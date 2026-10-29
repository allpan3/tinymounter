#!/usr/bin/env python3
"""Check actual ENOSPC on a bounded disposable volume beneath the M19 fixture."""
import argparse
import errno
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import uuid


spec = importlib.util.spec_from_file_location("edit_probe", Path(__file__).with_name("check-edit-in-place.py"))
edit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(edit)


def probe(args):
    root = edit.validate_fixture()
    backing = Path("/Users/Shared/tinymounter-m19-edit-fixture/probe-space")
    if not os.path.ismount(backing) or shutil.disk_usage(backing).total > 128 * 1024 * 1024:
        raise ValueError("requires a separate disposable volume of at most 128 MiB")
    if backing.stat().st_dev == backing.parent.stat().st_dev:
        raise ValueError("refuse to fill the VM's ordinary storage")
    if args.evidence.stat().st_dev == backing.stat().st_dev:
        raise ValueError("pending data must stay outside the bounded volume")
    library = edit.publication.load(args.library, authenticated=True, keychain=args.fixture_keychain)
    prefix = "probe-space/probe-" + uuid.uuid4().hex + "-"
    names = {key: prefix + key for key in ("original", "stage", "backup", "work")}
    old, new = edit.contents(b"old", 4 * 1024 * 1024), edit.contents(b"edit", 8 * 1024 * 1024)
    pending = args.evidence / ("space-" + uuid.uuid4().hex + ".data")
    with pending.open("xb") as stream:
        stream.write(new)
        stream.flush()
        fcntl.fcntl(stream.fileno(), 51)
    pending.chmod(0o400)
    report = {"passed": False, "fixture_names": names, "filler_names": [],
              "volume_capacity": shutil.disk_usage(backing).total, "old_size": len(old), "new_size": len(new),
              "pending_leaf": pending.name, "old_sha256": hashlib.sha256(old).hexdigest(),
              "edit_sha256": hashlib.sha256(new).hexdigest()}
    output = pending.with_suffix(".json")

    def record(point):
        report["checkpoint"] = point
        with output.open("w") as stream:
            json.dump(report, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())

    record("prepared")
    a = None
    try:
        a = edit.Client(library)
        parent = a.directory("probe-space")
        report["parent_identity"] = a.info(parent)[:2]
        edit.publication.native_write(root / names["original"], old, True)
        stage = a.private(names["stage"], edit.private_security(), edit.READ | edit.DELETE | 0x40000, 3)
        security = edit.private_security(edit.sid(a.metadata(stage, True), 4))
        a.set_metadata(stage, security, True)
        edit.require(report, "stage_private", edit.dacl(a.metadata(stage, True)) == edit.dacl(security))
        edit.publication.native_write(root / names["stage"], new)
        a.open(names["stage"], edit.READ, 1 | 4)
        report["stage_identity"] = a.info(stage)[:2]
        edit.require(report, "stage_complete", a.read(stage) == new)
        original = a.open(names["original"], edit.READ | edit.WRITE | edit.DELETE, 0)
        report["original_identity"] = a.info(original)[:2]
        edit.require(report, "original_complete", a.read(original) == old)
        backup = a.private(names["backup"], security)
        report["backup_identity"] = a.info(backup)[:2]
        edit.require(report, "backup_private", edit.dacl(a.metadata(backup, True)) == edit.dacl(security))
        a.copy(original, backup, len(old))
        a.size(backup, len(old))
        a.flush(backup)
        edit.require(report, "backup_complete", a.read(backup) == old)
        record("backup")
        a.rename(original, names["work"])
        edit.require(report, "ordinary_name_absent", edit.publication.attempt(
            lambda: a.close(a.open(names["original"]))) == errno.ENOENT)
        full = False
        block = edit.contents(b"filler", 1024 * 1024)
        for index in range(8):
            name = prefix + "filler-" + str(index)
            report["filler_names"].append(name)
            fd = None
            errors = []
            try:
                fd = os.open(root / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                for _ in range(16):
                    offset = 0
                    while offset < len(block):
                        count = os.write(fd, block[offset:])
                        if count <= 0:
                            raise OSError(errno.EIO, "short filler write")
                        offset += count
                os.fsync(fd)
            except OSError as error:
                errors.append(error.errno)
            finally:
                if fd is not None:
                    try:
                        os.close(fd)
                    except OSError as error:
                        errors.append(error.errno)
            if errors:
                report["filler_errors"] = errors
                if errno.ENOSPC not in errors or any(code not in (errno.ENOSPC, errno.ENXIO) for code in errors):
                    raise OSError(errors[0], "unexpected filler failure")
                full = True
            if full:
                break
        edit.require(report, "actual_volume_full", full)
        report["free_bytes_at_failure"] = shutil.disk_usage(backing).free
        record("copy")
        denied = edit.publication.attempt(lambda: a.copy(stage, original, len(new)))
        report["copy_errno"] = denied
        edit.require(report, "copy_reports_enospc", denied == errno.ENOSPC)
        edit.require(report, "original_identity_retained", a.info(original)[:2] == report["original_identity"])
        contents = a.read(original)
        report["work_size"], report["work_sha256"] = len(contents), hashlib.sha256(contents).hexdigest()
        edit.require(report, "backup_survives_full_volume", a.read(backup) == old)
        edit.require(report, "stage_survives_full_volume", a.read(stage) == new)
        edit.require(report, "local_pending_survives", pending.read_bytes() == new)
        a.disconnect()
        a = edit.Client(library)
        for key, expected in (("stage", new), ("backup", old), ("work", contents)):
            h = a.open(names[key], edit.READ | edit.DELETE, 0)
            identity_key = "original_identity" if key == "work" else key + "_identity"
            edit.require(report, key + "_reconnected_identity", a.info(h)[:2] == report[identity_key])
            edit.require(report, key + "_reconnected_contents", a.read(h) == expected)
            a.close(h)
        report["action"] = "retain"
        report["passed"] = True
    except (OSError, ValueError) as error:
        report.update(error=type(error).__name__, errno=getattr(error, "errno", None),
                      last_ntstatus=hex(library.probe_status()))
    finally:
        if a:
            a.disconnect()
    record("finished")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--fixture-keychain", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    if not args.evidence.is_dir():
        parser.error("requires an existing evidence directory outside the full volume")
    result = probe(args)
    print(json.dumps(result, sort_keys=True), flush=True)
    raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
