#include <ATen/cuda/CUDAContext.h>
#include <torch/extension.h>
#include <c10/cuda/CUDAGuard.h>

#include "../../dispatch_utils.h"
#include "../../reduction_utils.cuh"
#include "quant_utils.cuh"

namespace aphrodite {

// TODO: Further optimize this kernel.
template <typename scalar_t>
__global__ void rms_norm_quant_kernel(
  int8_t* __restrict__ out,         // [..., hidden_size]
  const scalar_t* __restrict__ input, // [..., hidden_size]
  const scalar_t* __restrict__ weight, // [hidden_size]
  const float epsilon,
  const int num_tokens,
  const int hidden_size) {
  __shared__ float s_variance;
  float variance = 0.0f;

  for (int idx = threadIdx.x; idx < hidden_size; idx += blockDim.x) {
    const float x = (float)input[blockIdx.x * hidden_size + idx];
    variance += x * x;
  }
  variance = blockReduceSum<float>(variance);
  if (threadIdx.x == 0) {
    s_variance = rsqrtf(variance / hidden_size + epsilon);
  }
  __syncthreads();

  for (int idx = threadIdx.x; idx < hidden_size; idx += blockDim.x) {
    float x = (float)input[blockIdx.x * hidden_size + idx];
    out[blockIdx.x * hidden_size + idx] = float_to_int8_rn(
      x * s_variance * (float)(weight[idx]));
  }
}

template <typename scalar_t, bool use_per_token_dequant>
__global__ void dequant_add_residual_rms_norm_quant_kernel(
  const int32_t* __restrict__ input,
  scalar_t* __restrict__ residual,
  int8_t* __restrict__ out,
  const scalar_t* __restrict__ gamma,
  const float layernorm_eps,
  const float scale,
  const int num_tokens,
  const int hidden_size,
  const float* __restrict__ act_scale = nullptr) {
  // layernorm module in the T5 style No bias and no subtraction of mean.
  const int tid = threadIdx.x;

  __shared__ float s_variance;
  float variance = 0.0f;
  float local_var_sum = 0.0f;
  float scale_ = scale;
  if constexpr (use_per_token_dequant) {
    scale_ = scale * act_scale[blockIdx.x];
  }
  for (int i = tid; i < hidden_size; i += blockDim.x) {
    float diff = ((((float)input[blockIdx.x * hidden_size + i]) * scale_) +
                  (float)residual[blockIdx.x * hidden_size + i]);
    residual[blockIdx.x * hidden_size + i] = (scalar_t)diff;
    local_var_sum += diff * diff;
  }
  variance = blockReduceSum<float>(local_var_sum);

  if (threadIdx.x == 0) {
    s_variance = rsqrtf(variance / (float)hidden_size + layernorm_eps);
  }
  __syncthreads();

  for (int i = tid; i < hidden_size; i += blockDim.x) {
    float x = (float) residual[blockIdx.x * hidden_size + i];
    out[blockIdx.x * hidden_size + i] = float_to_int8_rn(
        x * s_variance * (float)(gamma[i]));
  }
}

template<typename scalar_t>
__global__ void add_residual_rms_norm_quant_kernel(
  int8_t* __restrict__ out,             // [..., hidden_size]
  scalar_t* __restrict__ input,           // [..., hidden_size]
  scalar_t* __restrict__ residual,        // [..., hidden_size]
  const scalar_t* __restrict__ weight,    // [hidden_size]
  const float epsilon,
  const int num_tokens,
  const int hidden_size) {
  __shared__ float s_variance;
  float variance = 0.0f;

  for (int idx = threadIdx.x; idx < hidden_size; idx += blockDim.x) {
    float x = (float) input[blockIdx.x * hidden_size + idx];
    x += (float) residual[blockIdx.x * hidden_size + idx];
    variance += x * x;
    residual[blockIdx.x * hidden_size + idx] = (scalar_t) x;
  }
  variance = blockReduceSum<float>(variance);
  if (threadIdx.x == 0) {
    s_variance = rsqrtf(variance / hidden_size + epsilon);
  }
  __syncthreads();

  for (int idx = threadIdx.x; idx < hidden_size; idx += blockDim.x) {
    float x = (float) residual[blockIdx.x * hidden_size + idx];
    out[blockIdx.x * hidden_size + idx] = float_to_int8_rn(x * s_variance * (float)(weight[idx]));
  }
}

} // namespace aphrodite

void rms_norm_quant(
  torch::Tensor& out,    // [..., hidden_size]
  torch::Tensor& input,  // [..., hidden_size]
  torch::Tensor& weight, // [hidden_size]
  float epsilon) {
  int hidden_size = input.size(-1);
  int num_tokens = input.numel() / hidden_size;
  dim3 grid(num_tokens);
  dim3 block(std::min(hidden_size, 1024));
  const at::cuda::OptionalCUDAGuard device_guard(device_of(input));
  const cudaStream_t stream = at::cuda::getCurrentCUDAStream();
  APHRODITE_DISPATCH_FLOATING_TYPES(input.scalar_type(), "rms_norm_quant_kernel", [&] {
    aphrodite::rms_norm_quant_kernel<scalar_t><<<grid, block, 0, stream>>>(
      out.data_ptr<int8_t>(),
      input.data_ptr<scalar_t>(),
      weight.data_ptr<scalar_t>(),
      epsilon,
      num_tokens,
      hidden_size);
  });
}

void dequant_add_residual_rms_norm_quant(
  torch::Tensor& out,      // [..., hidden_size]
  torch::Tensor& input,    // [..., hidden_size]
  torch::Tensor& residual, // [..., hidden_size]
  torch::Tensor& gamma,    // [hidden_size]
  float scale,
  float epsilon) {
  int hidden_size = input.size(-1);
  int num_tokens = input.numel() / hidden_size;
  dim3 grid(num_tokens);
  dim3 block(std::min(hidden_size, 1024));
  const cudaStream_t stream = at::cuda::getCurrentCUDAStream();
  APHRODITE_DISPATCH_FLOATING_TYPES(
      residual.scalar_type(), "dequant_add_residual_rms_norm_quant_kernel",
      [&] {
          aphrodite::dequant_add_residual_rms_norm_quant_kernel<scalar_t, false><<<grid, block, 0, stream>>>(
            input.data_ptr<int32_t>(),
            residual.data_ptr<scalar_t>(),
            out.data_ptr<int8_t>(),
            gamma.data_ptr<scalar_t>(),
            epsilon,
            scale,
            num_tokens,
            hidden_size);
      });
}

void dequant_add_residual_rms_norm_quant(
  torch::Tensor& out,      // [..., hidden_size]
  torch::Tensor& input,    // [..., hidden_size]
  torch::Tensor& residual, // [..., hidden_size]
  torch::Tensor& gamma,    // [hidden_size]
  torch::Tensor& scale,    // [num_tokens]
  float epsilon,
  float weight_dequant_scale) {
  int hidden_size = input.size(-1);
  int num_tokens = input.numel() / hidden_size;

  dim3 grid(num_tokens);
  dim3 block(std::min(hidden_size, 1024));

  const cudaStream_t stream = at::cuda::getCurrentCUDAStream();
  APHRODITE_DISPATCH_FLOATING_TYPES(
      residual.scalar_type(), "dequant_add_residual_rms_norm_quant_kernel",
      [&] {
          aphrodite::dequant_add_residual_rms_norm_quant_kernel<scalar_t, true><<<grid, block, 0, stream>>>(
            input.data_ptr<int32_t>(),
            residual.data_ptr<scalar_t>(),
            out.data_ptr<int8_t>(),
            gamma.data_ptr<scalar_t>(),
            epsilon,
            weight_dequant_scale,
            num_tokens,
            hidden_size,
            scale.data_ptr<float>());
      });
}

void add_residual_rms_norm_quant(
  torch::Tensor& out,      // [..., hidden_size]
  torch::Tensor& input,    // [..., hidden_size]
  torch::Tensor& residual, // [..., hidden_size]
  torch::Tensor& weight,   // [hidden_size]
  float epsilon) {
  int hidden_size = input.size(-1);
  int num_tokens = input.numel() / hidden_size;

  dim3 grid(num_tokens);
  dim3 block(std::min(hidden_size, 1024));
  const at::cuda::OptionalCUDAGuard device_guard(device_of(input));
  const cudaStream_t stream = at::cuda::getCurrentCUDAStream();
  APHRODITE_DISPATCH_FLOATING_TYPES(
    input.scalar_type(),
    "add_residual_rms_norm_quant_kernel", [&] {
      aphrodite::add_residual_rms_norm_quant_kernel<scalar_t><<<grid, block, 0, stream>>>(
        out.data_ptr<int8_t>(),
        input.data_ptr<scalar_t>(),
        residual.data_ptr<scalar_t>(),
        weight.data_ptr<scalar_t>(),
        epsilon,
        num_tokens,
        hidden_size);
    });
}
