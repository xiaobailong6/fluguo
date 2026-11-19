"""Offline Android source contract checks for Xanerix/guoapp@3b16654c1e."""
import re
import unittest
from pathlib import Path
from xml.etree import ElementTree

MAIN = Path(__file__).resolve().parents[1] / 'app/src/main'
NATIVE = MAIN / 'kotlin/com/duanju/duanju_app'
ANDROID = '{http://schemas.android.com/apk/res/android}'


class MediaContract(unittest.TestCase):
    def test_wire_contract(self):
        code = (NATIVE / 'MediaControls.kt').read_text(encoding='utf-8')
        self.assertIn('MethodChannel(messenger, "duanju/media")', code)
        self.assertIn('"update" ->', code)
        self.assertIn('"clear" ->', code)
        self.assertEqual(set(re.findall(r'args\["(\w+)"\]', code)), {
            'title', 'subtitle', 'artwork', 'active', 'playing', 'positionMs',
            'durationMs', 'rate', 'hasPrevious', 'hasNext',
        })
        self.assertRegex(code, r'invokeMethod\(\s*"command",')
        self.assertIn('arguments["positionMs"] = positionMs', code)
        self.assertIn('onSeekTo(pos: Long) = send("seek", pos)', code)

    def test_interruption_resume_is_tagged_and_cancelable(self):
        code = (NATIVE / 'MediaControls.kt').read_text(encoding='utf-8')
        self.assertIn('"cancelResume" ->', code)
        self.assertIn('send("pause", interruptionId = interruptionId)', code)
        self.assertIn('send("play", interruptionId = interruptionId)', code)
        self.assertIn('arguments["interruptionId"] = interruptionId', code)
        self.assertRegex(code, r'if \(interruptionId == null[^\n]*\) \{\s*resumeOnFocus = false')
        self.assertIn('toInt() == interruptionId', code)

    def test_apple_interruption_uses_same_token(self):
        code = (MAIN.parents[3] / 'ios/Runner/AppDelegate.swift').read_text(encoding='utf-8')
        self.assertIn('case "cancelResume":', code)
        self.assertIn('id.intValue == self?.interruptionID', code)
        self.assertIn('self.send("pause", interruptionID: self.interruptionID)', code)
        self.assertIn('self.send("play", interruptionID: self.interruptionID)', code)
        self.assertIn('arguments["interruptionId"] = interruptionID', code)

    def test_manifest_coexistence(self):
        root = ElementTree.parse(MAIN / 'AndroidManifest.xml')
        services = {s.get(ANDROID + 'name'): s for s in root.findall('application/service')}
        for name, kind in [('.PlaybackService', 'mediaPlayback'),
                           ('com.pravera.flutter_foreground_task.service.ForegroundService', 'dataSync')]:
            self.assertEqual(services[name].get(ANDROID + 'foregroundServiceType'), kind)
            self.assertEqual(services[name].get(ANDROID + 'exported'), 'false')
        permissions = {p.get(ANDROID + 'name') for p in root.findall('uses-permission')}
        self.assertTrue({'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK',
                         'android.permission.FOREGROUND_SERVICE_DATA_SYNC'} <= permissions)
        activity = root.find(f'application/activity[@{ANDROID}name=".MainActivity"]')
        self.assertEqual(activity.get(ANDROID + 'supportsPictureInPicture'), 'true')


if __name__ == '__main__':
    unittest.main()
