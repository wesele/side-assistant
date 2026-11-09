#include <windows.h>
#include <winrt/base.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter_tts/flutter_tts_plugin.h>

#include <cstdio>
#include <memory>
#include <string>

namespace {
// Keep the channel alive and report a useful error when Windows speech is
// unavailable. Other plugins and Edge TTS can still initialize normally.
class UnavailableTtsPlugin : public flutter::Plugin {
 public:
  UnavailableTtsPlugin(flutter::BinaryMessenger* messenger, std::string reason)
      : channel_(messenger, "flutter_tts",
                 &flutter::StandardMethodCodec::GetInstance()) {
    channel_.SetMethodCallHandler(
        [reason](const auto& call, auto result) {
          if (call.method_name() == "stop") {
            result->Success(flutter::EncodableValue(1));
            return;
          }
          result->Error("windows_tts_unavailable", reason);
        });
  }

 private:
  flutter::MethodChannel<flutter::EncodableValue> channel_;
};
}  // namespace

extern "C" void SideAssistantRegisterTtsSafely(
    FlutterDesktopPluginRegistrarRef registrar) {
  try {
    FlutterTtsPluginRegisterWithRegistrar(registrar);
  } catch (const winrt::hresult_error& error) {
    const std::string reason = winrt::to_string(error.message());
    fprintf(stderr, "[Windows TTS] Initialization failed: 0x%08X %s\n",
            static_cast<unsigned int>(error.code().value), reason.c_str());
    auto* windows_registrar = flutter::PluginRegistrarManager::GetInstance()
                                  ->GetRegistrar<flutter::PluginRegistrarWindows>(
                                      registrar);
    windows_registrar->AddPlugin(std::make_unique<UnavailableTtsPlugin>(
        windows_registrar->messenger(), reason));
  }
}
