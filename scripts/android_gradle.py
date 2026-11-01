"""为 Flutter 的独立 Gradle 构建补齐插件依赖仓库，不改写共享 SDK。"""

from contextlib import contextmanager
from pathlib import Path
import tempfile


@contextmanager
def plugin_repositories(root: Path, environment: dict):
    # Flutter 的 flutter build 不透传 --init-script；Gradle user home 的 init.d
    # 同时作用于主构建与 included build，且保留调用者既有缓存和用户配置。
    home = Path(environment.get('GRADLE_USER_HOME') or Path.home() / '.gradle')
    if not home.is_absolute():
        home = root / home
    init_directory = home / 'init.d'
    init_directory.mkdir(parents=True, exist_ok=True)
    source = root / 'android' / 'gradle' / 'plugin-repositories.init.gradle'
    previous_home = environment.get('GRADLE_USER_HOME')
    installed = None
    try:
        # 随机文件名避免并发构建互相覆盖；不用固定名称覆盖用户自己的 init 脚本。
        with tempfile.NamedTemporaryFile(
            mode='wb', prefix='fluguo-repositories-', suffix='.gradle',
            dir=init_directory, delete=False,
        ) as script:
            installed = Path(script.name)
            script.write(source.read_bytes())
        environment['GRADLE_USER_HOME'] = str(home.resolve())
        yield
    finally:
        # 构建失败同样清理，防止本项目的仓库补充长期影响其他 Gradle 工程。
        if previous_home is None:
            environment.pop('GRADLE_USER_HOME', None)
        else:
            environment['GRADLE_USER_HOME'] = previous_home
        if installed is not None:
            installed.unlink(missing_ok=True)
