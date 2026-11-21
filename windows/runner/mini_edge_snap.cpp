#include "mini_edge_snap.h"

#include <algorithm>
#include <cmath>
#include <utility>

namespace mini_edge_snap {
namespace {
// 拖动时使用目标矩形所属屏幕，不用尚未移动的 HWND，允许穿过显示器接缝。
bool MonitorAreas(const RECT& frame, MONITORINFO* info) {
  info->cbSize = sizeof(*info);
  return GetMonitorInfo(MonitorFromRect(&frame, MONITOR_DEFAULTTONEAREST), info) != FALSE;
}

bool OverlapsOtherMonitor(const RECT& screen, const RECT& rect) {
  struct Search { HMONITOR own; bool found; } search{
      MonitorFromRect(&screen, MONITOR_DEFAULTTONEAREST), false};
  EnumDisplayMonitors(nullptr, &rect,
      [](HMONITOR monitor, HDC, LPRECT, LPARAM data) -> BOOL {
        auto* search = reinterpret_cast<Search*>(data);
        if (monitor == search->own) return TRUE;
        search->found = true;
        return FALSE;
      }, reinterpret_cast<LPARAM>(&search));
  return search.found;
}
}  // namespace

Edge DetectEdge(const RECT& frame, const RECT& work, LONG threshold) {
  const LONG width = work.right - work.left;
  const LONG height = work.bottom - work.top;
  if (width <= 0 || height <= 0) return Edge::none;
  const LONG x_limit = std::min(threshold, width / 3);
  const LONG y_limit = std::min(threshold, height / 3);
  if (frame.right - frame.left <= width &&
      frame.bottom > work.top && frame.top < work.bottom) {
    if (frame.left - work.left <= x_limit) return Edge::left;
    if (work.right - frame.right <= x_limit) return Edge::right;
  }
  if (frame.bottom - frame.top <= height &&
      frame.right > work.left && frame.left < work.right) {
    if (frame.top - work.top <= y_limit) return Edge::top;
    if (work.bottom - frame.bottom <= y_limit) return Edge::bottom;
  }
  return Edge::none;
}

RECT HiddenRect(const RECT& frame, const RECT& screen, Edge edge, LONG strip) {
  const LONG width = frame.right - frame.left;
  const LONG height = frame.bottom - frame.top;
  const LONG safe_strip = std::clamp(strip, LONG{1},
      std::max(LONG{1}, std::min(width, height) / 2));
  RECT target = frame;
  switch (edge) {
    case Edge::left:
      target.right = screen.left + safe_strip;
      target.left = target.right - width;
      break;
    case Edge::right:
      target.left = screen.right - safe_strip;
      target.right = target.left + width;
      break;
    case Edge::top:
      target.bottom = screen.top + safe_strip;
      target.top = target.bottom - height;
      break;
    case Edge::bottom:
      target.top = screen.bottom - safe_strip;
      target.bottom = target.top + height;
      break;
    case Edge::none: break;
  }
  return target;
}

RECT Intersect(const RECT& a, const RECT& b) {
  return {std::max(a.left, b.left), std::max(a.top, b.top),
          std::min(a.right, b.right), std::min(a.bottom, b.bottom)};
}
RECT Enlarged(const RECT& value, LONG margin) {
  return {value.left - margin, value.top - margin,
          value.right + margin, value.bottom + margin};
}
RECT ExtendedToEdge(const RECT& rect, const RECT& screen, Edge edge) {
  RECT result = rect;
  switch (edge) {
    case Edge::left: result.left = std::min(result.left, screen.left); break;
    case Edge::right: result.right = std::max(result.right, screen.right); break;
    case Edge::top: result.top = std::min(result.top, screen.top); break;
    case Edge::bottom: result.bottom = std::max(result.bottom, screen.bottom); break;
    case Edge::none: break;
  }
  return result;
}
RECT HotRect(const RECT& frame, const RECT& screen, LONG hot_zone) {
  return Intersect(Enlarged(Intersect(frame, screen), hot_zone), screen);
}
bool Contains(const RECT& rect, const POINT& point) {
  return point.x >= rect.left && point.x < rect.right &&
         point.y >= rect.top && point.y < rect.bottom;
}
RECT ClampInside(const RECT& frame, const RECT& work) {
  const LONG width = std::min(frame.right - frame.left, work.right - work.left);
  const LONG height = std::min(frame.bottom - frame.top, work.bottom - work.top);
  const LONG left = std::clamp(frame.left, work.left, work.right - width);
  const LONG top = std::clamp(frame.top, work.top, work.bottom - height);
  return {left, top, left + width, top + height};
}
RECT SnappedRect(const RECT& frame, const RECT& work, Edge edge) {
  RECT result = ClampInside(frame, work);
  const LONG width = result.right - result.left;
  const LONG height = result.bottom - result.top;
  switch (edge) {
    case Edge::left: result.left = work.left; result.right = work.left + width; break;
    case Edge::right: result.right = work.right; result.left = work.right - width; break;
    case Edge::top: result.top = work.top; result.bottom = work.top + height; break;
    case Edge::bottom: result.bottom = work.bottom; result.top = work.bottom - height; break;
    case Edge::none: break;
  }
  return result;
}

LONG Controller::Dip(double value) const {
  return static_cast<LONG>(std::lround(value * scale_));
}
bool Controller::IsOuterEdge(const RECT& frame, const MONITORINFO& monitor,
                             Edge edge) const {
  const RECT hidden = HiddenRect(SnappedRect(frame, monitor.rcWork, edge),
                                 monitor.rcMonitor, edge, Dip(2));
  return !OverlapsOtherMonitor(monitor.rcMonitor, hidden);
}
Edge Controller::HideableEdge(const RECT& frame, const MONITORINFO& monitor) const {
  // 过大的小窗不能按缩小后的假矩形检测，否则实际隐藏位置会进入相邻屏幕。
  if (frame.right - frame.left > monitor.rcWork.right - monitor.rcWork.left ||
      frame.bottom - frame.top > monitor.rcWork.bottom - monitor.rcWork.top) return Edge::none;
  const Edge edge = DetectEdge(frame, monitor.rcWork, Dip(14));
  return edge != Edge::none && IsOuterEdge(frame, monitor, edge) ? edge : Edge::none;
}
void Controller::Init(HWND window, std::function<void(bool)> on_hidden,
                      std::function<void()> on_reset,
                      std::function<void(DWORD)> on_error) {
  window_ = window;
  on_hidden_ = std::move(on_hidden);
  on_reset_ = std::move(on_reset);
  on_error_ = std::move(on_error);
}
void Controller::SetScale(double scale) {
  if (std::isfinite(scale) && scale > 0) scale_ = scale;
}
bool Controller::Fail() {
  const DWORD error = GetLastError();
  if (on_error_) on_error_(error);
  return false;
}
bool Controller::MoveTo(const RECT& target) {
  if (SetWindowPos(window_, nullptr, target.left, target.top, 0, 0,
                   SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE)) return true;
  return Fail();
}
bool Controller::SetEnabled(bool enabled) {
  if (enabled_ == enabled) return true;
  if (!enabled && !Reset()) return false;
  enabled_ = enabled;
  return true;
}
bool Controller::SetMiniActive(bool active) {
  if (mini_active_ == active) return true;
  if (!active && !Reset()) return false;
  mini_active_ = active;
  return true;
}
void Controller::StopTimer() {
  if (window_) KillTimer(window_, kTimerId);
}
bool Controller::Reset() {
  // 即便移动失败也先撤销播放凭证；错误不能导致下一次回调恢复旧会话。
  if (on_reset_) on_reset_();
  if (hidden_ && window_) {
    MONITORINFO monitor{};
    if (!MonitorAreas(restore_, &monitor)) return Fail();
    if (!MoveTo(ClampInside(restore_, monitor.rcWork))) return false;
  }
  StopTimer();
  hidden_ = revealed_ = dragging_ = drag_cursor_valid_ = false;
  edge_ = Edge::none;
  return true;
}
void Controller::Dispose() {
  if (on_reset_) on_reset_();
  StopTimer();
  window_ = nullptr;
  hidden_ = revealed_ = false;
}
void Controller::SetDragActive(bool active) {
  dragging_ = active;
  drag_cursor_valid_ = false;
  if (!active || !Active()) return;
  if (hidden_ && !Reset()) return;
  dragging_ = true;
  drag_cursor_valid_ = GetWindowRect(window_, &drag_origin_) && GetCursorPos(&drag_cursor_);
}
bool Controller::Hide(Edge edge, const RECT& frame, const MONITORINFO& monitor) {
  if (!Active() || edge == Edge::none || !IsOuterEdge(frame, monitor, edge)) return false;
  // 先确认有定时器，不能把窗口藏起来后失去唯一的 hover 恢复路径。
  if (!SetTimer(window_, kTimerId, 90, nullptr)) return Fail();
  const RECT restore = SnappedRect(frame, monitor.rcWork, edge);
  if (!MoveTo(HiddenRect(restore, monitor.rcMonitor, edge, Dip(2)))) {
    StopTimer();
    return false;
  }
  restore_ = restore;
  edge_ = edge;
  revealed_ = false;
  const bool changed = !hidden_;
  hidden_ = true;
  if (changed && on_hidden_) on_hidden_(true);
  return true;
}
void Controller::OnDragFinished() {
  dragging_ = false;
  drag_cursor_valid_ = false;
  if (!Active()) return;
  RECT frame{};
  MONITORINFO monitor{};
  if (!GetWindowRect(window_, &frame) || !MonitorAreas(frame, &monitor)) { Fail(); return; }
  const Edge edge = HideableEdge(frame, monitor);
  if (edge == Edge::none) { Reset(); return; }
  if (!hidden_ || edge_ != edge) Hide(edge, frame, monitor);
}
bool Controller::OnMoving(RECT* rect) const {
  if (!Active() || !rect || !drag_cursor_valid_) return false;
  POINT cursor{};
  if (!GetCursorPos(&cursor)) return false;
  // WM_DPICHANGED 可能在跨屏拖动中更新尺寸，不能强行恢复旧 DPI 的大小。
  const LONG width = rect->right - rect->left;
  const LONG height = rect->bottom - rect->top;
  rect->left = drag_origin_.left + cursor.x - drag_cursor_.x;
  rect->top = drag_origin_.top + cursor.y - drag_cursor_.y;
  rect->right = rect->left + width;
  rect->bottom = rect->top + height;
  MONITORINFO monitor{};
  if (!MonitorAreas(*rect, &monitor)) return true;
  const RECT& work = monitor.rcWork;
  const LONG limit = Dip(14);
  if (width <= work.right - work.left) {
    if (rect->left - work.left <= limit && IsOuterEdge(*rect, monitor, Edge::left)) {
      rect->left = work.left; rect->right = work.left + width;
    } else if (work.right - rect->right <= limit && IsOuterEdge(*rect, monitor, Edge::right)) {
      rect->right = work.right; rect->left = work.right - width;
    }
  }
  if (height <= work.bottom - work.top) {
    if (rect->top - work.top <= limit && IsOuterEdge(*rect, monitor, Edge::top)) {
      rect->top = work.top; rect->bottom = work.top + height;
    } else if (work.bottom - rect->bottom <= limit && IsOuterEdge(*rect, monitor, Edge::bottom)) {
      rect->bottom = work.bottom; rect->top = work.bottom - height;
    }
  }
  return true;
}
void Controller::OnTimerTick() {
  if (!Active() || dragging_ || IsIconic(window_) || !IsWindowVisible(window_)) return;
  POINT cursor{};
  RECT frame{};
  MONITORINFO monitor{};
  if (!GetCursorPos(&cursor) || !GetWindowRect(window_, &frame) ||
      !MonitorAreas(restore_, &monitor)) return;
  if (hidden_) {
    if (Contains(HotRect(frame, monitor.rcMonitor, Dip(6)), cursor) && MoveTo(restore_)) {
      hidden_ = false;
      revealed_ = true;
      if (on_hidden_) on_hidden_(false);
    }
    return;
  }
  if (!revealed_) return;
  // 展开区延伸至物理屏幕边缘，跨任务栏空隙时不会反复收起。
  const RECT keep = ExtendedToEdge(Enlarged(frame, Dip(12)), monitor.rcMonitor, edge_);
  if (!Contains(keep, cursor)) Hide(edge_, frame, monitor);
}
}  // namespace mini_edge_snap
