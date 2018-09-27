// Copyright 2018 ETH Zürich
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// 3. Neither the name of the copyright holder nor the names of its contributors
//    may be used to endorse or promote products derived from this software
//    without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#include "view_correction/cuda_convolution_inpainting.cuh"

#include <cub/cub.cuh>
#include <glog/logging.h>

#include "view_correction/cuda_util.h"

namespace view_correction {

constexpr int kIterationsPerKernelCall = 4;

const int kBlockWidth = 32;
const int kBlockHeight = 32;

constexpr float kSqrt2 = 1.4142135623731f;

template<int block_size_x, int block_size_y>
__global__ void ConvolutionInpaintingInitializeVariablesKernel(
    int grid_dim_x,
    float depth_input_scaling_factor,
    cudaTextureObject_t depth_map_input,
    CUDABuffer_<float> depth_map_output,
    CUDABuffer_<uint16_t> block_coordinates) {
  const int width = depth_map_output.width();
  const int height = depth_map_output.height();
  
  const int kBlockOutputSizeX = block_size_x - 2 * kIterationsPerKernelCall;
  const int kBlockOutputSizeY = block_size_y - 2 * kIterationsPerKernelCall;
  unsigned int x = blockIdx.x * kBlockOutputSizeX + threadIdx.x - kIterationsPerKernelCall;
  unsigned int y = blockIdx.y * kBlockOutputSizeY + threadIdx.y - kIterationsPerKernelCall;
  
  const bool kOutput =
      threadIdx.x >= kIterationsPerKernelCall &&
      threadIdx.y >= kIterationsPerKernelCall &&
      threadIdx.x < block_size_x - kIterationsPerKernelCall &&
      threadIdx.y < block_size_y - kIterationsPerKernelCall &&
      x < width &&
      y < height;
  
  bool thread_is_active = false;
  if (kOutput) {
    const float depth_input = depth_input_scaling_factor * tex2D<float>(depth_map_input, x, y);
    depth_map_output(y, x) = depth_input;
    thread_is_active = (depth_input == 0);
  }
  
  typedef cub::BlockReduce<
      int, block_size_x, cub::BLOCK_REDUCE_WARP_REDUCTIONS, block_size_y> BlockReduceInt;
  __shared__ typename BlockReduceInt::TempStorage int_storage;
  int num_active_threads = BlockReduceInt(int_storage).Sum(thread_is_active ? 1 : 0);
  if (threadIdx.x == 0 && threadIdx.y == 0) {
    block_coordinates(0, blockIdx.x + blockIdx.y * grid_dim_x) = num_active_threads;
  }
}

template<int block_size_x, int block_size_y, bool check_convergence>
__global__ void ConvolutionInpaintingKernel(
    CUDABuffer_<uint16_t> block_coordinates,
    cudaTextureObject_t depth_map_input,
    CUDABuffer_<uint8_t> max_change,
    float max_change_rate_threshold,
    CUDABuffer_<float> depth_map_output) {
  const int x = max(0, min(depth_map_output.width() - 1, block_coordinates(0, 2 * blockIdx.x + 0) + threadIdx.x - kIterationsPerKernelCall));
  const int y = max(0, min(depth_map_output.height() - 1, block_coordinates(0, 2 * blockIdx.x + 1) + threadIdx.y - kIterationsPerKernelCall));
  
  const bool kIsPixelToInpaint = (tex2D<float>(depth_map_input, x, y) <= 0);
  const bool kOutput =
      threadIdx.x >= kIterationsPerKernelCall &&
      threadIdx.y >= kIterationsPerKernelCall &&
      threadIdx.x < block_size_x - kIterationsPerKernelCall &&
      threadIdx.y < block_size_y - kIterationsPerKernelCall &&
      block_coordinates(0, 2 * blockIdx.x + 0) + threadIdx.x - kIterationsPerKernelCall < depth_map_output.width() &&
      block_coordinates(0, 2 * blockIdx.x + 1) + threadIdx.y - kIterationsPerKernelCall < depth_map_output.height();
  
  // Load inputs into private or shared memory.
  __shared__ float depth_shared[block_size_x * block_size_y];
  int shared_mem_index = threadIdx.x + block_size_x * threadIdx.y;
  depth_shared[shared_mem_index] = depth_map_output(y, x);
  
  // Wait for shared memory to be loaded.
  __syncthreads();
  
#pragma unroll
  for (int i = 0; i < kIterationsPerKernelCall; ++ i) {
    float result = 0;
    float weight = 0;
    float pixel_weight;
    float temp_depth;
    if (kIsPixelToInpaint &&
        threadIdx.x > 0 &&
        threadIdx.y > 0 &&
        threadIdx.x < block_size_x - 1 &&
        threadIdx.y < block_size_y - 1) {
      temp_depth = depth_shared[shared_mem_index - 1 - block_size_x];
      pixel_weight =
          (y > 0 && x > 0 && temp_depth > 0) *
          0.073235f;
      result += pixel_weight * temp_depth;
      weight += pixel_weight;
      
      temp_depth = depth_shared[shared_mem_index - block_size_x];
      pixel_weight =
          (y > 0 && temp_depth > 0) *
          0.176765f;
      result += pixel_weight * temp_depth;
      weight += pixel_weight;
      
      temp_depth = depth_shared[shared_mem_index + 1 - block_size_x];
      pixel_weight =
          (y > 0 && x < depth_map_output.width() - 1 && temp_depth > 0) *
          0.073235f;
      result += pixel_weight * temp_depth;
      weight += pixel_weight;
      
      temp_depth = depth_shared[shared_mem_index - 1];
      pixel_weight =
          (x > 0 && temp_depth > 0) *
          0.176765f;
      result += pixel_weight * temp_depth;
      weight += pixel_weight;
      
      temp_depth = depth_shared[shared_mem_index + 1];
      pixel_weight =
          (x < depth_map_output.width() - 1 && temp_depth > 0) *
          0.176765f;
      result += pixel_weight * temp_depth;
      weight += pixel_weight;
      
      temp_depth = depth_shared[shared_mem_index - 1 + block_size_x];
      pixel_weight =
          (y < depth_map_output.height() - 1 && x > 0 && temp_depth > 0) *
          0.073235f;
      result += pixel_weight * temp_depth;
      weight += pixel_weight;
      
      temp_depth = depth_shared[shared_mem_index + block_size_x];
      pixel_weight =
          (y < depth_map_output.height() - 1 && temp_depth > 0) *
          0.176765f;
      result += pixel_weight * temp_depth;
      weight += pixel_weight;
      
      temp_depth = depth_shared[shared_mem_index + 1 + block_size_x];
      pixel_weight =
          (y < depth_map_output.height() - 1 && x < depth_map_output.width() - 1 && temp_depth > 0) *
          0.073235f;
      result += pixel_weight * temp_depth;
      weight += pixel_weight;
      
      // Version without explicit handling of uninitialized values:
//       result = 0.073235f * depth_shared[shared_mem_index - 1 - block_size_x] +
//                0.176765f * depth_shared[shared_mem_index - block_size_x] +
//                0.073235f * depth_shared[shared_mem_index + 1 - block_size_x] +
//                0.176765f * depth_shared[shared_mem_index - 1] +
//                0 +
//                0.176765f * depth_shared[shared_mem_index + 1] +
//                0.073235f * depth_shared[shared_mem_index - 1 + block_size_x] +
//                0.176765f * depth_shared[shared_mem_index + block_size_x] +
//                0.073235f * depth_shared[shared_mem_index + 1 + block_size_x];
    }
    __syncthreads();
    
    float new_depth = result / weight;
    
    // Convergence test.
    float change = 0;
    if (check_convergence && kOutput && kIsPixelToInpaint && i == kIterationsPerKernelCall - 1) {
      change = fabs((new_depth - depth_shared[shared_mem_index]) / depth_shared[shared_mem_index]);
    }
    if (check_convergence) {
      typedef cub::BlockReduce<
          int, block_size_x, cub::BLOCK_REDUCE_WARP_REDUCTIONS, block_size_y> BlockReduceInt;
      __shared__ typename BlockReduceInt::TempStorage int_storage;
      int active_pixels = BlockReduceInt(int_storage).Sum(change > max_change_rate_threshold);
      if (threadIdx.x == 0 && threadIdx.y == 0) {
        max_change(0, blockIdx.x) = (active_pixels > 0) ? 1 : 0;
      }
    }
    
    if (kIsPixelToInpaint && weight > 0) {
      depth_shared[shared_mem_index] = new_depth;
    }
    __syncthreads();
  }
  
  if (kOutput && kIsPixelToInpaint) {
    depth_map_output(y, x) = depth_shared[shared_mem_index];
  }
}

template<int block_size_x, int block_size_y, bool check_convergence>
__global__ void ConvolutionInpaintingKernelWithWeighting(
    CUDABuffer_<uint16_t> block_coordinates,
    cudaTextureObject_t depth_map_input,
    cudaTextureObject_t gradient_magnitude_div_sqrt2,
    CUDABuffer_<uint8_t> max_change,
    float max_change_rate_threshold,
    CUDABuffer_<float> depth_map_output) {
  const int raw_x = block_coordinates(0, 2 * blockIdx.x + 0) + threadIdx.x - kIterationsPerKernelCall;
  const int raw_y = block_coordinates(0, 2 * blockIdx.x + 1) + threadIdx.y - kIterationsPerKernelCall;
  const bool kInImage =
      raw_x >= 0 &&
      raw_y >= 0 &&
      raw_x < depth_map_output.width() &&
      raw_y < depth_map_output.height();
  const int x = max(0, min(depth_map_output.width() - 1, raw_x));
  const int y = max(0, min(depth_map_output.height() - 1, raw_y));
  
  const bool kIsPixelToInpaint = (tex2D<float>(depth_map_input, x, y) <= 0);
  const bool kOutput =
      threadIdx.x >= kIterationsPerKernelCall &&
      threadIdx.y >= kIterationsPerKernelCall &&
      threadIdx.x < block_size_x - kIterationsPerKernelCall &&
      threadIdx.y < block_size_y - kIterationsPerKernelCall &&
      kInImage && kIsPixelToInpaint;
  
  // Load inputs into private or shared memory.
  __shared__ float depth_shared[block_size_x * block_size_y];
  __shared__ float weights_shared[block_size_x * block_size_y];
  const int shared_mem_index = threadIdx.x + block_size_x * threadIdx.y;
  depth_shared[shared_mem_index] = depth_map_output(y, x);
  const float base_weight = (kInImage ? 1 : 0) *  1.f / (1.f + 50.f * tex2D<uchar>(gradient_magnitude_div_sqrt2, x, y) * kSqrt2 / 255.f);
  weights_shared[shared_mem_index] = base_weight * (depth_shared[shared_mem_index] > 0);
  
  // Wait for shared memory to be loaded.
  __syncthreads();
  
#pragma unroll
  for (int i = 0; i < kIterationsPerKernelCall; ++ i) {
    float new_depth = 0;
    if (kIsPixelToInpaint &&
        threadIdx.x > 0 &&
        threadIdx.y > 0 &&
        threadIdx.x < block_size_x - 1 &&
        threadIdx.y < block_size_y - 1) {
      float weight = 0;
      float pixel_weight;
      
      pixel_weight =
          0.073235f * weights_shared[shared_mem_index - 1 - block_size_x];
      new_depth += pixel_weight * depth_shared[shared_mem_index - 1 - block_size_x];
      weight += pixel_weight;
      
      pixel_weight =
          0.176765f * weights_shared[shared_mem_index - block_size_x];
      new_depth += pixel_weight * depth_shared[shared_mem_index - block_size_x];
      weight += pixel_weight;
      
      pixel_weight =
          0.073235f * weights_shared[shared_mem_index + 1 - block_size_x];
      new_depth += pixel_weight * depth_shared[shared_mem_index + 1 - block_size_x];
      weight += pixel_weight;
      
      pixel_weight =
          0.176765f * weights_shared[shared_mem_index - 1];
      new_depth += pixel_weight * depth_shared[shared_mem_index - 1];
      weight += pixel_weight;
      
      pixel_weight =
          0.176765f * weights_shared[shared_mem_index + 1];
      new_depth += pixel_weight * depth_shared[shared_mem_index + 1];
      weight += pixel_weight;
      
      pixel_weight =
          0.073235f * weights_shared[shared_mem_index - 1 + block_size_x];
      new_depth += pixel_weight * depth_shared[shared_mem_index - 1 + block_size_x];
      weight += pixel_weight;
      
      pixel_weight =
          0.176765f * weights_shared[shared_mem_index + block_size_x];
      new_depth += pixel_weight * depth_shared[shared_mem_index + block_size_x];
      weight += pixel_weight;
      
      pixel_weight =
          0.073235f * weights_shared[shared_mem_index + 1 + block_size_x];
      new_depth += pixel_weight * depth_shared[shared_mem_index + 1 + block_size_x];
      weight += pixel_weight;
      
      // Version without explicit handling of uninitialized values:
      // (And without weights):
//       result = 0.073235f * depth_shared[shared_mem_index - 1 - block_size_x] +
//                0.176765f * depth_shared[shared_mem_index - block_size_x] +
//                0.073235f * depth_shared[shared_mem_index + 1 - block_size_x] +
//                0.176765f * depth_shared[shared_mem_index - 1] +
//                0 +
//                0.176765f * depth_shared[shared_mem_index + 1] +
//                0.073235f * depth_shared[shared_mem_index - 1 + block_size_x] +
//                0.176765f * depth_shared[shared_mem_index + block_size_x] +
//                0.073235f * depth_shared[shared_mem_index + 1 + block_size_x];
      
      new_depth = new_depth / weight;
    }
    __syncthreads();
    
    // Convergence test.
    if (check_convergence && i == kIterationsPerKernelCall - 1) {
      float change = 0;
      if (kOutput) {
        change = fabs((new_depth - depth_shared[shared_mem_index]) / depth_shared[shared_mem_index]);
      }
      
      typedef cub::BlockReduce<
          int, block_size_x, cub::BLOCK_REDUCE_WARP_REDUCTIONS, block_size_y> BlockReduceInt;
      __shared__ typename BlockReduceInt::TempStorage int_storage;
      int active_pixels = BlockReduceInt(int_storage).Sum(change > max_change_rate_threshold);
      if (threadIdx.x == 0 && threadIdx.y == 0) {
        max_change(0, blockIdx.x) = (active_pixels > 0) ? 1 : 0;
      }
    }
    
    if (kIsPixelToInpaint && new_depth > 0) {
      depth_shared[shared_mem_index] = new_depth;
      if (i < kIterationsPerKernelCall - 1) {
        weights_shared[shared_mem_index] = base_weight * (new_depth > 0);
      }
    }
    if (i < kIterationsPerKernelCall - 1) {
      __syncthreads();
    }
  }
  
  if (kOutput) {
    depth_map_output(y, x) = depth_shared[shared_mem_index];
  }
}

int InpaintDepthMapWithConvolutionCUDA(
    cudaStream_t stream,
    bool use_weighting,
    int max_num_iterations,
    float max_change_rate_threshold,
    float depth_input_scaling_factor,
    cudaTextureObject_t gradient_magnitude_div_sqrt2,
    cudaTextureObject_t depth_map_input,
    CUDABuffer<uint8_t>* max_change,
    CUDABuffer<float>* depth_map_output,
    CUDABuffer<uint16_t>* block_coordinates,
    uint32_t* pixel_to_inpaint_count) {
  const int width = depth_map_output->width();
  const int height = depth_map_output->height();
  
  const dim3 block_dim(kBlockWidth, kBlockHeight);
  
  const int kBlockOutputSizeX = kBlockWidth - 2 * kIterationsPerKernelCall;
  const int kBlockOutputSizeY = kBlockHeight - 2 * kIterationsPerKernelCall;
  dim3 grid_dim(cuda_util::GetBlockCount(width, kBlockOutputSizeX),
                cuda_util::GetBlockCount(height, kBlockOutputSizeY));
  
  // Initialize variables.
  CHECK_EQ(kBlockWidth, 32);
  CHECK_EQ(kBlockHeight, 32);
  ConvolutionInpaintingInitializeVariablesKernel<32, 32><<<grid_dim, block_dim, 0, stream>>>(
      grid_dim.x, depth_input_scaling_factor, depth_map_input, depth_map_output->ToCUDA(), block_coordinates->ToCUDA());
  CHECK_CUDA_NO_ERROR();
  
  uint16_t* block_activity = new uint16_t[grid_dim.x * grid_dim.y];
  block_coordinates->DownloadPartAsync(0, grid_dim.x * grid_dim.y * sizeof(uint16_t), stream, block_activity);
  cudaStreamSynchronize(stream);
  int active_block_count = 0;
  *pixel_to_inpaint_count = 0;
  uint16_t* block_coordinates_cpu = new uint16_t[2 * grid_dim.x * grid_dim.y];
  for (size_t y = 0; y < grid_dim.y; ++ y) {
    for (size_t x = 0; x < grid_dim.x; ++ x) {
      if (block_activity[x + y * grid_dim.x] > 0) {
        block_coordinates_cpu[2 * active_block_count + 0] = x * kBlockOutputSizeX;
        block_coordinates_cpu[2 * active_block_count + 1] = y * kBlockOutputSizeY;
        ++ active_block_count;
        *pixel_to_inpaint_count += block_activity[x + y * grid_dim.x];
      }
    }
  }
  delete[] block_activity;
  if (active_block_count == 0) {
    delete[] block_coordinates_cpu;
    LOG(INFO) << "Depth inpainting converged after iteration: 0";
    return 0;
  }
  block_coordinates->UploadPartAsync(0, 2 * active_block_count * sizeof(uint16_t), stream, block_coordinates_cpu);
  
  uint8_t* max_change_cpu = new uint8_t[grid_dim.x * grid_dim.y];
  
  // Run convolution iterations.
  int i = 0;
  int last_convergence_check_iteration = -9999;
  for (i = 0; i < max_num_iterations; i += kIterationsPerKernelCall) {
    const bool check_convergence = (i - last_convergence_check_iteration >= 25);
    
    dim3 grid_dim_active(active_block_count);
    CHECK_EQ(kBlockWidth, 32);
    CHECK_EQ(kBlockHeight, 32);
    if (use_weighting) {
      if (check_convergence) {
        ConvolutionInpaintingKernelWithWeighting<32, 32, true><<<grid_dim_active, block_dim, 0, stream>>>(
            block_coordinates->ToCUDA(),
            depth_map_input,
            gradient_magnitude_div_sqrt2,
            max_change->ToCUDA(),
            max_change_rate_threshold,
            depth_map_output->ToCUDA());
      } else {
        ConvolutionInpaintingKernelWithWeighting<32, 32, false><<<grid_dim_active, block_dim, 0, stream>>>(
            block_coordinates->ToCUDA(),
            depth_map_input,
            gradient_magnitude_div_sqrt2,
            max_change->ToCUDA(),
            max_change_rate_threshold,
            depth_map_output->ToCUDA());
      }
    } else {
      if (check_convergence) {
        ConvolutionInpaintingKernel<32, 32, true><<<grid_dim_active, block_dim, 0, stream>>>(
            block_coordinates->ToCUDA(),
            depth_map_input,
            max_change->ToCUDA(),
            max_change_rate_threshold,
            depth_map_output->ToCUDA());
      } else {
        ConvolutionInpaintingKernel<32, 32, false><<<grid_dim_active, block_dim, 0, stream>>>(
            block_coordinates->ToCUDA(),
            depth_map_input,
            max_change->ToCUDA(),
            max_change_rate_threshold,
            depth_map_output->ToCUDA());
      }
    }
    
    if (check_convergence) {
      max_change->DownloadPartAsync(0, active_block_count * sizeof(uint8_t), stream, max_change_cpu);
      cudaStreamSynchronize(stream);
      int new_active_block_count = 0;
      for (int j = 0, end = active_block_count; j < end; j ++) {
        if (max_change_cpu[j]) {
          ++ new_active_block_count;
        }
      }
      if (new_active_block_count == 0) {
        i += kIterationsPerKernelCall;  // For correct iteration count logging.
        break;
      }
      last_convergence_check_iteration = i;
    }
  }
  
  delete[] max_change_cpu;
  delete[] block_coordinates_cpu;
  CHECK_CUDA_NO_ERROR();
  
  if (i < max_num_iterations) {
    LOG(INFO) << "Depth inpainting converged after iteration: " << i;
  } else {
    LOG(WARNING) << "Depth inpainting used maximum iteration count: " << i;
  }
  return i;
}

}
