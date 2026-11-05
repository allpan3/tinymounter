#!/usr/bin/env python3
"""Read-only VM check: independent connections, failure cleanup and account separation.

Usage: check-smb-concurrency.py LIBRARY SERVER OUTPUT.json
Uses only the disposable simplify-20261105/saves-1m/direct-64-1.bin fixture. Four connections must all
open before any can read/close, which detects a lock held for a whole connection lifetime.
Run with an external timeout so a regressed connection lock cannot hang the test runner.
"""
from concurrent.futures import ThreadPoolExecutor
import ctypes as C
import hashlib
import json
from pathlib import Path
import sys
import threading


def main():
    library, server, output = sys.argv[1:]
    mount = Path('/Volumes/tinymounter-single')
    if Path.home() != Path('/Users/user') or not mount.is_mount() or Path(output).exists():
        raise RuntimeError('a fresh output in the mounted macOS VM fixture is required')
    lib = C.CDLL(library)
    pointer, data = C.c_void_p, C.POINTER(C.c_ubyte)
    for name, arguments, result in [
        ('connect', [C.c_char_p, C.c_char_p, C.c_char_p, C.POINTER(C.c_int)], pointer),
        ('disconnect', [pointer], None),
        ('open', [pointer, C.c_char_p, C.c_uint32, C.c_uint32, data], C.c_int),
        ('read', [pointer, data, C.c_uint64, data, C.c_uint32, C.POINTER(C.c_uint32)], C.c_int),
        ('close', [pointer, data], C.c_int),
    ]:
        function = getattr(lib, 'tm_edit_' + name)
        function.argtypes, function.restype = arguments, result
    path = 'simplify-20261105/saves-1m/direct-64-1.bin'
    with (mount / path).open('rb') as file:
        expected = [hashlib.sha256(file.read(1 << 20)).hexdigest() for _ in range(4)]

    def check(code):
        if code:
            raise OSError(code, 'SMB concurrency check')

    def connect(account):
        error = C.c_int()
        context = lib.tm_edit_connect(server.encode(), b'tinymounter-single', account, C.byref(error))
        return context, error.value

    def read(index, barrier):
        context, error = connect(b'tmtest')
        check(error)
        if not context:
            raise RuntimeError('no context')
        try:
            handle = (C.c_ubyte * 16)()
            check(lib.tm_edit_open(context, path.encode(), 0x81, 7, handle))
            barrier.wait(timeout=10)
            block = (C.c_ubyte * (1 << 20))()
            offset = 0
            digest = hashlib.sha256()
            while offset < len(block):
                count = C.c_uint32()
                check(lib.tm_edit_read(context, handle, (index << 20) + offset, block,
                                       len(block) - offset, C.byref(count)))
                if not 0 < count.value <= len(block) - offset:
                    raise RuntimeError('invalid read count')
                digest.update(bytes(block[:count.value]))
                offset += count.value
            check(lib.tm_edit_close(context, handle))
            if digest.hexdigest() != expected[index]:
                raise RuntimeError('concurrent bytes differ')
        finally:
            lib.tm_edit_disconnect(context)

    for _ in range(10):
        barrier = threading.Barrier(4)
        with ThreadPoolExecutor(max_workers=4) as pool:
            futures = [pool.submit(read, index, barrier) for index in range(4)]
            for future in futures:
                future.result(timeout=30)
        wrong, error = connect(b'tm-simplify-no-credential')
        if wrong:
            lib.tm_edit_disconnect(wrong)
            raise RuntimeError('uncached account borrowed another account credential')
        if not error:
            raise RuntimeError('missing account failure')
    result = dict(concurrentReads=40, refusedAccounts=10, passed=True)
    Path(output).write_text(json.dumps(result, indent=2))
    print(json.dumps(result))


if __name__ == '__main__':
    main()
