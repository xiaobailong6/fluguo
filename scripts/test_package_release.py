import ast
from pathlib import Path
import subprocess
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts' / 'package_release.py'


class MacOSSigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # 脚本在模块顶层解析参数并打包；只加载被测函数，避免创建 dist 或执行构建。
        tree = ast.parse(SCRIPT.read_text(encoding='utf-8'), filename=str(SCRIPT))
        functions = [node for node in tree.body
                     if isinstance(node, ast.FunctionDef)
                     and node.name in {'run', 'sign_macos_application'}]
        if len(functions) != 2:
            raise AssertionError('Missing release signing functions')
        namespace = {'root': ROOT, 'subprocess': subprocess}
        exec(compile(ast.Module(body=functions, type_ignores=[]), str(SCRIPT), 'exec'),
             namespace)
        cls.sign_application = staticmethod(namespace['sign_macos_application'])

    def setUp(self):
        self.application = ROOT / 'mock bundle' / 'FlGuo.app'
        self.frameworks = self.application / 'Contents' / 'Frameworks'
        self.app_framework = self.frameworks / 'App.framework'
        self.flutter_framework = self.frameworks / 'FlutterMacOS.framework'
        self.entitlements = ROOT / 'macos' / 'Runner' / 'Release.entitlements'

    def assert_signing_commands(self, identity, flags):
        # 故意逆序返回框架，验证排序以及 frameworks -> app 的签名顺序。
        with mock.patch.object(Path, 'glob', autospec=True,
                               return_value=[self.flutter_framework, self.app_framework]) as glob, \
             mock.patch.object(subprocess, 'run') as command:
            self.sign_application(self.application, identity)
        glob.assert_called_once_with(self.frameworks, '*')
        self.assertEqual(command.call_args_list, [
            mock.call(flags + [str(self.app_framework)], cwd=None, check=True),
            mock.call(flags + [str(self.flutter_framework)], cwd=None, check=True),
            mock.call(flags + ['--entitlements', str(self.entitlements),
                               str(self.application)], cwd=None, check=True),
        ])
        # 权限只附加到 app，不向框架传递，也不使用 --deep 扩大签名范围。
        for invocation in command.call_args_list[:-1]:
            self.assertNotIn('--entitlements', invocation.args[0])
        for invocation in command.call_args_list:
            self.assertNotIn('--deep', invocation.args[0])

    def test_default_ad_hoc_signing(self):
        self.assert_signing_commands('', ['codesign', '--force', '--sign', '-'])

    def test_explicit_ad_hoc_signing(self):
        self.assert_signing_commands('-', ['codesign', '--force', '--sign', '-'])

    def test_developer_id_enables_hardened_runtime_and_timestamp(self):
        identity = 'Developer ID Application: Example (TEAM123456)'
        self.assert_signing_commands(identity, [
            'codesign', '--force', '--sign', identity,
            '--options', 'runtime', '--timestamp',
        ])

    def test_application_without_frameworks_still_gets_entitlements(self):
        with mock.patch.object(Path, 'glob', return_value=[]), \
             mock.patch.object(subprocess, 'run') as command:
            self.sign_application(self.application, '')
        command.assert_called_once_with([
            'codesign', '--force', '--sign', '-', '--entitlements',
            str(self.entitlements), str(self.application),
        ], cwd=None, check=True)

    def test_framework_failure_stops_before_signing_application(self):
        failure = subprocess.CalledProcessError(1, ['codesign'])
        with mock.patch.object(Path, 'glob', return_value=[self.app_framework]), \
             mock.patch.object(subprocess, 'run', side_effect=failure) as command:
            with self.assertRaises(subprocess.CalledProcessError):
                self.sign_application(self.application, '')
        command.assert_called_once_with([
            'codesign', '--force', '--sign', '-', str(self.app_framework),
        ], cwd=None, check=True)


if __name__ == '__main__':
    unittest.main()
