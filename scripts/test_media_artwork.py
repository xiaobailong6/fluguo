"""Offline Windows artwork guards plus an optional compiled C++17 helper test.

Run: python -B scripts/test_media_artwork.py
Set CXX to a compiler executable (not flags), or put c++/g++/clang++/cl on PATH.
Build outputs use PI_SCRATCH_DIR, or the OS temporary directory, never the tree.
Missing compiler => explicit skip, not a native pass. Even a compiled helper pass
is NOT a Windows/Flutter/WinRT build or an SMTC integration/runtime test.
"""

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CPP_TEST = ROOT / 'windows/tests/media_artwork_state_test.cpp'


def source(path):
    return re.sub(r'//[^\n]*|/\*.*?\*/', '',
                  (ROOT / path).read_text(encoding='utf-8'), flags=re.S)


def block(text, marker):
    """Balanced blocks in these known sources; not a general C++ parser."""
    start = text.index('{', text.index(marker))
    depth = 1
    for end in range(start + 1, len(text)):
        depth += (text[end] == '{') - (text[end] == '}')
        if not depth:
            return text[start + 1:end]
    raise AssertionError(f'Unclosed block after {marker}')


class MediaArtworkStructureTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cpp = source('windows/runner/media_controls.cpp')
        cls.header = source('windows/runner/media_controls.h')
        cls.state = source('windows/runner/media_artwork_state.h')
        cls.update = block(cls.cpp, 'void MediaControls::Update(')
        cls.callback = block(cls.update, '.Completed(')
        cls.prepare = block(cls.update, 'artwork_state_->Update(')

    def assert_order(self, text, *parts):
        cursor = 0
        for part in parts:
            found = text.find(part, cursor)
            self.assertNotEqual(found, -1, f'Missing/out-of-order: {part}')
            cursor = found + len(part)

    def test_shared_portable_state_is_used_by_production(self):
        self.assertIn('#include "media_artwork_state.h"', self.header)
        self.assertIn('using ArtworkState = MediaArtworkState<', self.header)
        self.assertIn('SystemMediaTransportControlsDisplayUpdater>', self.header)
        self.assertIn('std::shared_ptr<ArtworkState> artwork_state_', self.header)
        self.assertIn('std::make_shared<ArtworkState>()', self.header)
        self.assertNotIn('std::string artwork_;', self.header)
        self.assertNotRegex(self.state, r'winrt::|#include.*[Ww]indows')

    def test_completion_captures_shared_state_not_owner_or_updater(self):
        captures = re.findall(r'\.Completed\(\[([^\]]*)\]', self.update)
        self.assertEqual(captures, ['state = artwork_state_, request'])
        self.assertNotRegex(self.callback, r'\bthis\b|controls_|artwork_state_')
        apply = block(self.callback, 'state->Complete(request,')
        self.assert_order(apply, 'updater.Thumbnail(thumbnail)', 'updater.Update()')
        self.assertEqual(self.callback.count('updater.Thumbnail('), 1)
        self.assertEqual(self.callback.count('updater.Update()'), 1)
        self.assertNotIn('DisplayUpdater()', self.callback)

    def test_token_identity_changes_before_preparation_including_empty_path(self):
        update = block(self.state, 'Token Update(')
        self.assertIn('using Token = std::shared_ptr<const Generation>;', self.state)
        self.assert_order(update, 'std::lock_guard<std::mutex> lock(mutex_)',
                          'if (closed_) return {}', 'const bool changed = path != path_',
                          'token_ = path.empty() ? Token{} : std::make_shared<Generation>()',
                          'path_ = path', 'target_.reset()', 'target_ = prepare(changed)',
                          'return changed ? token_ : Token{}')
        self.assertIn('if (changed) updater.Thumbnail(nullptr)', self.prepare)

    def test_check_and_apply_share_the_invalidation_mutex(self):
        complete = block(self.state, 'bool Complete(')
        self.assert_order(complete, 'std::lock_guard<std::mutex> lock(mutex_)',
                          'if (closed_ || !token || token != token_ || !target_) return false',
                          'apply(*target_)', 'return true')
        # The lock is function-scoped, not a nested check-only scope.
        self.assertNotIn('{', complete)
        for method in ('Token Update(', 'void Clear(', 'void Close('):
            self.assertIn('std::lock_guard<std::mutex> lock(mutex_)',
                          block(self.state, method))
        self.assertNotRegex(self.state, r'\b(?:atomic|unlock)\b')

    def test_clear_invalidates_before_fallible_display_reset(self):
        clear = block(self.state, 'void Clear(')
        self.assert_order(clear, 'std::lock_guard<std::mutex> lock(mutex_)',
                          'InvalidateLocked()', 'clear_display()')
        invalidate = block(self.state, 'void InvalidateLocked(')
        for reset in ('token_.reset()', 'target_.reset()', 'path_.clear()'):
            self.assertIn(reset, invalidate)
        owner_clear = block(self.cpp, 'void MediaControls::Clear()')
        self.assert_order(owner_clear, 'artwork_state_->Clear(',
                          'if (!controls_) return', 'try {',
                          'controls_.PlaybackStatus(MediaPlaybackStatus::Closed)',
                          'controls_.DisplayUpdater().ClearAll()',
                          'controls_.DisplayUpdater().Update()',
                          'controls_.IsEnabled(false)',
                          'catch (const winrt::hresult_error&)')

    def test_destruction_closes_before_early_return_and_releases_target(self):
        destructor = block(self.cpp, 'MediaControls::~MediaControls()')
        self.assert_order(destructor, 'artwork_state_->Close()',
                          'channel_->SetMethodCallHandler(nullptr)',
                          'if (!controls_) return', 'Clear()',
                          'controls_.ButtonPressed(button_token_)')
        close = block(self.state, 'void Close()')
        self.assert_order(close, 'std::lock_guard<std::mutex> lock(mutex_)',
                          'closed_ = true', 'InvalidateLocked()')
        self.assertIn('bool closed_ = false;', self.state)
        self.assertEqual(self.state.count('closed_ = false'), 1)
        self.assertNotIn('Target', self.callback)

    def test_async_registration_is_outside_lock_and_empty_requests_do_not_fetch(self):
        self.assertNotIn('GetFileFromPathAsync', self.prepare)
        self.assertNotIn('.Completed(', self.prepare)
        self.assert_order(self.update, 'artwork_state_->Update(', 'return updater;',
                          '});', 'if (request)', 'GetFileFromPathAsync(', '.Completed(')
        fetch = block(self.update, 'if (request)')
        self.assertIn('GetFileFromPathAsync(', fetch)
        self.assert_order(self.callback,
                          'status != winrt::Windows::Foundation::AsyncStatus::Completed',
                          'return;', 'try {', 'CreateFromFile(operation.GetResults())',
                          'state->Complete(request,', 'updater.Thumbnail(thumbnail)',
                          'updater.Update()', 'catch (const winrt::hresult_error&)')

    def test_metadata_playback_timeline_and_exception_guards_are_preserved(self):
        for statement in ('controls_.IsEnabled(true)', 'controls_.IsPlayEnabled(true)',
                          'controls_.IsPauseEnabled(true)', 'controls_.IsStopEnabled(true)',
                          'controls_.IsNextEnabled(BoolArgument(args, "hasNext"))',
                          'controls_.IsPreviousEnabled(BoolArgument(args, "hasPrevious"))',
                          'MediaPlaybackStatus::Playing', 'MediaPlaybackStatus::Paused',
                          'controls_.PlaybackRate(rate > 0 ? rate : 1)',
                          'updater.Type(MediaPlaybackType::Video)',
                          'StringArgument(args, "title")', 'StringArgument(args, "subtitle")',
                          'updater.Update()'):
            self.assertIn(statement, self.prepare)
        for statement in ('timeline.StartTime(std::chrono::milliseconds(0))',
                          'timeline.MinSeekTime(std::chrono::milliseconds(0))',
                          'timeline.EndTime(Milliseconds(duration))',
                          'timeline.MaxSeekTime(Milliseconds(duration))',
                          'timeline.Position(Milliseconds(NumberArgument(args, "positionMs")))',
                          'controls_.UpdateTimelineProperties(timeline)'):
            self.assertIn(statement, self.update)
        self.assertEqual(self.update.count('catch (const winrt::hresult_error&)'), 2)
        self.assert_order(self.update, 'try {', 'artwork_state_->Update(',
                          'controls_.UpdateTimelineProperties(timeline)',
                          'catch (const winrt::hresult_error&)')

    def test_cpp_regressions_use_production_helper_and_cover_lifetime_and_races(self):
        tests = source('windows/tests/media_artwork_state_test.cpp')
        self.assertIn('#include "../runner/media_artwork_state.h"', tests)
        main = block(tests, 'int main()')
        for name in ('OutOfOrderAndAba', 'ClearThenNewOwner',
                     'EmptyPathAndSamePathRefresh', 'OwnerDestruction',
                     'ExceptionsDoNotReviveRequests'):
            self.assertIn(f'{name}();', main)
        for mutation in ('kUpdate', 'kClear', 'kClose'):
            self.assertIn(f'CompletionAndInvalidationAreSerialized(Mutation::{mutation})',
                          main)
        self.assertIn('released.wait()', tests)
        self.assertIn('invalidation.wait_for(', tests)
        self.assertIn('std::async(std::launch::async, late)', tests)
        self.assertIn('weak_updater.expired()', tests)
        self.assertIn('weak_state.expired()', tests)


class MediaArtworkPortableCppTest(unittest.TestCase):
    def test_compile_and_run_production_helper(self):
        configured = os.environ.get('CXX')
        if configured:
            compiler = shutil.which(configured)
            self.assertIsNotNone(compiler, f'CXX executable not found: {configured}')
        else:
            compiler = next((found for name in ('c++', 'g++', 'clang++', 'cl')
                             if (found := shutil.which(name))), None)
        if not compiler:
            self.skipTest('No C++17 compiler on PATH/CXX; ONLY source-structure checks ran')

        scratch = os.environ.get('PI_SCRATCH_DIR') or tempfile.gettempdir()
        with tempfile.TemporaryDirectory(prefix='media-artwork-', dir=scratch) as temp:
            executable = Path(temp) / ('artwork_test.exe' if os.name == 'nt' else 'artwork_test')
            if Path(compiler).stem.lower() in ('cl', 'clang-cl'):
                command = [compiler, '/nologo', '/std:c++17', '/EHsc', '/W4', '/WX',
                           str(CPP_TEST), f'/Fe{executable}',
                           f'/Fo{Path(temp) / "artwork_test.obj"}']
            else:
                command = [compiler, '-std=c++17', '-pthread', '-Wall', '-Wextra',
                           '-Werror', '-pedantic', str(CPP_TEST), '-o', str(executable)]
            built = subprocess.run(command, cwd=temp, capture_output=True, text=True,
                                   errors='replace', timeout=90)
            self.assertEqual(built.returncode, 0,
                             f'Portable helper compile failed:\n{built.stdout}\n{built.stderr}')
            result = subprocess.run([str(executable)], cwd=temp, capture_output=True,
                                    text=True, errors='replace', timeout=20)
            self.assertEqual(result.returncode, 0,
                             f'Portable helper failed:\n{result.stdout}\n{result.stderr}')
            self.assertIn('PASS: 8 portable media artwork test groups', result.stdout)
            print(f'\n{result.stdout.strip()} [compiler: {compiler}]', flush=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
