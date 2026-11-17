"""Offline source-structure guards, not a Windows/Flutter build or runtime test.

Run: python -B scripts/test_windows_fullscreen.py
Taskbar coverage, DWM animation, multi-monitor DPI and PiP still need a Windows
SDK-enabled build and manual runtime validation. No network or media requests.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def source(path):
    return re.sub(r'//[^\n]*|/\*.*?\*/', '',
                  (ROOT / path).read_text(encoding='utf-8'), flags=re.S)


def block(text, marker):
    start = text.index('{', text.index(marker))
    depth = 1
    for end in range(start + 1, len(text)):
        depth += (text[end] == '{') - (text[end] == '}')
        if depth == 0:
            return text[start + 1:end]
    raise AssertionError(f'Unclosed block: {marker}')


class WindowsFullscreenStructuralTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cpp = source('windows/runner/flutter_window.cpp')
        cls.header = source('windows/runner/flutter_window.h')
        cls.full = block(cls.cpp, 'bool FlutterWindow::SetFullScreen(')

    def assert_order(self, text, *parts):
        cursor = 0
        for part in parts:
            found = text.find(part, cursor)
            self.assertNotEqual(found, -1, f'Missing/out-of-order: {part}')
            cursor = found + len(part)

    def test_snapshot_and_monitor_checks_precede_mutations(self):
        self.assertIn('WINDOWPLACEMENT placement_before_fullscreen_{};', self.header)
        self.assertNotIn('frame_before_fullscreen_', self.cpp + self.header)
        self.assert_order(self.full, 'previous.length = sizeof(previous)',
                          '!GetWindowPlacement(window, &previous)',
                          '!GetWindowRect(window, &frame)', '!GetMonitorInfo(',
                          'GetWindowLongPtr(window, GWL_STYLE)',
                          'SuppressWindowTransitions()', 'SetWindowStyle(')
        self.assertIn('if (style == 0 && GetLastError() != ERROR_SUCCESS)', self.full)

    def test_maximize_bit_cleared_before_full_monitor_position(self):
        enter = block(self.full, 'if (enabled)')
        self.assert_order(enter, 'style & ~static_cast<LONG_PTR>(WS_MAXIMIZE)',
                          'fullscreen_ = true', 'monitor.rcMonitor',
                          'if (SetWindowPos(', 'placement_before_fullscreen_ = previous')
        self.assertNotIn('rcWork', enter)
        self.assertNotIn('ShowWindow(', self.full)
        self.assertNotIn('WS_CAPTION', self.full)
        self.assertNotIn('WS_THICKFRAME', self.full)

    def test_exit_uses_placement_and_keeps_z_order(self):
        self.assert_order(self.full, '} else {', 'fullscreen_ = false',
                          'SetWindowPlacement(window, &placement_before_fullscreen_)',
                          'SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER',
                          'fullscreen_ = true')
        self.assertNotIn('HWND_TOPMOST', self.full)
        self.assertNotIn('HWND_NOTOPMOST', self.full)
        self.assertEqual(self.full.count('SetWindowPos('), 3)
        self.assertEqual(self.full.count('SWP_NOZORDER'), 3)

    def test_dwm_original_value_restored_and_failure_is_retryable(self):
        suppress = block(self.cpp, 'void FlutterWindow::SuppressWindowTransitions()')
        restore = block(self.cpp, 'void FlutterWindow::RestoreWindowTransitions()')
        self.assert_order(suppress, 'if (restore_transitions_pending_) return',
                          'DwmGetWindowAttribute(', 'return;',
                          'const BOOL disabled = TRUE', 'SUCCEEDED(DwmSetWindowAttribute(',
                          'transitions_before_fullscreen_ = previous',
                          'restore_transitions_pending_ = true')
        self.assert_order(restore, 'if (!restore_transitions_pending_) return',
                          'SUCCEEDED(DwmSetWindowAttribute(',
                          '&transitions_before_fullscreen_',
                          'restore_transitions_pending_ = false')
        failure = restore.split('} else {', 1)[1]
        self.assertNotIn('restore_transitions_pending_ = false', failure)
        self.assertEqual(self.full.count('RestoreWindowTransitions()'), 2)
        self.assert_order(self.full, 'SuppressWindowTransitions()',
                          'const bool changed = [&]()', '}();',
                          'RestoreWindowTransitions()', 'return changed')
        self.assertIn('RestoreWindowTransitions()', block(self.cpp, 'void FlutterWindow::OnDestroy()'))
        self.assertIn('"dwmapi.lib"', (ROOT / 'windows/runner/CMakeLists.txt').read_text())

    def test_api_failures_roll_back_and_reach_dart_error_path(self):
        helper = block(self.cpp, 'bool SetWindowStyle(')
        self.assert_order(helper, 'SetLastError(ERROR_SUCCESS)',
                          'SetWindowLongPtr(', 'GetLastError() == ERROR_SUCCESS')
        self.assert_order(self.full, 'SetWindowStyle(window, style)',
                          'SetWindowPlacement(window, &previous)',
                          'const bool frame_restored = SetWindowPos(',
                          'if (!style_restored || !placement_restored || !frame_restored)')
        channel = block(self.cpp, 'if (call.method_name() == "setFullScreen")')
        self.assertIn('if (!SetFullScreen(*enabled))', channel)
        self.assertIn('result->Error("window_transition"', channel)
        dart = source('lib/ui/player/window_fullscreen.dart')
        self.assertIn('fullScreenRequested(previous)', dart)
        self.assertIn('WindowOnTop.instance.restore()', dart)

    def test_repeated_requests_do_not_overwrite_snapshot(self):
        repeated = block(self.full, 'if (enabled == fullscreen_)')
        self.assertIn('return true;', repeated)
        self.assertNotIn('placement_before_fullscreen_', repeated)
        self.assert_order(self.full, 'if (enabled == fullscreen_)', 'GetWindowPlacement(')
        mark = block(self.cpp, 'void FlutterWindow::UpdateFullscreenMark()')
        self.assertIn('SUCCEEDED(taskbar_->MarkFullscreenWindow(GetHandle(), fullscreen_))', mark)
        self.assertIn('UpdateFullscreenMark()', repeated)
        self.assertIn('if (changed) fullscreen_mark_pending_ = true', self.full)

    def test_mini_transitions_keep_independent_placement_and_failure_retry(self):
        mini_intent = block(self.full, 'if (mini_)')
        self.assertIn('fullscreen_before_mini_ = enabled', mini_intent)
        self.assertNotIn('SetWindowPos', mini_intent)
        enter = block(self.cpp, 'bool FlutterWindow::EnterMiniWindow(')
        leave = block(self.cpp, 'flutter::EncodableValue FlutterWindow::ExitMiniWindow(')
        self.assert_order(enter, 'fullscreen_before_mini_ = fullscreen_',
                          'if (fullscreen_ && !SetFullScreen(false))',
                          'return false', 'placement_before_mini_.length',
                          'SetWindowPos(window, HWND_TOPMOST')
        self.assert_order(leave, 'mini_ = false', 'HWND_NOTOPMOST',
                          'SetWindowPlacement(window, &placement_before_mini_)',
                          'fullscreen_before_mini_ && !SetFullScreen(true)',
                          'mini_ = true', 'HWND_TOPMOST', '*restored = false')
        for key in ('left', 'top', 'extent'):
            self.assertIn(f'flutter::EncodableValue("{key}")', leave)
        self.assertIn('if ((fullscreen_ || mini_) && wparam)', self.cpp)


if __name__ == '__main__':
    unittest.main()
