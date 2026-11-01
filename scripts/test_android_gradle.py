import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest import mock

from android_gradle import plugin_repositories


ROOT = Path(__file__).resolve().parents[1]
INIT_SCRIPT = ROOT / 'android' / 'gradle' / 'plugin-repositories.init.gradle'


class AndroidGradleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='fluguo-gradle-')
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / 'gradle home'
        self.environment = {'GRADLE_USER_HOME': str(self.home)}

    def scripts(self):
        return list((self.home / 'init.d').glob('fluguo-repositories-*.gradle'))

    def test_install_and_cleanup_preserve_user_configuration(self):
        directory = self.home / 'init.d'
        directory.mkdir(parents=True)
        user = directory / 'user.gradle'
        user.write_text('// user configuration', encoding='utf-8')
        original = self.environment.copy()
        with plugin_repositories(ROOT, self.environment):
            installed, = self.scripts()
            self.assertEqual(installed.read_bytes(), INIT_SCRIPT.read_bytes())
            self.assertTrue(Path(self.environment['GRADLE_USER_HOME']).is_absolute())
        self.assertFalse(installed.exists())
        self.assertEqual(user.read_text(encoding='utf-8'), '// user configuration')
        self.assertEqual(self.environment, original)

    def test_failure_and_nested_builds_cleanup_only_their_own_script(self):
        with self.assertRaisesRegex(RuntimeError, 'build failed'):
            with plugin_repositories(ROOT, self.environment):
                first, = self.scripts()
                with plugin_repositories(ROOT, self.environment):
                    self.assertEqual(len(self.scripts()), 2)
                self.assertEqual(self.scripts(), [first])
                raise RuntimeError('build failed')
        self.assertEqual(self.scripts(), [])

    def test_relative_gradle_home_is_absolute_during_build_then_restored(self):
        root = Path(self.temp.name)
        source = root / 'android' / 'gradle'
        source.mkdir(parents=True)
        (source / INIT_SCRIPT.name).write_bytes(INIT_SCRIPT.read_bytes())
        environment = {'GRADLE_USER_HOME': 'relative home'}
        with plugin_repositories(root, environment):
            self.assertEqual(Path(environment['GRADLE_USER_HOME']), root / 'relative home')
            self.assertEqual(len(list((root / 'relative home' / 'init.d').glob('*.gradle'))), 1)
        self.assertEqual(environment, {'GRADLE_USER_HOME': 'relative home'})

    def test_default_home_does_not_leave_environment_override(self):
        environment = {}
        with mock.patch('android_gradle.Path.home', return_value=Path(self.temp.name)):
            with plugin_repositories(ROOT, environment):
                self.assertEqual(Path(environment['GRADLE_USER_HOME']), Path(self.temp.name) / '.gradle')
        self.assertEqual(environment, {})

    def test_missing_source_cleans_partial_file(self):
        with self.assertRaises(FileNotFoundError):
            with plugin_repositories(Path(self.temp.name), self.environment):
                self.fail('missing source must stop build')
        self.assertEqual(self.scripts(), [])
        self.assertEqual(self.environment['GRADLE_USER_HOME'], str(self.home))

    def test_build_entry_keeps_both_editions_and_cleans_up_on_failure(self):
        for all_sources in (False, True):
            for fail in (False, True):
                with self.subTest(all_sources=all_sources, fail=fail):
                    commands = []

                    def run(command, **kwargs):
                        commands.append(command)
                        if 'build' in command:
                            self.assertEqual(len(self.scripts()), 1)
                            self.assertIn('--release', command)
                            self.assertIn('--split-per-abi', command)
                            self.assertIn('android-arm64', command)
                            self.assertEqual('--dart-define=ALL_SOURCES=true' in command, all_sources)
                            if fail:
                                raise subprocess.CalledProcessError(1, command)
                        else:
                            self.assertEqual(self.scripts(), [])
                        return subprocess.CompletedProcess(command, 0)

                    arguments = ['build_android.py', '--abi', 'arm64-v8a']
                    if all_sources:
                        arguments.append('--all-sources')
                    with mock.patch.dict(os.environ, self.environment), \
                         mock.patch('sys.argv', arguments), \
                         mock.patch('shutil.which', return_value='flutter'), \
                         mock.patch('subprocess.run', side_effect=run):
                        if fail:
                            with self.assertRaises(subprocess.CalledProcessError):
                                runpy.run_path(str(ROOT / 'scripts' / 'build_android.py'), run_name='__main__')
                        else:
                            runpy.run_path(str(ROOT / 'scripts' / 'build_android.py'), run_name='__main__')
                    self.assertEqual(len(commands), 3 if fail else 4)
                    self.assertEqual(self.scripts(), [])

    @unittest.skipUnless(os.environ.get('FLUGUO_TEST_GRADLE'), 'set FLUGUO_TEST_GRADLE to Gradle executable')
    def test_real_flutter_style_included_build_resolves_kotlin_plugins(self):
        # 独立构建复现 Flutter SDK 的插件声明，不需要 Android SDK/NDK/签名。
        fixture = Path(self.temp.name) / 'fixture'
        included = fixture / 'flutter-gradle'
        included.mkdir(parents=True)
        (fixture / 'settings.gradle.kts').write_text(
            'pluginManagement { includeBuild("flutter-gradle") }\n', encoding='utf-8')
        (fixture / 'build.gradle.kts').write_text('', encoding='utf-8')
        (included / 'settings.gradle.kts').write_text('''
rootProject.name = "flutter-gradle"
dependencyResolutionManagement {
    repositories { google(); mavenCentral() }
}
check(pluginManagement.repositories.any {
    it is org.gradle.api.artifacts.repositories.MavenArtifactRepository &&
        it.url.toString().contains("repo.maven.apache.org")
}) { "included build has no Maven Central plugin repository" }
''', encoding='utf-8')
        (included / 'build.gradle.kts').write_text('''
plugins {
    `java-gradle-plugin`
    groovy
    `kotlin-dsl`
    kotlin("jvm") version "2.2.20"
}
tasks.register("verifyPluginResolution") {
    doLast {
        val files = project.buildscript.configurations.getByName("classpath").files
        check(files.any { it.name == "kotlin-stdlib-2.2.21.jar" })
        check(files.any { it.name == "kotlin-gradle-plugin-api-2.2.21.jar" })
        println("FLUTTER_INCLUDED_BUILD_KOTLIN_RESOLVED")
    }
}
''', encoding='utf-8')
        environment = os.environ.copy()
        # 实测可复用下载缓存，但 init 脚本仍由被测 context manager 安装并清理。
        environment['GRADLE_USER_HOME'] = os.environ.get('FLUGUO_TEST_GRADLE_HOME', str(self.home))
        with plugin_repositories(ROOT, environment):
            result = subprocess.run([
                os.environ['FLUGUO_TEST_GRADLE'], '--no-daemon', '--console=plain',
                '-p', str(fixture), ':flutter-gradle:verifyPluginResolution',
            ], env=environment, capture_output=True, text=True, timeout=210)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('FLUTTER_INCLUDED_BUILD_KOTLIN_RESOLVED', result.stdout)
        print(result.stdout)


if __name__ == '__main__':
    unittest.main()
