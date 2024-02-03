from typing import Any, Dict, List, Optional

import torch
from torch._tensor import Tensor
from torch.nn.parameter import Parameter
import threading

from aphrodite._C import ops
from aphrodite.modeling.layers.linear import (LinearMethodBase,
                                              set_weight_attrs)
from aphrodite.modeling.layers.quantization.base_config import QuantizationConfig


class SmoothQuantConfig(QuantizationConfig):
    """Config class for SmoothQuant
    Reference: https://github.com/mit-han-lab/smoothquant
    """

    def __init__(self,
                 weight_bits: int = 8,
                 quant_map: dict[str:str] = None) -> None:
        self.weight_bits = weight_bits
        self.quant_map = quant_map

        if self.weight_bits != 8:
            raise ValueError(
                "Currently, only w8a8 quantization is supported for "
                f"SmoothQuant, but got {self.weight_bits} bits.")
        if self.quant_map is None or self.quant_map == {}:
            raise ValueError(
                'Quant_map for SmoothQuant should not be None or an empty dict. '
                'For example, when using llama, you should set a quant_config.json in model directory, like '
                '{ "qkv": "per-tensor", "out": "per-token", "fc1": "per-tensor", "fc2": "per-token" }'
            )

    def __repr__(self) -> str:
        return (f"SmoothQuantConfig(weight_bits={self.weight_bits}, "
                f"quant_map={self.quant_map})")

    def get_name(self) -> str:
        return "smoothquant"

    def get_supported_act_dtypes(self) -> List[torch.dtype]:
        return [torch.half, torch.float]

    def get_min_capability(self) -> int:
        # The smoothquant kernel only supports Ampere or newer GPUs.
        return 80

    @classmethod
    def get_config_filenames(cls) -> List[str]:
        """List of filenames to search for in the model directory."""
        return [
            "quant_config.json",
            "quantize_config.json",
        ]

    @classmethod
    def from_config(cls, config: Dict[str, Any]) -> "SmoothQuantConfig":
        try:
            weight_bits = cls.get_from_keys(config, ["w_bit", "bits"])
        except ValueError as e:
            weight_bits = 8
            print(str(e) + " Set weight_bits = 8 by default.")

        quant_map = {}
        for key, value in config.items():
            if value in ["per-tensor", "per-token"]:
                quant_map[key] = value
        return cls(weight_bits, quant_map)

    def get_linear_method(self) -> "SQLinearMethod":
        return SQLinearMethod(Int8GEMM)

    def get_scaled_act_names(self) -> List[str]:
        return []


class Int8GEMM(object):
    _instance_lock = threading.Lock()

    def __init__(self):
        if not hasattr(self, "i8cugemm"):
            self.i8cugemm = ops.I8CUGEMM()

    def __new__(cls, *args, **kwargs):
        if not hasattr(Int8GEMM, "_instance"):
            with Int8GEMM._instance_lock:
                if not hasattr(Int8GEMM, "_instance"):
                    Int8GEMM._instance = object.__new__(cls)
        return Int8GEMM._instance

    def get_i8cugemm(self):
        return self.i8cugemm


class SQLinearMethod(LinearMethodBase):
    """Linear method for SmoothQuant.
    """

    def __init__(self, gemm):
        i8_gemm = gemm()
        self.i8cugemm = i8_gemm.get_i8cugemm()

    def create_weights(self, input_size_per_partition: int,
                       output_size_per_partition: int, input_size: int,
                       output_size: int,
                       params_dtype: torch.dtype) -> Dict[str, Tensor]:
        weight = Parameter(
            torch.empty(
                output_size_per_partition,
                input_size_per_partition,
                device="cuda",
                dtype=torch.int8,
            ),
            requires_grad=False,
        )
        set_weight_attrs(weight, {
            "input_dim": 1,
            "output_dim": 0,
        })
        # q k v dequant_scales are used in QKVParallelLinear
        q_dequant_scale = Parameter(
            torch.tensor(1.0, dtype=torch.float32, device='cpu'),
            requires_grad=False,
        )
        k_dequant_scale = Parameter(
            torch.tensor(1.0, dtype=torch.float32, device='cpu'),
            requires_grad=False,
        )
        v_dequant_scale = Parameter(
            torch.tensor(1.0, dtype=torch.float32, device='cpu'),
            requires_grad=False,
        )
        # gate up dequant_scales are used in MergedColumnParallelLinear
        gate_dequant_scale = Parameter(
            torch.tensor(1.0, dtype=torch.float32, device='cpu'),
            requires_grad=False,
        )
        up_dequant_scale = Parameter(
            torch.tensor(1.0, dtype=torch.float32, device='cpu'),
            requires_grad=False,
        )
        # dequant_scale is used in RowParallelLinear
        dequant_scale = Parameter(
            torch.tensor(1.0, dtype=torch.float32, device='cpu'),
            requires_grad=False,
        )
        return {
            "weight": weight,
            "q_dequant_scale": q_dequant_scale,
            "k_dequant_scale": k_dequant_scale,
            "v_dequant_scale": v_dequant_scale,
            "gate_dequant_scale": gate_dequant_scale,
            "up_dequant_scale": up_dequant_scale,
            "dequant_scale": dequant_scale
        }

    def apply_weights(self,
                      weights: Dict[str, Tensor],
                      x: torch.Tensor,
                      bias: Optional[torch.Tensor] = None) -> Tensor:
        assert bias is None
        weight = weights["weight"]
        x_shape = x.shape
        x = x.view(-1, x_shape[-1])
        y = torch.empty((x.shape[0], weight.shape[0]),
                        dtype=torch.int32,
                        device=x.device)
        self.i8cugemm.linear_a8_w8_o32_(x, weight, y)
        y = y.view(*x_shape[:-1], -1)
        return y
