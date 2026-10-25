#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  HMONITOR monitor = ::MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi > 0 ? (dpi / 96.0) : 1.0;

  MONITORINFO monitor_info = {};
  monitor_info.cbSize = sizeof(MONITORINFO);
  int logical_screen_width = 1920;
  int logical_screen_height = 1080;
  if (::GetMonitorInfo(monitor, &monitor_info)) {
    const int physical_width =
        monitor_info.rcMonitor.right - monitor_info.rcMonitor.left;
    const int physical_height =
        monitor_info.rcMonitor.bottom - monitor_info.rcMonitor.top;
    logical_screen_width = static_cast<int>(physical_width / scale_factor);
    logical_screen_height = static_cast<int>(physical_height / scale_factor);
  }

  const unsigned int win_width =
      static_cast<unsigned int>(logical_screen_width * 0.30);
  const unsigned int win_height =
      static_cast<unsigned int>(logical_screen_height * 0.80);
  const unsigned int origin_x =
      static_cast<unsigned int>((logical_screen_width - win_width) / 2);
  const unsigned int origin_y =
      static_cast<unsigned int>((logical_screen_height - win_height) / 2);

  FlutterWindow window(project);
  Win32Window::Point origin(origin_x, origin_y);
  Win32Window::Size size(win_width, win_height);
  if (!window.Create(L"side_assistant", origin, size)) {
    return EXIT_FAILURE;
  }
  window.Show();
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
