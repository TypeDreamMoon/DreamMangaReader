#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {
// 会话级(Local\)命名互斥体:同一用户会话里只允许一份实例。跨会话(切换用户 /
// 远程桌面)各自独立,所以不用 Global\。
constexpr wchar_t kSingleInstanceMutexName[] =
    L"Local\\DreamMangaReaderSingleInstance";
}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // 单实例。本程序关闭默认是「收进托盘」,窗口藏起来时用户很容易再点一次快捷方式:
  // 没有这道闸,就会多出第二个托盘图标、第二份下载队列和第二份云同步,两份还会互相
  // 覆盖同一批持久化文件。已有实例时把它叫回前台,自己直接退出。
  HANDLE instance_mutex =
      ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutexName);
  const bool already_running =
      instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS;
  if (already_running) {
    // 刚被用户启动的这一份大概率握着前台权。先把它让出去,否则已有实例的
    // SetForegroundWindow 会撞上前台锁,窗口显示出来却不激活。
    ::AllowSetForegroundWindow(ASFW_ANY);
    // 广播只送到顶层窗口,隐藏的也算;消息 id 来自 RegisterWindowMessage,
    // 全系统唯一,别的程序不会误认。
    const UINT show_message = ShowExistingInstanceMessage();
    if (show_message != 0) {
      ::PostMessageW(HWND_BROADCAST, show_message, 0, 0);
    }
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

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

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Dream Manga Reader", origin, size)) {
    if (instance_mutex != nullptr) {
      ::CloseHandle(instance_mutex);
    }
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex != nullptr) {
    ::CloseHandle(instance_mutex);
  }
  return EXIT_SUCCESS;
}
