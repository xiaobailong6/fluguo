import os
from dataclasses import dataclass


@dataclass(frozen=True)
class BuildVariant:
    all_sources: bool = False

    @property
    def slug(self):
        return 'FlGuo-all-sources' if self.all_sources else 'FlGuo'

    @property
    def legacy_slug(self):
        # Bundle identifiers are persistent storage identities, not release branding.
        return 'zhenguojian' if self.all_sources else 'hongguojian'

    @property
    def arguments(self):
        return ['--all-sources'] if self.all_sources else []

    @property
    def flutter_arguments(self):
        return ['--dart-define=ALL_SOURCES=' + str(self.all_sources).lower()]

    @property
    def linker_flags(self):
        flags = '-s -w -X duanjuapp/native/core.buildAllSources=' + str(self.all_sources).lower()
        update_server = os.environ.get('UPDATE_SERVER_URL', '').strip()
        if update_server:
            flags += ' -X duanjuapp/native/core.nativeUpdateServer=' + update_server
        return flags


def add_variant_argument(parser):
    parser.add_argument('--all-sources', action='store_true',
                        help='构建 FlGuo 全站源版；默认构建红果、饭果、爽果标准版')
