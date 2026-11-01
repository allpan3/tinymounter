#!/usr/bin/env python3
r"""Parent-operated reproduction of New Folder creation on the disposable Samba fixture.

It compares the production SMB folder-create adapter with a native mkdir on the same
mount and parent, and records the adapter's stage trace and the backing metadata before
and after. It never builds, signs, installs, launches, mounts, deletes, changes modes or
ownership, or changes server configuration. Every created folder and uncertain result
stays in place. Use only macOS VM 1 with the approved loopback fixture mounted at
/Volumes/tinymounter-m19-edit-test, the normal app closed, and one process at a time.

RUN is 16 new lowercase hex digits. EVIDENCE is an existing private session folder
that the fixture user can write; each step adds RUN-STEP.json and refuses to overwrite.
  1. As root:         python3 -I Tools/check-folder-creation-runtime.py observe \
                        --run RUN --evidence EVIDENCE --label before
  2. As fixture user: python3 -I Tools/check-folder-creation-runtime.py create \
                        --run RUN --evidence EVIDENCE --smb-library LIBRARY
  3. As root:         the step 1 command with --label after
LIBRARY is the integration build's libTinyMounterSMB.dylib. --parent REL places the
folders below an existing share folder; the default is the share root, where the
recorded Finder failure happened. The reports hold fixture-relative names, so they stay
in the VM's private evidence.

create runs three adapter calls, then the native control:
  adapter       exclusive create of a new name; the receipt opens it through the mount
                like the app's receipt
  collision     the same exclusive create again; it must not replace the folder
  replay        an expected-identity open, only if the first call returned an identity
  native        os.mkdir of another new name through the mount
Observations are recorded without a verdict. A folder is uncertain whenever the
adapter reports sent=1 without a receipt.
"""
import argparse
import ctypes as C
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import stat
import subprocess
import time

SERVER, SHARE, ACCOUNT = b"127.0.0.1", b"tinymounter-m19-edit-test", b"_tinymounter_m19"
MOUNT = Path("/Volumes/tinymounter-m19-edit-test")
BACKING = Path("/Users/Shared/tinymounter-m19-edit-fixture")
RUN = re.compile(r"[0-9a-f]{16}")
XATTR_NOFOLLOW = 0x0001
LIBC = C.CDLL(None, use_errno=True)
LIBC.listxattr.argtypes = [C.c_char_p, C.c_char_p, C.c_size_t, C.c_int]
LIBC.listxattr.restype = C.c_ssize_t
LIBC.getxattr.argtypes = [C.c_char_p, C.c_char_p, C.c_void_p, C.c_size_t, C.c_uint32, C.c_int]
LIBC.getxattr.restype = C.c_ssize_t


class Timespec(C.Structure):
    _fields_ = [("sec", C.c_long), ("nsec", C.c_long)]


class Stat(C.Structure):
    """arm64 Darwin's struct stat, read through libc for exact birth nanoseconds."""
    _fields_ = [("dev", C.c_int32), ("mode", C.c_uint16), ("nlink", C.c_uint16), ("ino", C.c_uint64),
                ("uid", C.c_uint32), ("gid", C.c_uint32), ("rdev", C.c_int32), ("atime", Timespec),
                ("mtime", Timespec), ("ctime", Timespec), ("birthtime", Timespec), ("size", C.c_int64),
                ("blocks", C.c_int64), ("blksize", C.c_int32), ("flags", C.c_uint32), ("gen", C.c_uint32),
                ("lspare", C.c_int32), ("qspare", C.c_int64 * 2)]


LIBC.lstat.argtypes = [C.c_char_p, C.POINTER(Stat)]
LIBC.fstat.argtypes = [C.c_int, C.POINTER(Stat)]


def birth_us(info):
    """Microseconds as the app's receipt computes them, or 0 without a birth time."""
    birth = info.birthtime
    return birth.sec * 1_000_000 + birth.nsec // 1000 if birth.sec > 0 else 0


class Trace(C.Structure):
    _fields_ = [("stage", C.c_int), ("parents", C.c_int), ("status", C.c_uint32), ("error", C.c_int),
                ("sent_queued", C.c_int), ("sent", C.c_int)]


RECEIPT = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_uint64, C.c_uint64)


def validate_mount():
    if not os.path.ismount(MOUNT):
        raise SystemExit("requires the approved mounted fixture")
    mount = subprocess.run(["/sbin/mount", "-t", "smbfs"], capture_output=True, text=True, check=True)
    prefix = "//_tinymounter_m19@127.0.0.1/tinymounter-m19-edit-test on " + str(MOUNT) + " ("
    if not any(line.startswith(prefix) for line in mount.stdout.splitlines()):
        raise SystemExit("requires the authenticated native loopback fixture")


def names(run):
    return {"adapter": f"probe-newfolder-{run}-adapter", "native": f"probe-newfolder-{run}-native"}


def relative(parent, name):
    return f"{parent}/{name}" if parent else name


def xattrs(path):
    encoded = os.fsencode(path)
    size = LIBC.listxattr(encoded, None, 0, XATTR_NOFOLLOW)
    if size < 0:
        return {"errno": C.get_errno()}
    buffer = C.create_string_buffer(size)
    size = LIBC.listxattr(encoded, buffer, size, XATTR_NOFOLLOW)
    if size < 0:
        return {"errno": C.get_errno()}
    result = {}
    for name in filter(None, buffer.raw[:size].split(b"\0")):
        length = LIBC.getxattr(encoded, name, None, 0, 0, XATTR_NOFOLLOW)
        value = C.create_string_buffer(max(length, 1))
        length = LIBC.getxattr(encoded, name, value, length, 0, XATTR_NOFOLLOW) if length >= 0 else length
        key = name.decode(errors="replace")
        if length < 0:
            result[key] = {"errno": C.get_errno()}
        else:
            result[key] = {"bytes": length, "sha256": hashlib.sha256(value.raw[:length]).hexdigest()}
    return result


def metadata(path):
    try:
        info = os.lstat(path)
    except OSError as error:
        return {"exists": False, "errno": error.errno}
    exact = Stat()
    if LIBC.lstat(os.fsencode(path), C.byref(exact)) != 0:
        return {"exists": True, "lstat_errno": C.get_errno()}
    listing = subprocess.run(["/bin/ls", "-lden", str(path)], capture_output=True, text=True)
    return {"exists": True, "type": "directory" if stat.S_ISDIR(info.st_mode) else "other",
            "mode": oct(stat.S_IMODE(info.st_mode)), "uid": info.st_uid, "gid": info.st_gid,
            "device": info.st_dev, "inode": info.st_ino, "birth_us": birth_us(exact),
            "xattrs": xattrs(path), "ls": listing.stdout.strip() if listing.returncode == 0 else None}


def observe(args):
    if os.geteuid() != 0:
        raise SystemExit("observe runs as root to read mode-000 metadata")
    parent = BACKING / args.parent if args.parent else BACKING
    report = {"label": args.label, "time": time.time(), "parent": metadata(parent),
              "items": {key: metadata(parent / name) for key, name in names(args.run).items()}}
    return f"observe-{args.label}", report


def load(path):
    library = C.CDLL(str(path))
    library.tm_smb_create_folder.argtypes = [C.c_char_p, C.c_char_p, C.c_char_p, C.c_char_p, C.c_uint64,
                                             C.c_uint64, RECEIPT, C.c_void_p, C.POINTER(C.c_int),
                                             C.POINTER(Trace)]
    library.tm_smb_create_folder.restype = C.c_int
    library.tm_smb_folder_stage_name.argtypes = [C.c_int]
    library.tm_smb_folder_stage_name.restype = C.c_char_p
    return library


def adapter_call(library, path, expected_id=0, expected_birth=0):
    """One production adapter call with a receipt that checks the mount like the app's receipt."""
    receipt = {"called": False}

    def receive(context, file_id, birth):
        # ctypes turns an exception in a callback into a 0 return, which would read as success.
        try:
            receipt.update(called=True, file_id=file_id, birth_us=birth, step="open")
            try:
                fd = os.open(MOUNT / path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            except OSError as error:
                receipt["open_errno"] = error.errno
                return errno.EIO
            info = Stat()
            try:
                if LIBC.fstat(fd, C.byref(info)) != 0:
                    receipt["fstat_errno"] = C.get_errno()
                    return errno.EIO
            finally:
                os.close(fd)
            receipt.update(step="identity", native_inode=info.ino, native_birth_us=birth_us(info),
                           native_mode=oct(stat.S_IMODE(info.mode)))
            if not info.ino or birth_us(info) != birth:
                return errno.EIO
            receipt["step"] = "done"
            return 0
        except Exception as error:
            receipt["exception"] = type(error).__name__
            return errno.EIO

    callback = RECEIPT(receive)
    sent, trace = C.c_int(-1), Trace()
    started = time.monotonic()
    code = library.tm_smb_create_folder(SERVER, SHARE, ACCOUNT, os.fsencode(path), expected_id, expected_birth,
                                        callback, None, C.byref(sent), C.byref(trace))
    return {"code": code, "errno_name": errno.errorcode.get(code, str(code)),
            "seconds": round(time.monotonic() - started, 3),
            "stage": library.tm_smb_folder_stage_name(trace.stage).decode(), "parents": trace.parents,
            "status": f"0x{trace.status:08x}", "trace_errno": trace.error, "sent_queued": trace.sent_queued,
            "sent": trace.sent, "create_sent": sent.value,
            "uncertain": sent.value == 1 and receipt.get("step") != "done", "receipt": receipt}


def create(args):
    if os.geteuid() == 0:
        raise SystemExit("create runs as the fixture user, whose native mount holds the credential")
    validate_mount()
    if args.parent and not (MOUNT / args.parent).is_dir():
        raise SystemExit("--parent must be an existing fixture folder")
    library = load(args.smb_library)
    targets = {key: relative(args.parent, name) for key, name in names(args.run).items()}
    if any(os.path.lexists(MOUNT / path) for path in targets.values()):
        raise SystemExit("a probe name already exists; use a new RUN")
    report = {"macos": platform.mac_ver()[0], "cache_state": "uncontrolled", "parent": args.parent, "cases": {}}
    report["cases"]["adapter"] = first = adapter_call(library, targets["adapter"])
    report["cases"]["collision"] = adapter_call(library, targets["adapter"])
    identity = first["receipt"].get("file_id", 0), first["receipt"].get("birth_us", 0)
    if all(identity):
        report["cases"]["replay"] = adapter_call(library, targets["adapter"], *identity)
    try:
        os.mkdir(MOUNT / targets["native"])
        native = {"errno": 0}
    except OSError as error:
        native = {"errno": error.errno}
    try:
        info = os.stat(MOUNT / targets["native"])
        native.update(mount_mode=oct(stat.S_IMODE(info.st_mode)), mount_inode=info.st_ino)
    except OSError as error:
        native["stat_errno"] = error.errno
    report["cases"]["native"] = native
    try:
        info = os.stat(MOUNT / targets["adapter"])
        report["adapter_mount_view"] = {"mode": oct(stat.S_IMODE(info.st_mode)), "inode": info.st_ino}
    except OSError as error:
        report["adapter_mount_view"] = {"errno": error.errno}
    return "create", report


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=("observe", "create"))
    parser.add_argument("--run", required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--parent", default="", help="an existing folder relative to the share root")
    parser.add_argument("--label", choices=("before", "after"))
    parser.add_argument("--smb-library", type=Path)
    args = parser.parse_args()
    if not RUN.fullmatch(args.run):
        parser.error("--run must be 16 lowercase hex digits")
    if args.parent and (args.parent.startswith("/") or ".." in args.parent.split("/") or "\\" in args.parent):
        parser.error("--parent must be a plain relative path")
    if args.action == "observe" and not args.label:
        parser.error("observe needs --label")
    if args.action == "create" and not args.smb_library:
        parser.error("create needs --smb-library")
    if not BACKING.is_dir() or BACKING.is_symlink():
        raise SystemExit("requires the disposable fixture's backing folder")
    if not args.evidence.is_dir():
        parser.error("--evidence must be an existing folder")
    name, report = observe(args) if args.action == "observe" else create(args)
    with open(args.evidence / f"{args.run}-{name}.json", "x") as output:
        json.dump(report, output, indent=2, sort_keys=True)
    print(name)


if __name__ == "__main__":
    main()
