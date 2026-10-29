#!/usr/bin/env python3
"""Exercise production rename enumeration on the approved disposable loopback SMB fixture."""
import argparse
import ctypes as C
import importlib.util
import json
from pathlib import Path
import shutil
import struct
import uuid

spec = importlib.util.spec_from_file_location("in_place", Path(__file__).with_name("check-edit-in-place.py"))
in_place = importlib.util.module_from_spec(spec)
spec.loader.exec_module(in_place)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = in_place.validate_fixture()
    name = "probe-rename-list-" + uuid.uuid4().hex
    backing = Path("/Users/Shared/tinymounter-m19-edit-fixture") / name
    backing.mkdir(mode=0o777)
    backing.chmod(0o777)
    names = {"entry-%03d.txt" % index for index in range(100)}
    library = C.CDLL(str(args.library.resolve()))
    library.tm_edit_connect.argtypes = [C.c_char_p, C.c_char_p, C.c_char_p, C.POINTER(C.c_int)]
    library.tm_edit_connect.restype = C.c_void_p
    library.tm_edit_open_directory.argtypes = [C.c_void_p, C.c_char_p, C.c_uint32, C.c_uint32, C.c_void_p]
    library.tm_edit_list.argtypes = [C.c_void_p, C.c_void_p, C.c_int, C.c_void_p, C.c_uint32,
                                   C.POINTER(C.c_uint32), C.POINTER(C.c_int)]
    library.tm_edit_disconnect.argtypes = [C.c_void_p]
    client = None
    try:
        for leaf in names:
            (root / name / leaf).write_bytes(b"pagination fixture\n")
        error = C.c_int()
        client = library.tm_edit_connect(b"127.0.0.1", b"tinymounter-m19-edit-test", b"_tinymounter_m19", C.byref(error))
        assert client, "fixture connection errno=%d" % error.value
        handle = (C.c_ubyte * 16)()
        assert library.tm_edit_open_directory(client, name.encode(), 0x81, 3, handle) == 0
        pages = []
        identities = []
        for _ in range(2):
            seen = {}
            for page in range(200):
                buffer = (C.c_ubyte * 256)()
                count, finished = C.c_uint32(), C.c_int()
                error = library.tm_edit_list(client, handle, int(page == 0), buffer, len(buffer),
                                              C.byref(count), C.byref(finished))
                assert error == 0, "directory page errno=%d" % error
                if finished.value:
                    break
                data, offset = bytes(buffer[:count.value]), 0
                assert data
                while True:
                    next_offset, length = struct.unpack_from("<I", data, offset)[0], struct.unpack_from("<I", data, offset + 60)[0]
                    leaf = data[offset + 80:offset + 80 + length].decode("utf-16-le")
                    if leaf not in (".", ".."):
                        assert leaf not in seen
                        seen[leaf] = struct.unpack_from("<Q", data, offset + 72)[0]
                        assert seen[leaf] != 0
                    if not next_offset:
                        break
                    offset += next_offset
            else:
                raise AssertionError("directory did not finish")
            assert set(seen) == names and page > 1
            identities.append(seen)
            pages.append(page)
        assert identities[0] == identities[1]
        result = {"passed": True, "entries": len(names), "pages_per_scan": pages, "restarted_identity_matches": True}
        args.output.write_text(json.dumps(result, indent=2))
        print(json.dumps(result))
    finally:
        if client:
            library.tm_edit_disconnect(client)
        shutil.rmtree(backing)


if __name__ == "__main__":
    main()
