#include "flutter_window.h"

#include <dwmapi.h>
#include <algorithm>
#include <cmath>
#include <optional>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr double kMiniExtent = 480;
constexpr double kMiniMinExtent = 200;
constexpr double kMiniMargin = 24;

std::optional<int> IntArgument(const flutter::EncodableMap& args,
                               const char* key) {
  const auto found = args.find(flutter::EncodableValue(key));
  if (found == args.end()) return std::nullopt;
  if (const auto* value = std::get_if<int32_t>(&found->second)) return *value;
  if (const auto* value = std::get_if<int64_t>(&found->second)) {
    return static_cast<int>(*value);
  }
  return std::nullopt;
}

SIZE MiniSize(double aspect, double extent) {
  if (aspect >= 1) {
    return {std::lround(extent), std::lround(extent / aspect)};
  }
  return {std::lround(extent * aspect), std::lround(extent)};
}

double WindowScale(HWND window) {
  return FlutterDesktopGetDpiForHWND(window) / 96.0;
}

// SetWindowLongPtr 的零返回值也可能表示成功，必须同时检查 last error。
bool SetWindowStyle(HWND window, LONG_PTR style) {
  SetLastError(ERROR_SUCCESS);
  return SetWindowLongPtr(window, GWL_STYLE, style) != 0 ||
         GetLastError() == ERROR_SUCCESS;
}

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
  media_controls_ = std::make_unique<MediaControls>(
      GetHandle(), flutter_controller_->engine()->messenger());
  device_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "duanju/device",
          &flutter::StandardMethodCodec::GetInstance());
  device_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "setFullScreen") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          const bool* enabled = nullptr;
          if (args) {
            const auto found = args->find(flutter::EncodableValue("enabled"));
            if (found != args->end()) enabled = std::get_if<bool>(&found->second);
          }
          if (!enabled) {
            result->Error("bad_args", "enabled is required");
            return;
          }
          if (!SetFullScreen(*enabled)) {
            result->Error("window_transition", "Unable to change fullscreen");
          } else {
            result->Success();
          }
          return;
        }
        if (call.method_name() == "setMiniWindow") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          const bool* enabled = nullptr;
          const double* aspect = nullptr;
          if (args) {
            const auto found = args->find(flutter::EncodableValue("enabled"));
            if (found != args->end()) enabled = std::get_if<bool>(&found->second);
            const auto ratio = args->find(flutter::EncodableValue("aspect"));
            if (ratio != args->end()) aspect = std::get_if<double>(&ratio->second);
          }
          if (!enabled || (*enabled && (!aspect || !(*aspect > 0)))) {
            result->Error("bad_args", "enabled and aspect are required");
            return;
          }
          if (!*enabled) {
            bool restored = false;
            auto frame = ExitMiniWindow(&restored);
            if (restored) {
              result->Success(frame);
            } else {
              result->Error("window_transition", "Unable to restore fullscreen");
            }
            return;
          }
          if (!EnterMiniWindow(*aspect, *args)) {
            result->Error("window_transition", "Unable to leave fullscreen");
          } else {
            result->Success();
          }
          return;
        }
        if (call.method_name() != "playbackPower") {
          result->NotImplemented();
          return;
        }
        SYSTEM_POWER_STATUS power{};
        const bool known = GetSystemPowerStatus(&power) != 0;
        MEMORYSTATUSEX memory{};
        memory.dwLength = sizeof(memory);
        const bool memory_known = GlobalMemoryStatusEx(&memory) != 0;
        flutter::EncodableMap values;
        values[flutter::EncodableValue("batterySaver")] =
            flutter::EncodableValue(known && power.SystemStatusFlag == 1);
        values[flutter::EncodableValue("onBattery")] =
            flutter::EncodableValue(!known || power.ACLineStatus != 1);
        values[flutter::EncodableValue("lowMemory")] =
            flutter::EncodableValue(!memory_known || memory.ullTotalPhys < 4ULL * 1024 * 1024 * 1024);
        result->Success(flutter::EncodableValue(values));
      });
  if (FAILED(CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&taskbar_))) ||
      FAILED(taskbar_->HrInit())) {
    taskbar_.Reset();
  }
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::RestoreWindowTransitions() {
  if (!restore_transitions_pending_) return;
  if (SUCCEEDED(DwmSetWindowAttribute(
          GetHandle(), DWMWA_TRANSITIONS_FORCEDISABLED,
          &transitions_before_fullscreen_, sizeof(transitions_before_fullscreen_)))) {
    restore_transitions_pending_ = false;
  } else {
    // 保留原值，重复调用/销毁时重试，不把系统原本禁用动画的状态改为开启。
    OutputDebugString(L"Fullscreen: DWM transition restore failed\n");
  }
}

void FlutterWindow::SuppressWindowTransitions() {
  if (restore_transitions_pending_) return;
  BOOL previous = FALSE;
  if (FAILED(DwmGetWindowAttribute(GetHandle(), DWMWA_TRANSITIONS_FORCEDISABLED,
                                   &previous, sizeof(previous)))) {
    return;  // 无法读取原值时不修改；DWM 不可用不阻止窗口恢复。
  }
  const BOOL disabled = TRUE;
  if (SUCCEEDED(DwmSetWindowAttribute(GetHandle(), DWMWA_TRANSITIONS_FORCEDISABLED,
                                      &disabled, sizeof(disabled)))) {
    transitions_before_fullscreen_ = previous;
    restore_transitions_pending_ = true;
  }
}

void FlutterWindow::UpdateFullscreenMark() {
  if (!taskbar_ || !fullscreen_mark_pending_) return;
  if (SUCCEEDED(taskbar_->MarkFullscreenWindow(GetHandle(), fullscreen_))) {
    fullscreen_mark_pending_ = false;
  } else {
    // COM 标记是辅助提示；不能因此把已成功的窗口几何状态回报为失败。
    OutputDebugString(L"Fullscreen: taskbar mark failed\n");
  }
}

bool FlutterWindow::SetFullScreen(bool enabled) {
  RestoreWindowTransitions();
  if (mini_) {
    // PiP 保持独立尺寸/置顶，退出时再恢复最新的全屏意图。
    fullscreen_before_mini_ = enabled;
    return true;
  }
  if (enabled == fullscreen_) {
    UpdateFullscreenMark();
    return true;
  }
  HWND window = GetHandle();
  WINDOWPLACEMENT previous{};
  previous.length = sizeof(previous);
  RECT frame{};
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  if (!GetWindowPlacement(window, &previous) || !GetWindowRect(window, &frame) ||
      (enabled && !GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST),
                                  &monitor))) {
    return false;
  }
  SetLastError(ERROR_SUCCESS);
  const LONG_PTR style = GetWindowLongPtr(window, GWL_STYLE);
  if (style == 0 && GetLastError() != ERROR_SUCCESS) return false;

  SuppressWindowTransitions();
  const bool changed = [&]() {
    if (enabled) {
      // 最大化会把边界限制在工作区；只清除此位，保留边框及所有其它样式。
      if (!SetWindowStyle(window, style & ~static_cast<LONG_PTR>(WS_MAXIMIZE))) {
        return false;
      }
      fullscreen_ = true;  // WM_NCCALCSIZE 必须在 SetWindowPos 中看到目标状态。
      const RECT& target = monitor.rcMonitor;
      if (SetWindowPos(window, nullptr, target.left, target.top,
                       target.right - target.left, target.bottom - target.top,
                       SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED)) {
        placement_before_fullscreen_ = previous;
        return true;
      }
      fullscreen_ = false;
    } else {
      fullscreen_ = false;
      // WINDOWPLACEMENT 保留 showCmd 和普通窗口位置，不能只恢复最大化矩形。
      if (SetWindowPlacement(window, &placement_before_fullscreen_) &&
          SetWindowPos(window, nullptr, 0, 0, 0, 0,
                       SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                           SWP_NOACTIVATE | SWP_FRAMECHANGED)) {
        return true;
      }
      fullscreen_ = true;
    }
    // 失败后回滚此次过渡，保留快照供重试；任何路径都不改变置顶层级。
    const bool style_restored = SetWindowStyle(window, style);
    const bool placement_restored = SetWindowPlacement(window, &previous) != FALSE;
    const bool frame_restored = SetWindowPos(
        window, nullptr, frame.left, frame.top, frame.right - frame.left,
        frame.bottom - frame.top,
        SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED |
            (fullscreen_ ? 0 : SWP_NOMOVE | SWP_NOSIZE)) != FALSE;
    if (!style_restored || !placement_restored || !frame_restored) {
      OutputDebugString(L"Fullscreen: window rollback failed\n");
    }
    return false;
  }();
  RestoreWindowTransitions();
  if (changed) fullscreen_mark_pending_ = true;
  UpdateFullscreenMark();
  return changed;
}

bool FlutterWindow::EnterMiniWindow(double aspect,
                                   const flutter::EncodableMap& args) {
  HWND window = GetHandle();
  const double scale = WindowScale(window);
  mini_aspect_ = aspect;
  if (mini_) {
    RECT frame;
    GetWindowRect(window, &frame);
    const SIZE size = MiniSize(
        aspect, std::max(frame.right - frame.left, frame.bottom - frame.top));
    SetWindowPos(window, nullptr, 0, 0, size.cx, size.cy,
                 SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    return true;
  }
  fullscreen_before_mini_ = fullscreen_;
  if (fullscreen_ && !SetFullScreen(false)) {
    return false;
  }
  placement_before_mini_.length = sizeof(WINDOWPLACEMENT);
  GetWindowPlacement(window, &placement_before_mini_);
  if (IsZoomed(window)) {
    ShowWindow(window, SW_RESTORE);
  }
  const auto left = IntArgument(args, "left");
  const auto top = IntArgument(args, "top");
  const auto extent = IntArgument(args, "extent");
  RECT target{};
  bool placed = false;
  if (left && top && extent && *extent >= kMiniMinExtent * scale) {
    const SIZE size = MiniSize(aspect, *extent);
    target = {*left, *top, *left + size.cx, *top + size.cy};
    placed = MonitorFromRect(&target, MONITOR_DEFAULTTONULL) != nullptr;
  }
  if (!placed) {
    MONITORINFO monitor{};
    monitor.cbSize = sizeof(monitor);
    GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST),
                   &monitor);
    const SIZE size = MiniSize(aspect, kMiniExtent * scale);
    const LONG margin = std::lround(kMiniMargin * scale);
    target.right = monitor.rcWork.right - margin;
    target.bottom = monitor.rcWork.bottom - margin;
    target.left = target.right - size.cx;
    target.top = target.bottom - size.cy;
  }
  style_before_mini_ = GetWindowLong(window, GWL_STYLE);
  SetWindowLong(window, GWL_STYLE, style_before_mini_ & ~WS_CAPTION);
  mini_ = true;
  SetWindowPos(window, HWND_TOPMOST, target.left, target.top,
               target.right - target.left, target.bottom - target.top,
               SWP_FRAMECHANGED);
  return true;
}

flutter::EncodableValue FlutterWindow::ExitMiniWindow(bool* restored) {
  *restored = true;
  if (!mini_) {
    return flutter::EncodableValue();
  }
  HWND window = GetHandle();
  RECT frame{};
  if (!GetWindowRect(window, &frame)) {
    *restored = false;
    return flutter::EncodableValue();
  }
  mini_ = false;
  const bool window_restored =
      SetWindowStyle(window, style_before_mini_) &&
      SetWindowPos(window, HWND_NOTOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED) &&
      SetWindowPlacement(window, &placement_before_mini_);
  if (!window_restored || (fullscreen_before_mini_ && !SetFullScreen(true))) {
    // 全屏恢复失败时回到原 PiP，Dart 收到错误后仍允许再次退出。
    mini_ = true;
    const bool style_restored = SetWindowStyle(window, style_before_mini_ & ~WS_CAPTION);
    const bool frame_restored = SetWindowPos(
        window, HWND_TOPMOST, frame.left, frame.top, frame.right - frame.left,
        frame.bottom - frame.top, SWP_NOACTIVATE | SWP_FRAMECHANGED) != FALSE;
    if (!style_restored || !frame_restored) {
      OutputDebugString(L"Fullscreen: mini window rollback failed\n");
    }
    *restored = false;
    return flutter::EncodableValue();
  }
  flutter::EncodableMap values;
  values[flutter::EncodableValue("left")] =
      flutter::EncodableValue(static_cast<int32_t>(frame.left));
  values[flutter::EncodableValue("top")] =
      flutter::EncodableValue(static_cast<int32_t>(frame.top));
  values[flutter::EncodableValue("extent")] = flutter::EncodableValue(
      static_cast<int32_t>(std::max(frame.right - frame.left,
                                    frame.bottom - frame.top)));
  return flutter::EncodableValue(values);
}

void FlutterWindow::KeepMiniAspect(WPARAM edge, RECT* frame) {
  double width = frame->right - frame->left;
  double height = frame->bottom - frame->top;
  if (edge == WMSZ_TOP || edge == WMSZ_BOTTOM) {
    width = height * mini_aspect_;
  } else {
    height = width / mini_aspect_;
  }
  const double minimum = kMiniMinExtent * WindowScale(GetHandle());
  const double extent = std::max(width, height);
  if (extent < minimum) {
    width *= minimum / extent;
    height *= minimum / extent;
  }
  if (edge == WMSZ_LEFT || edge == WMSZ_TOPLEFT || edge == WMSZ_BOTTOMLEFT) {
    frame->left = frame->right - std::lround(width);
  } else {
    frame->right = frame->left + std::lround(width);
  }
  if (edge == WMSZ_TOP || edge == WMSZ_TOPLEFT || edge == WMSZ_TOPRIGHT) {
    frame->top = frame->bottom - std::lround(height);
  } else {
    frame->bottom = frame->top + std::lround(height);
  }
}

void FlutterWindow::OnDestroy() {
  RestoreWindowTransitions();
  media_controls_.reset();
  device_channel_.reset();
  taskbar_.Reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
    case MediaControls::kCommandMessage:
      if (media_controls_) media_controls_->HandleCommand(wparam, lparam);
      return 0;
    case WM_NCCALCSIZE:
      if ((fullscreen_ || mini_) && wparam) {
        return 0;
      }
      break;
    case WM_NCACTIVATE:
      if (mini_) {
        return DefWindowProc(hwnd, message, wparam, -1);
      }
      break;
    case WM_SIZING:
      if (mini_) {
        KeepMiniAspect(wparam, reinterpret_cast<RECT*>(lparam));
        return TRUE;
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
