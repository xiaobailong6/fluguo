"""Exercise the compiled C ABI offline; requires an explicit freshly built library.

Run: python -B scripts/check_native_abi.py <library> [--all-sources]
The protocol query must work without initializing storage or contacting a source.
"""
import argparse
import ctypes
import json
from pathlib import Path


def check(library_path: Path, all_sources: bool) -> None:
    library = ctypes.CDLL(str(library_path.resolve(strict=True)))
    request = library.DuanjuRequest
    request.argtypes = [ctypes.c_char_p]
    request.restype = ctypes.c_void_p
    free = library.DuanjuFree
    free.argtypes = [ctypes.c_void_p]
    free.restype = None

    def call(body: bytes):
        pointer = request(body)
        if not pointer:
            raise AssertionError('DuanjuRequest returned NULL')
        try:
            return json.loads(ctypes.string_at(pointer).decode('utf-8'))
        finally:
            free(pointer)

    # Repeated allocation/free uses the exported pair, not Go-only dispatch tests.
    for _ in range(32):
        response = call(b'{"action":"protocol"}')
        assert response['ok'] is True, response
        build = response['data']
        assert build['allSources'] is all_sources, build
        assert build['protocolVersion'] >= 1, build
        assert build['minCompatibleVersion'] == 1, build
        assert {'structuredErrors', 'catalogWarningDetails'} <= set(build['capabilities'])
    malformed = call(b'{')
    assert malformed['ok'] is False, malformed
    assert malformed['code'] == 'invalid_request', malformed
    denied = call(b'{"action":"catalog","source":"unknown"}')
    assert denied['ok'] is False, denied
    assert denied['code'] == 'source_unavailable', denied
    print('Native C ABI protocol, structured errors and allocation/free verified')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('library', type=Path)
    parser.add_argument('--all-sources', action='store_true')
    args = parser.parse_args()
    check(args.library, args.all_sources)
