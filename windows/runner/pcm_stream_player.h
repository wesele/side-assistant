#ifndef RUNNER_PCM_STREAM_PLAYER_H_
#define RUNNER_PCM_STREAM_PLAYER_H_

#include <windows.h>
#include <mmsystem.h>
#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <mutex>
#include <vector>

class PcmStreamPlayer {
 public:
  explicit PcmStreamPlayer(flutter::BinaryMessenger* messenger);
  ~PcmStreamPlayer();

  void FeedPcm(const std::vector<uint8_t>& pcm_bytes, int sample_rate);
  void StopImmediate();

 private:
  struct AudioChunk {
    WAVEHDR header{};
    std::vector<uint8_t> data;
    bool prepared = false;
  };

  bool EnsureWaveOutLocked(int sample_rate);
  void ReclaimFinishedChunksLocked();
  void CloseWaveOutLocked();

  std::mutex mutex_;
  HWAVEOUT wave_out_ = nullptr;
  int current_sample_rate_ = 0;
  std::vector<std::unique_ptr<AudioChunk>> active_chunks_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_PCM_STREAM_PLAYER_H_
