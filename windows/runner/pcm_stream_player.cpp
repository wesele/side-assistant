#include "pcm_stream_player.h"

#include <algorithm>

PcmStreamPlayer::PcmStreamPlayer(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.sideassistant.side_assistant/pcm_player",
      &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto& method = call.method_name();
        if (method == "feed") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (!args) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          int sample_rate = 24000;
          auto sr_it = args->find(flutter::EncodableValue("sampleRate"));
          if (sr_it != args->end()) {
            if (const auto* sr = std::get_if<int32_t>(&sr_it->second)) {
              sample_rate = *sr;
            }
          }
          auto bytes_it = args->find(flutter::EncodableValue("bytes"));
          if (bytes_it != args->end()) {
            if (const auto* bytes =
                    std::get_if<std::vector<uint8_t>>(&bytes_it->second)) {
              FeedPcm(*bytes, sample_rate);
              result->Success(flutter::EncodableValue(true));
              return;
            }
          }
          result->Success(flutter::EncodableValue(false));
        } else if (method == "stop") {
          StopImmediate();
          result->Success(flutter::EncodableValue(true));
        } else if (method == "isPlaying") {
          std::lock_guard<std::mutex> lock(mutex_);
          ReclaimFinishedChunksLocked();
          result->Success(flutter::EncodableValue(!active_chunks_.empty()));
        } else {
          result->NotImplemented();
        }
      });
}

PcmStreamPlayer::~PcmStreamPlayer() {
  std::lock_guard<std::mutex> lock(mutex_);
  CloseWaveOutLocked();
}

bool PcmStreamPlayer::EnsureWaveOutLocked(int sample_rate) {
  if (wave_out_ != nullptr && current_sample_rate_ == sample_rate) {
    return true;
  }
  CloseWaveOutLocked();

  WAVEFORMATEX wfx{};
  wfx.wFormatTag = WAVE_FORMAT_PCM;
  wfx.nChannels = 1;
  wfx.nSamplesPerSec = static_cast<DWORD>(sample_rate);
  wfx.wBitsPerSample = 16;
  wfx.nBlockAlign = (wfx.nChannels * wfx.wBitsPerSample) / 8;
  wfx.nAvgBytesPerSec = wfx.nSamplesPerSec * wfx.nBlockAlign;
  wfx.cbSize = 0;

  MMRESULT res = waveOutOpen(&wave_out_, WAVE_MAPPER, &wfx, 0, 0, CALLBACK_NULL);
  if (res != MMSYSERR_NOERROR) {
    wave_out_ = nullptr;
    return false;
  }
  current_sample_rate_ = sample_rate;
  return true;
}

void PcmStreamPlayer::ReclaimFinishedChunksLocked() {
  if (!wave_out_) {
    active_chunks_.clear();
    return;
  }
  auto it = active_chunks_.begin();
  while (it != active_chunks_.end()) {
    auto& chunk = *it;
    if (chunk->header.dwFlags & WHDR_DONE) {
      if (chunk->prepared) {
        waveOutUnprepareHeader(wave_out_, &chunk->header, sizeof(WAVEHDR));
        chunk->prepared = false;
      }
      it = active_chunks_.erase(it);
    } else {
      ++it;
    }
  }
}

void PcmStreamPlayer::FeedPcm(const std::vector<uint8_t>& pcm_bytes,
                              int sample_rate) {
  if (pcm_bytes.empty()) return;
  std::lock_guard<std::mutex> lock(mutex_);
  if (!EnsureWaveOutLocked(sample_rate)) return;
  ReclaimFinishedChunksLocked();

  auto chunk = std::make_unique<AudioChunk>();
  chunk->data = pcm_bytes;
  ZeroMemory(&chunk->header, sizeof(WAVEHDR));
  chunk->header.lpData = reinterpret_cast<LPSTR>(chunk->data.data());
  chunk->header.dwBufferLength = static_cast<DWORD>(chunk->data.size());

  if (waveOutPrepareHeader(wave_out_, &chunk->header, sizeof(WAVEHDR)) !=
      MMSYSERR_NOERROR) {
    return;
  }
  chunk->prepared = true;
  if (waveOutWrite(wave_out_, &chunk->header, sizeof(WAVEHDR)) !=
      MMSYSERR_NOERROR) {
    waveOutUnprepareHeader(wave_out_, &chunk->header, sizeof(WAVEHDR));
    return;
  }
  active_chunks_.push_back(std::move(chunk));
}

void PcmStreamPlayer::StopImmediate() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!wave_out_) return;
  waveOutReset(wave_out_);
  for (auto& chunk : active_chunks_) {
    if (chunk->prepared) {
      waveOutUnprepareHeader(wave_out_, &chunk->header, sizeof(WAVEHDR));
      chunk->prepared = false;
    }
  }
  active_chunks_.clear();
}

void PcmStreamPlayer::CloseWaveOutLocked() {
  if (!wave_out_) return;
  waveOutReset(wave_out_);
  for (auto& chunk : active_chunks_) {
    if (chunk->prepared) {
      waveOutUnprepareHeader(wave_out_, &chunk->header, sizeof(WAVEHDR));
      chunk->prepared = false;
    }
  }
  active_chunks_.clear();
  waveOutClose(wave_out_);
  wave_out_ = nullptr;
  current_sample_rate_ = 0;
}
