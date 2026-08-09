#include "flutter_window.h"

#include <optional>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {
constexpr UINT kTrayCallbackMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 1;
constexpr UINT kShowWindowCommand = 40001;
constexpr UINT kExitApplicationCommand = 40002;
constexpr char kWindowChannelName[] = "dream_manga_reader/window";
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kWindowChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() != "setCloseToTray") {
          result->NotImplemented();
          return;
        }
        const auto* enabled = std::get_if<bool>(call.arguments());
        if (enabled == nullptr) {
          result->Error("invalid_argument", "Expected a boolean value");
          return;
        }
        close_to_tray_ = *enabled;
        close_behavior_ready_ = true;
        result->Success();
        if (pending_close_ && GetHandle() != nullptr) {
          pending_close_ = false;
          PostMessageW(GetHandle(), WM_CLOSE, 0, 0);
        }
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");
  AddTrayIcon();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
  window_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    tray_icon_added_ = false;
    AddTrayIcon();
    return 0;
  }

  if (message == kTrayCallbackMessage) {
    // NOTIFYICON_VERSION_4 把事件放在 lparam 低位;旧协议直接用整个 lparam,
    // 那些事件 id 都在低 16 位内,所以取低位对两种协议都成立。
    switch (LOWORD(lparam)) {
      case NIN_SELECT:
      case NIN_KEYSELECT:
      case WM_LBUTTONUP:
      case WM_LBUTTONDBLCLK:
        ShowFromTray();
        return 0;
      case WM_RBUTTONUP:
      case WM_CONTEXTMENU:
        ShowTrayMenu();
        return 0;
    }
  }

  if (message == WM_CLOSE && !force_quit_) {
    if (!close_behavior_ready_) {
      pending_close_ = true;
      return 0;
    }
    if (close_to_tray_) {
      ShowWindow(hwnd, SW_HIDE);
      return 0;
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::AddTrayIcon() {
  if (tray_icon_added_ || GetHandle() == nullptr) {
    return;
  }
  tray_icon_ = {};
  tray_icon_.cbSize = sizeof(NOTIFYICONDATAW);
  tray_icon_.hWnd = GetHandle();
  tray_icon_.uID = kTrayIconId;
  tray_icon_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  tray_icon_.uCallbackMessage = kTrayCallbackMessage;
  tray_icon_.hIcon = static_cast<HICON>(LoadImageW(
      GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON, 0,
      0, LR_DEFAULTSIZE | LR_SHARED));
  wcscpy_s(tray_icon_.szTip, L"Dream Manga Reader");
  tray_icon_added_ = Shell_NotifyIconW(NIM_ADD, &tray_icon_) == TRUE;
  if (!tray_icon_added_) {
    return;
  }
  // 不声明版本的话外壳沿用 Win95 的回调协议:左键单击**不产生任何事件**,只有双击
  // 才会回调。用户点一下没反应、只能再点,体感就是「托盘点击要等半天才打开」。
  // NOTIFYICON_VERSION_4 会送 NIN_SELECT(单击)与 WM_CONTEXTMENU(右键)。
  tray_icon_.uVersion = NOTIFYICON_VERSION_4;
  Shell_NotifyIconW(NIM_SETVERSION, &tray_icon_);
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_added_) {
    return;
  }
  Shell_NotifyIconW(NIM_DELETE, &tray_icon_);
  tray_icon_added_ = false;
}

void FlutterWindow::ShowFromTray() {
  const HWND window = GetHandle();
  if (window == nullptr) {
    return;
  }
  // 藏进托盘前如果是最小化状态,SW_SHOW 只会把它「显示成最小化」,得走 SW_RESTORE。
  ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);

  // 前台锁:调用线程不是当前前台线程时 SetForegroundWindow 会被系统拒掉 ——
  // 窗口显示出来却没被激活,WM_ACTIVATE 不来,子视图也就拿不回焦点。
  // 先把自己挂到前台线程的输入队列上再抢,是 Win32 上唯一稳的做法。
  const HWND foreground = GetForegroundWindow();
  const DWORD foreground_thread =
      GetWindowThreadProcessId(foreground, nullptr);
  const DWORD this_thread = GetCurrentThreadId();
  const bool attached =
      foreground_thread != 0 && foreground_thread != this_thread &&
      AttachThreadInput(foreground_thread, this_thread, TRUE) != FALSE;
  SetForegroundWindow(window);
  SetActiveWindow(window);
  if (attached) {
    AttachThreadInput(foreground_thread, this_thread, FALSE);
  }

  // 焦点必须回到 Flutter 视图本身,而不是外层框架窗口:给了框架,键盘输入和指针
  // 状态都留在 Flutter 之外。
  HWND content = FlutterViewWindow();
  SetFocus(content != nullptr ? content : window);
  RestoreCursor(content != nullptr ? content : window);
}

HWND FlutterWindow::FlutterViewWindow() const {
  if (!flutter_controller_ || flutter_controller_->view() == nullptr) {
    return nullptr;
  }
  return flutter_controller_->view()->GetNativeWindow();
}

void FlutterWindow::RestoreCursor(HWND target) {
  // 指针的显示计数是按输入队列记的,只要有一层在窗口隐藏期间把它减到负数,再显示
  // 出来就变成「只有本程序窗口里看不见鼠标」。先拉回非负,并且不要多留计数。
  int count = ShowCursor(TRUE);
  while (count < 0) {
    count = ShowCursor(TRUE);
  }
  if (count > 0) {
    ShowCursor(FALSE);
  }

  // 窗口重新显示时系统不会主动重发 WM_SETCURSOR;指针恰好停在客户区里的话,
  // Flutter 视图就一直不会重新贴上自己的光标。补一发,让它自己刷新。
  POINT cursor{};
  RECT bounds{};
  if (target != nullptr && GetCursorPos(&cursor) &&
      GetWindowRect(GetHandle(), &bounds) && PtInRect(&bounds, cursor)) {
    SendMessageW(target, WM_SETCURSOR, reinterpret_cast<WPARAM>(target),
                 MAKELPARAM(HTCLIENT, WM_MOUSEMOVE));
  }
}

void FlutterWindow::ShowTrayMenu() {
  const HWND window = GetHandle();
  if (window == nullptr) {
    return;
  }
  POINT point{};
  if (!GetCursorPos(&point)) {
    return;
  }
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  AppendMenuW(menu, MF_STRING, kShowWindowCommand, L"显示主窗口");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kExitApplicationCommand, L"退出");
  SetForegroundWindow(window);
  const UINT command = TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, point.x, point.y,
      0, window, nullptr);
  PostMessageW(window, WM_NULL, 0, 0);
  DestroyMenu(menu);
  if (command == kShowWindowCommand) {
    ShowFromTray();
  } else if (command == kExitApplicationCommand) {
    ExitFromTray();
  }
}

void FlutterWindow::ExitFromTray() {
  force_quit_ = true;
  if (GetHandle() != nullptr) {
    DestroyWindow(GetHandle());
  }
}
