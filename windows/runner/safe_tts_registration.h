#ifndef RUNNER_SAFE_TTS_REGISTRATION_H_
#define RUNNER_SAFE_TTS_REGISTRATION_H_

// Import the original declaration before redirecting the generated call, so
// the wrapper itself is not declared as a DLL import.
#include <flutter_tts/flutter_tts_plugin.h>

extern "C" void SideAssistantRegisterTtsSafely(
    FlutterDesktopPluginRegistrarRef registrar);

#define FlutterTtsPluginRegisterWithRegistrar SideAssistantRegisterTtsSafely

#endif  // RUNNER_SAFE_TTS_REGISTRATION_H_
