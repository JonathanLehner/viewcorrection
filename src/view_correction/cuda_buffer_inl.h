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

#ifndef VIEW_CORRECTION_CUDA_BUFFER_INL_H_
#define VIEW_CORRECTION_CUDA_BUFFER_INL_H_

#include <glog/logging.h>
#include <opencv2/core/core.hpp>

#include "view_correction/cuda_util.h"

namespace view_correction {

template <typename T>
CUDABuffer<T>::CUDABuffer(int height, int width)
    : data_(0, height, width, 0),
      texture_object_allocated_(false) {
  CUDA_CHECKED_CALL(cudaMallocPitch(&data_.address_, &data_.pitch_,
                                    data_.width_ * sizeof(T), data_.height_));
  if (data_.pitch_ != data_.width_ * sizeof(T)) {
    LOG(WARNING) << "Pitch does not match width. Width in bytes: "
                 << data_.width_ * sizeof(T)
                 << ", pitch in bytes: " << data_.pitch_
                 << ", width and height: " << data_.width_ << " x "
                 << data_.height_;
  }
}

template <typename T>
CUDABuffer<T>::~CUDABuffer() {
  if (texture_object_allocated_) {
    cudaDestroyTextureObject(texture_object_);
    texture_object_allocated_ = false;
  }

  CUDA_CHECKED_CALL(cudaFree(reinterpret_cast<void*>(data_.address_)));
}

template <typename T>
void CUDABuffer<T>::DebugUpload(const T* data) {
  CHECK_NOTNULL(data);
  CUDA_CHECKED_CALL(
      cudaMemcpy2D(data_.address_, data_.pitch_, static_cast<const void*>(data),
                   data_.width_ * sizeof(T), data_.width_ * sizeof(T),
                   data_.height_, cudaMemcpyHostToDevice));
}

template <typename T>
void CUDABuffer<T>::DebugUploadPitched(size_t pitch, const T* data) {
  CHECK_NOTNULL(data);
  CUDA_CHECKED_CALL(cudaMemcpy2D(
      data_.address_, data_.pitch_, static_cast<const void*>(data), pitch,
      data_.width_ * sizeof(T), data_.height_, cudaMemcpyHostToDevice));
}

template <typename T>
void CUDABuffer<T>::UploadAsync(cudaStream_t stream, const T* data) {
  CHECK_NOTNULL(data);
  CUDA_CHECKED_CALL(cudaMemcpy2DAsync(
      data_.address_, data_.pitch_, static_cast<const void*>(data),
      data_.width_ * sizeof(T), data_.width_ * sizeof(T), data_.height_,
      cudaMemcpyHostToDevice, stream));
}

template <typename T>
void CUDABuffer<T>::UploadPitchedAsync(cudaStream_t stream, size_t pitch,
                                       const T* data) {
  CHECK_NOTNULL(data);
  CUDA_CHECKED_CALL(cudaMemcpy2DAsync(
      data_.address_, data_.pitch_, static_cast<const void*>(data), pitch,
      data_.width_ * sizeof(T), data_.height_, cudaMemcpyHostToDevice, stream));
}

template <typename T>
void CUDABuffer<T>::UploadPartAsync(size_t start, size_t length,
                                    cudaStream_t stream, T* data) {
  CHECK_EQ(data_.height_, 1);
  CHECK_NOTNULL(data);
  CUDA_CHECKED_CALL(cudaMemcpy2DAsync(
      static_cast<void*>(reinterpret_cast<int8_t*>(data_.address_) + start),
      data_.pitch_, static_cast<void*>(data), data_.width_ * sizeof(T), length,
      data_.height_, cudaMemcpyHostToDevice, stream));
}

template <typename T>
void CUDABuffer<T>::Upload(const cv::Mat_<T>& image) {
  CHECK(!image.empty());
  CUDA_CHECKED_CALL(cudaMemcpy2D(data_.address_, data_.pitch_, image.data,
                                 image.step, data_.width_ * sizeof(T),
                                 data_.height_, cudaMemcpyHostToDevice));
}

template <typename T>
void CUDABuffer<T>::UploadAsync(cudaStream_t stream, const cv::Mat_<T>& image) {
  CHECK(!image.empty());
  CUDA_CHECKED_CALL(cudaMemcpy2DAsync(
      data_.address_, data_.pitch_, image.data, image.step,
      data_.width_ * sizeof(T), data_.height_, cudaMemcpyHostToDevice, stream));
}

template <typename T>
void CUDABuffer<T>::DebugDownload(T* data) const {
  CHECK_NOTNULL(data);
  CUDA_CHECKED_CALL(cudaMemcpy2D(static_cast<void*>(data),
                                 data_.width_ * sizeof(T), data_.address_,
                                 data_.pitch_, data_.width_ * sizeof(T),
                                 data_.height_, cudaMemcpyDeviceToHost));
}

template <typename T>
void CUDABuffer<T>::DebugDownloadPitched(size_t pitch, T* data) const {
  CHECK_NOTNULL(data);
  CUDA_CHECKED_CALL(cudaMemcpy2D(
      static_cast<void*>(data), pitch, data_.address_, data_.pitch_,
      data_.width_ * sizeof(T), data_.height_, cudaMemcpyDeviceToHost));
}

template <typename T>
void CUDABuffer<T>::DownloadPitchedAsync(cudaStream_t stream, size_t pitch,
                                         T* data) {
  CHECK_NOTNULL(data);
  CUDA_CHECKED_CALL(cudaMemcpy2DAsync(
      static_cast<void*>(data), pitch, data_.address_, data_.pitch_,
      data_.width_ * sizeof(T), data_.height_, cudaMemcpyDeviceToHost, stream));
}

template <typename T>
void CUDABuffer<T>::DownloadAsync(cudaStream_t stream, T* data) const {
  CHECK_NOTNULL(data);
  CUDA_CHECKED_CALL(
      cudaMemcpy2DAsync(static_cast<void*>(data), data_.width_ * sizeof(T),
                        data_.address_, data_.pitch_, data_.width_ * sizeof(T),
                        data_.height_, cudaMemcpyDeviceToHost, stream));
}

template <typename T>
void CUDABuffer<T>::DownloadPartAsync(size_t start, size_t length,
                                      cudaStream_t stream, T* data) const {
  CHECK_EQ(data_.height_, 1);
  CHECK_NOTNULL(data);
  CUDA_CHECKED_CALL(cudaMemcpy2DAsync(
      static_cast<void*>(data), data_.width_ * sizeof(T),
      static_cast<void*>(reinterpret_cast<int8_t*>(data_.address_) + start),
      data_.pitch_, length, data_.height_, cudaMemcpyDeviceToHost, stream));
}

template <typename T>
void CUDABuffer<T>::Download(cv::Mat_<T>* image) const {
  CHECK_NOTNULL(image)->create(height(), width());
  CUDA_CHECKED_CALL(cudaMemcpy2D(image->data, image->step, data_.address_,
                                 data_.pitch_, data_.width_ * sizeof(T),
                                 data_.height_, cudaMemcpyDeviceToHost));
}

template <typename T>
void CUDABuffer<T>::DownloadRectAsync(int src_y, int src_x, int height,
                                      int width, int dest_y, int dest_x,
                                      cudaStream_t stream,
                                      cv::Mat_<T>* image) const {
  CHECK_NOTNULL(image);
  CUDA_CHECKED_CALL(cudaMemcpy2DAsync(
      image->data + dest_y * image->step + dest_x * sizeof(T), image->step,
      reinterpret_cast<T*>(reinterpret_cast<int8_t*>(data_.address_) +
                           src_y * data_.pitch_) +
          src_x,
      data_.pitch_, width * sizeof(T), height, cudaMemcpyDeviceToHost, stream));
}

template <typename T>
void CUDABuffer<T>::Clear(T value, cudaStream_t stream) {
  data_.Clear(value, stream);
}

template <typename T>
void CUDABuffer<T>::SetTo(cudaTextureObject_t texture, cudaStream_t stream) {
  data_.SetTo(texture, stream);
}

template <typename T>
void CUDABuffer<T>::SetTo(const CUDABuffer<T>& other, cudaStream_t stream) {
  cudaTextureObject_t texture;
  other.CreateTextureObject(cudaAddressModeClamp, cudaAddressModeClamp,
                            cudaFilterModePoint, cudaReadModeElementType, false,
                            &texture);
  SetTo(texture, stream);
  cudaDestroyTextureObject(texture);
}

template <typename T>
void CUDABuffer<T>::CreateTextureObject(
    cudaTextureAddressMode address_mode_x,
    cudaTextureAddressMode address_mode_y, cudaTextureFilterMode filter_mode,
    cudaTextureReadMode read_mode, bool use_normalized_coordinates,
    cudaTextureObject_t* texture_object) const {
//   CHECK_NOTNULL(texture_object);
  cudaResourceDesc resDesc;
  memset(&resDesc, 0, sizeof(resDesc));
  resDesc.resType = cudaResourceTypePitch2D;

  resDesc.res.pitch2D.devPtr = data_.address_;
  resDesc.res.pitch2D.pitchInBytes = data_.pitch_;
  resDesc.res.pitch2D.width = data_.width_;
  resDesc.res.pitch2D.height = data_.height_;
  resDesc.res.pitch2D.desc = cudaCreateChannelDesc<T>();

  struct cudaTextureDesc texDesc;
  memset(&texDesc, 0, sizeof(texDesc));
  texDesc.addressMode[0] = address_mode_x;
  texDesc.addressMode[1] = address_mode_y;
  texDesc.filterMode = filter_mode;
  texDesc.readMode = read_mode;
  texDesc.normalizedCoords = use_normalized_coordinates ? 1 : 0;
//   CUDA_CHECKED_CALL(
  cudaCreateTextureObject(texture_object, &resDesc, &texDesc, NULL);
//       );
}

template <typename T>
void CUDABuffer<T>::GetCachedTextureObject(
    cudaTextureAddressMode address_mode_x,
    cudaTextureAddressMode address_mode_y, cudaTextureFilterMode filter_mode,
    cudaTextureReadMode read_mode, bool use_normalized_coordinates,
    cudaTextureObject_t* texture_object) {
  CHECK_NOTNULL(texture_object);
  if (texture_object_allocated_) {
    if (address_mode_x_ == address_mode_x &&
        address_mode_y_ == address_mode_y && filter_mode_ == filter_mode &&
        read_mode_ == read_mode &&
        use_normalized_coordinates_ == use_normalized_coordinates) {
      *texture_object = texture_object_;
      return;
    }
//     CUDA_CHECKED_CALL(
    cudaDestroyTextureObject(texture_object_);
//     );
  }
  CreateTextureObject(address_mode_x, address_mode_y, filter_mode, read_mode,
                      use_normalized_coordinates, &texture_object_);
  texture_object_allocated_ = true;
  address_mode_x_ = address_mode_x;
  address_mode_y_ = address_mode_y;
  filter_mode_ = filter_mode;
  read_mode_ = read_mode;
  use_normalized_coordinates_ = use_normalized_coordinates;
  *texture_object = texture_object_;
}

}  // namespace view_correction

#endif  // VIEW_CORRECTION_CUDA_BUFFER_INL_H_
