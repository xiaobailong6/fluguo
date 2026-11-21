// Standalone geometry regression: no Flutter engine or desktop interaction.
// MSVC: cl /std:c++17 /EHsc /utf-8 /DNOMINMAX mini_edge_snap_test.cpp mini_edge_snap.cpp user32.lib
#include "mini_edge_snap.h"
#include <cassert>

using namespace mini_edge_snap;

int main() {
  const RECT screen{0, 0, 1920, 1080};
  const RECT work{0, 0, 1920, 1040};
  assert(DetectEdge({5, 200, 485, 470}, work, 14) == Edge::left);
  assert(DetectEdge({1430, 200, 1910, 470}, work, 14) == Edge::right);
  assert(DetectEdge({700, 10, 1180, 280}, work, 14) == Edge::top);
  assert(DetectEdge({700, 760, 1180, 1030}, work, 14) == Edge::bottom);
  assert(DetectEdge({700, 400, 1180, 670}, work, 14) == Edge::none);
  assert(DetectEdge({700, 400, 1180, 670}, {0, 0, 0, 0}, 14) == Edge::none);

  const RECT snapped = SnappedRect({700, 760, 1180, 1030}, work, Edge::bottom);
  assert(snapped.bottom == 1040 && snapped.top == 770);
  const RECT hidden = HiddenRect(snapped, screen, Edge::bottom, 2);
  // 收到物理屏幕底部，不是任务栏上沿。
  assert(hidden.top == 1078 && hidden.bottom == 1348);
  assert(Contains(HotRect(hidden, screen, 6), {800, 1079}));
  assert(!Contains(HotRect(hidden, screen, 6), {800, 1060}));
  const RECT keep = ExtendedToEdge(Enlarged(snapped, 12), screen, Edge::bottom);
  assert(Contains(keep, {800, 1079})); // 展开后跨任务栏空隙不抖动。
  assert(!Contains(keep, {800, 1080}));

  const RECT negative{-1920, -1080, 0, 0};
  const RECT frame{-1920, -800, -1440, -530};
  const RECT left = HiddenRect(frame, negative, Edge::left, 3);
  assert(left.right == -1917 && left.left == -2397);
  assert(Contains(HotRect(left, negative, 9), {-1920, -700}));
  const RECT clamped = ClampInside({-2200, -1200, -1720, -930}, negative);
  assert(clamped.left == -1920 && clamped.top == -1080);
  assert(clamped.right - clamped.left == 480);

  // 其它方向的展开区同样覆盖屏幕与工作区之间的任务栏。
  assert(ExtendedToEdge({40, 200, 520, 470}, screen, Edge::left).left == 0);
  assert(ExtendedToEdge({1400, 200, 1880, 470}, screen, Edge::right).right == 1920);
  assert(ExtendedToEdge({700, 40, 1180, 310}, screen, Edge::top).top == 0);
  assert(HiddenRect(frame, negative, Edge::left, 0).right == -1919);
  return 0;
}
