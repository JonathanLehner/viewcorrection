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

#ifndef VIEW_CORRECTION_CUDA_CONVOLUTION_INPAINTING_RGB_CUH_
#define VIEW_CORRECTION_CUDA_CONVOLUTION_INPAINTING_RGB_CUH_

#include <cuda_runtime.h>

#include "view_correction/cuda_buffer.h"

namespace view_correction {

// Returns the number of iterations done.
// Pixels with input.w == 0 will be inpainted.
int InpaintImageWithConvolutionCUDA(
    cudaStream_t stream,
    bool use_weighting,
    int max_num_iterations,
    float max_change_rate_threshold,
    cudaTextureObject_t gradient_magnitude_div_sqrt2,
    const CUDABuffer<uchar4>& input,
    CUDABuffer<uint8_t>* max_change,
    CUDABuffer<uchar4>* output,
    CUDABuffer<uint16_t>* block_coordinates,
    uint32_t* pixel_to_inpaint_count);

} // namespace view_correction

#endif // #ifndef VIEW_CORRECTION_CUDA_CONVOLUTION_INPAINTING_RGB_CUH_
