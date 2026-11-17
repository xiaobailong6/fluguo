"""Offline structural guards only; these do not compile or exercise mpv/Flutter/ANGLE.

Run with: python -B scripts/test_windows_video_fallback.py
Real Windows backend initialization, failed renders and texture teardown still need
SDK-enabled build/runtime validation. No network, media or third-party modules.
"""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WINDOWS = ROOT / 'packages/media_kit_video/windows'


def source(name):
    # Ignore comments so a safety assertion must be backed by executable code.
    return re.sub(r'//[^\n]*|/\*.*?\*/', '',
                  (WINDOWS / name).read_text(encoding='utf-8'), flags=re.S)


def block(text, marker):
    """Extract a balanced block from the known C++ source (not a C++ parser)."""
    start = text.index('{', text.index(marker))
    depth = 1
    for end in range(start + 1, len(text)):
        depth += (text[end] == '{') - (text[end] == '}')
        if depth == 0:
            return text[start + 1:end]
    raise AssertionError(f'Unclosed block after {marker}')


class WindowsVideoFallbackStructuralTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cc = source('video_output.cc')
        cls.header = source('video_output.h')
        cls.constructor = cls.cc.split('VideoOutput::~VideoOutput()', 1)[0]
        cls.fallback = block(cls.constructor,
                             'if (!is_hardware_acceleration_enabled)')
        cls.render = block(cls.cc, 'void VideoOutput::Render()')

    def assert_order(self, text, *parts):
        cursor = 0
        for part in parts:
            found = text.find(part, cursor)
            self.assertNotEqual(found, -1, f'Missing/out-of-order: {part}')
            cursor = found + len(part)

    def test_hardware_context_precedes_gpu_texture_and_callback(self):
        hardware = block(self.constructor,
                         'if (configuration.enable_hardware_acceleration)')
        self.assert_order(hardware, 'surface_manager_->MakeCurrent(true)',
                          'mpv_render_context_create(', 'if (status == 0)',
                          'Resize(', 'surface_manager_->MakeCurrent(false)',
                          'mpv_render_context_set_update_callback(',
                          'is_hardware_acceleration_enabled = true')
        self.assertEqual(hardware.count('Resize('), 1)
        self.assertIn('Resize(', block(hardware, 'if (status == 0)'))
        self.assertIn('H/W context creation failed:', hardware)
        self.assertIn('mpv_error_string(status)', hardware)
        self.assertIn('catch (const std::exception& error)', hardware)
        self.assertIn('error.what()', hardware)

    def test_fallback_disables_and_frees_gl_before_reset_and_software(self):
        self.assert_order(
            self.fallback, 'if (surface_manager_ != nullptr)',
            'if (render_context_ != nullptr)',
            'mpv_render_context_set_update_callback(render_context_, nullptr,',
            'surface_manager_->Draw(', 'mpv_render_context_free(render_context_)',
            'render_context_ = nullptr', 'surface_manager_->MakeCurrent(false)',
            'std::lock_guard<std::mutex> lock(textures_mutex_)',
            'surface_manager_.reset()', 'pixel_buffer_ =', 'Resize(',
            'MPV_RENDER_API_TYPE_SW', 'mpv_render_context_create(')
        # Resize owns generation invalidation, descriptors and async unregistration.
        for forbidden in ('texture_id_ =', '.clear()', 'UnregisterTexture(',
                          'texture_generation_ ='):
            self.assertNotIn(forbidden, self.fallback)

    def test_software_context_errors_are_logged_without_callback(self):
        self.assert_order(self.fallback, 'mpv_render_context_create(',
                          'if (status == 0)',
                          'mpv_render_context_set_update_callback(',
                          '} else {', 'S/W context creation failed:',
                          'mpv_error_string(status)')
        success = block(self.fallback, 'if (status == 0)')
        self.assertIn('mpv_render_context_set_update_callback(', success)
        self.assertEqual(self.fallback.count(
            'mpv_render_context_set_update_callback('), 2)

    def test_render_has_one_backend_and_only_notifies_after_success(self):
        guard = block(self.render, 'if (destroyed_')
        self.assertIn('texture_id_ <= 0', self.render.split('{', 1)[0])
        self.assertIn('render_context_ == nullptr', self.render.split('{', 1)[0])
        self.assertIn('return;', guard)
        self.assertIn('int status = MPV_ERROR_GENERIC;', self.render)
        self.assertIn('} else if (pixel_buffer_ != nullptr)', self.render)
        self.assertEqual(self.render.count('mpv_render_context_render('), 2)
        self.assertEqual(self.render.count(
            'status = mpv_render_context_render(render_context_, params);'), 2)
        failure = block(self.render, 'if (status < 0)')
        self.assertIn('return;', failure)
        self.assertNotIn('MarkTextureFrameAvailable', failure)
        self.assertIn('} else {\n    return;\n  }', self.render)
        self.assert_order(self.render, 'if (status < 0)',
                          'mpv_error_string(status)', 'return;',
                          'MarkTextureFrameAvailable(texture_id_)')
        self.assertEqual(self.render.count('MarkTextureFrameAvailable('), 1)

    def test_render_diagnostics_are_bounded_per_output(self):
        self.assertIn('bool render_error_logged_ = false;', self.header)
        log = block(self.render, 'if (!render_error_logged_)')
        self.assert_order(log, 'render_error_logged_ = true;',
                          'mpv_error_string(status)')
        self.assertNotIn('render_error_logged_ = false', self.cc)
        self.assertEqual(self.render.count('mpv_error_string('), 1)

    def test_generation_descriptors_and_pending_unregister_are_retained(self):
        resize = block(self.cc, 'void VideoOutput::Resize(')
        self.assert_order(resize, 'generation = ++texture_generation_',
                          'if (texture_id_ > 0)',
                          '++pending_texture_unregistrations_',
                          'UnregisterTexture(', '--pending_texture_unregistrations_',
                          'textures_unregistered_.notify_all()', 'texture_id_ = 0')
        gpu = block(resize, '[this, texture, generation](auto, auto)')
        self.assert_order(gpu, 'std::lock_guard<std::mutex> lock(textures_mutex_)',
                          'generation != texture_generation_',
                          'surface_manager_ == nullptr',
                          'return (FlutterDesktopGpuSurfaceDescriptor*)nullptr',
                          'surface_manager_->Read()', 'return texture.get()')
        sw = block(resize, '[this, pixel_buffer_texture, generation](auto, auto)')
        self.assert_order(sw, 'generation != texture_generation_',
                          'return (FlutterDesktopPixelBuffer*)nullptr',
                          'return pixel_buffer_texture.get()')

    def test_teardown_worker_lifetime_and_software_caps_are_retained(self):
        destructor = block(self.cc, 'VideoOutput::~VideoOutput()')
        self.assertIn('std::atomic<bool> destroyed_{false};', self.header)
        self.assertEqual(destructor.count('->Post('), 2)
        self.assert_order(destructor, 'destroyed_ = true', '->Post(',
                          'mpv_render_context_set_update_callback(',
                          'surface_manager_->Draw(', 'mpv_render_context_free(',
                          '.wait()', 'if (texture_id_ > 0)', 'UnregisterTexture(',
                          'textures_unregistered_.wait(',
                          'pending_texture_unregistrations_ == 0',
                          '->Post(', 'texture_variants_.clear()',
                          'surface_manager_.reset()', '.wait()')
        notify = block(self.cc, 'void VideoOutput::NotifyRender()')
        self.assert_order(notify, 'if (destroyed_)', 'return;',
                          'Post(std::bind(&VideoOutput::CheckAndResize, this))',
                          'Post(std::bind(&VideoOutput::Render, this))')
        self.assertIn('#define SW_RENDERING_MAX_WIDTH 1920', self.cc)
        self.assertIn('#define SW_RENDERING_MAX_HEIGHT 1080', self.cc)
        self.assertIn('std::make_unique<uint8_t[]>(SW_RENDERING_PIXEL_BUFFER_SIZE)',
                      self.fallback)
        self.assertIn('std::clamp(width.value()', self.cc)
        self.assertIn('std::clamp(height.value()', self.cc)


if __name__ == '__main__':
    unittest.main()
