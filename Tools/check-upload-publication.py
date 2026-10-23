#!/usr/bin/env python3
"""Probe publication safety inside an approved disposable writable fixture on macOS."""
import argparse
import ctypes
import errno
import json
import os
from pathlib import Path
import platform
import tempfile


def call(operation, *args):
    ctypes.set_errno(0)
    result = operation(*args)
    return {"succeeded": result == 0, "errno": ctypes.get_errno() if result else 0}


def probe(root):
    libc = ctypes.CDLL(None, use_errno=True)
    libc.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    libc.renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int,
                                 ctypes.c_char_p, ctypes.c_uint]
    libc.linkat.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p,
                           ctypes.c_int]
    for operation in (libc.renamex_np, libc.renameatx_np, libc.linkat):
        operation.restype = ctypes.c_int
    report = {"macos": platform.mac_ver()[0]}
    exclusive = 0x00000004
    payload = bytes(range(256)) * 4096
    with tempfile.TemporaryDirectory(prefix="tinymounter-publication-", dir=root) as temporary:
        directory = Path(temporary)
        fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            for api in ("renamex_np", "renameatx_np", "linkat"):
                for collision in (False, True):
                    key = api + ("_collision" if collision else "_new")
                    source = directory / (key + "-stage")
                    destination = directory / (key + "-final")
                    with source.open("xb") as stream:
                        stream.write(payload)
                        stream.flush()
                        os.fsync(stream.fileno())
                    identity = source.stat().st_ino
                    if collision:
                        destination.write_bytes(b"existing content")
                    if api == "renamex_np":
                        result = call(libc.renamex_np, os.fsencode(source),
                                      os.fsencode(destination), exclusive)
                    elif api == "renameatx_np":
                        result = call(libc.renameatx_np, fd, os.fsencode(source.name),
                                      fd, os.fsencode(destination.name), exclusive)
                    else:
                        result = call(libc.linkat, fd, os.fsencode(source.name),
                                      fd, os.fsencode(destination.name), 0)
                    if collision:
                        result["existing_unchanged"] = destination.read_bytes() == b"existing content"
                        result["pending_unchanged"] = source.exists() and source.read_bytes() == payload
                    elif result["succeeded"]:
                        result["complete_content"] = destination.read_bytes() == payload
                        result["identity_preserved"] = destination.stat().st_ino == identity
                    else:
                        result["final_absent"] = not destination.exists()
                        result["pending_unchanged"] = source.read_bytes() == payload
                    report[key] = result
            target = directory / "exclusive-folder"
            target.mkdir()
            try:
                target.mkdir()
                report["exclusive_mkdir_collision_refused"] = False
            except FileExistsError as error:
                report["exclusive_mkdir_collision_refused"] = error.errno == errno.EEXIST
            source = directory / "ordinary-stage"
            destination = directory / "ordinary-final"
            source.write_bytes(payload)
            destination.write_bytes(b"existing content")
            os.rename(source, destination)
            report["ordinary_rename_replaced_existing"] = destination.read_bytes() == payload
        finally:
            os.close(fd)
    report["probe_directory_removed"] = not directory.exists()
    report["safe_file_publication_available"] = any(
        report[api + "_new"]["succeeded"]
        and report[api + "_new"]["complete_content"]
        and report[api + "_collision"]["errno"] == errno.EEXIST
        and report[api + "_collision"]["existing_unchanged"]
        and report[api + "_collision"]["pending_unchanged"]
        for api in ("renamex_np", "renameatx_np", "linkat")
    )
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture-root", required=True, type=Path,
                        help="Approved writable fixture directory; never a production share")
    args = parser.parse_args()
    try:
        report = probe(args.fixture_root)
    except Exception as error:
        print(json.dumps({"probe_failed": type(error).__name__,
                          "errno": getattr(error, "errno", None)}))
        return 1
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
