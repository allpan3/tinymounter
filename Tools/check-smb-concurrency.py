#!/usr/bin/env python3
"""Read-only VM check: independent connections, failure cleanup and a refused password.

Usage: check-smb-concurrency.py LIBRARY SERVER PASSWORD_FILE OUTPUT.json
The file holds the fixture account's password, outside the repository.
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


class Login(C.Structure):
    _fields_ = [('server', C.c_char_p), ('account', C.c_char_p), ('password', C.POINTER(C.c_ubyte)),
                ('password_length', C.c_size_t)]


def main():
    library, server, secret, output = sys.argv[1:]
    password = Path(secret).read_bytes()
    mount = Path('/Volumes/tinymounter-single')
    if Path.home() != Path('/Users/user') or not mount.is_mount() or Path(output).exists():
        raise RuntimeError('a fresh output in the mounted macOS VM fixture is required')
    lib = C.CDLL(library)
    pointer, data = C.c_void_p, C.POINTER(C.c_ubyte)
    for name, arguments, result in [
        ('connect_password', [C.POINTER(Login), C.c_char_p, C.POINTER(C.c_int), C.POINTER(C.c_uint32)], pointer),
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

    def connect(account, secret):
        error, status = C.c_int(), C.c_uint32()
        buffer = (C.c_ubyte * len(secret)).from_buffer_copy(secret)
        login = Login(server.encode(), account, buffer, len(secret))
        context = lib.tm_edit_connect_password(C.byref(login), b'tinymounter-single', C.byref(error),
                                               C.byref(status))
        return context, error.value

    def read(index, barrier):
        context, error = connect(b'tmtest', password)
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
        wrong, error = connect(b'tmtest', password + b'x')
        if wrong:
            lib.tm_edit_disconnect(wrong)
            raise RuntimeError('a wrong password signed in')
        if not error:
            raise RuntimeError('missing refused-password failure')
    result = dict(concurrentReads=40, refusedPasswords=10, passed=True)
    Path(output).write_text(json.dumps(result, indent=2))
    print(json.dumps(result))


if __name__ == '__main__':
    main()
