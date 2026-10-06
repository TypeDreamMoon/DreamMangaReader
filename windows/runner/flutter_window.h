#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <windows.h>
#include <shellapi.h>

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// 单实例握手用的系统级消息 id。RegisterWindowMessageW 保证全系统唯一:第二个进程
// 广播它,只有本应用的窗口会认,收到就从托盘恢复自己。首次调用时注册,之后返回
// 同一个 id;注册失败返回 0。
UINT ShowExistingInstanceMessage();

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void AddTrayIcon();
  void RemoveTrayIcon();
  void ShowFromTray();
  void ShowTrayMenu();
  void ExitFromTray();
  HWND FlutterViewWindow() const;
  void RestoreCursor(HWND target);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;
  NOTIFYICONDATAW tray_icon_{};
  UINT taskbar_created_message_ = 0;
  bool tray_icon_added_ = false;
  bool close_to_tray_ = true;
  bool close_behavior_ready_ = false;
  bool pending_close_ = false;
  bool force_quit_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
