#!/usr/bin/env python3
"""Read a fresh provider range in small steps; report no names or paths."""
import argparse
import ctypes
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import time


def read(path, offset, length, step, delay, timings, io="pread", short_every=0, short_step=1):
    digest = hashlib.sha256()
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
    done = 0
    started = time.monotonic()
    before = None
    try:
        before = os.fstat(fd)
        if not 0 <= offset < offset + length <= before.st_size:
            raise ValueError("range outside file")
        started = time.monotonic()
        if io == "read":
            os.lseek(fd, offset, os.SEEK_SET)
        while done < length:
            tick = time.monotonic()
            short = short_every > 0 and (len(timings) + 1) % short_every == 0
            size = min(short_step if short else step, length - done)
            data = os.read(fd, size) if io == "read" else os.pread(fd, size, offset + done)
            if not data:
                raise ValueError("unexpected EOF")
            timings.append([offset + done, len(data), time.monotonic() - tick])
            digest.update(data)
            done += len(data)
            if delay:
                time.sleep(delay)
        elapsed = time.monotonic() - started
        after = os.fstat(fd)
        if (before.st_ino, before.st_size, before.st_mtime_ns) != (
                after.st_ino, after.st_size, after.st_mtime_ns):
            raise ValueError("source changed")
        return {"bytes": done, "seconds": elapsed, "sha256": digest.hexdigest(),
                "allocated_before": before.st_blocks * 512,
                "allocated_after": after.st_blocks * 512}
    except OSError as error:
        if before is not None:
            error.partial_read = {"bytes": done, "seconds": time.monotonic() - started,
                                  "sha256": digest.hexdigest(), "allocated_before": before.st_blocks * 512}
        raise
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider-root", type=Path, required=True)
    parser.add_argument("--native-root", type=Path, required=True)
    parser.add_argument("--relative-path-file", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--run", type=int, required=True)
    parser.add_argument("--offset", type=int, default=24048)
    parser.add_argument("--length", type=int, default=512 << 20)
    parser.add_argument("--step", type=int, default=64 << 10)
    parser.add_argument("--delay-ms", type=float, default=0)
    parser.add_argument("--io", choices=["pread", "read"], default="pread")
    parser.add_argument("--short-every", type=int, default=0)
    parser.add_argument("--short-step", type=int, default=40000)
    parser.add_argument("--log", type=Path)
    parser.add_argument("--settle-seconds", type=float, default=20)
    args = parser.parse_args()
    if (args.offset < 0 or args.step <= 0 or args.length <= 0 or args.short_every < 0
            or args.short_step <= 0 or not math.isfinite(args.delay_ms) or args.delay_ms < 0
            or not math.isfinite(args.settle_seconds) or not 0 <= args.settle_seconds <= 60):
        parser.error("invalid range, step, delay or settling interval (0–60 seconds)")
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.setiopolicy_np(3, 0, 2) != 0:
        raise OSError(ctypes.get_errno(), "materialization policy failed")
    relative = Path(args.relative_path_file.read_text().strip())
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError("expected a relative path beneath both roots")
    result = {"run": args.run, "started": datetime.datetime.now().astimezone().isoformat(),
              "offset": args.offset, "length": args.length, "step": args.step,
              "delay_ms": args.delay_ms, "io": args.io, "short_every": args.short_every,
              "short_step": args.short_step, "nas_cache": "unknown"}
    timings = []
    try:
        result["provider"] = read(args.provider_root / relative, args.offset, args.length,
                                  args.step, args.delay_ms / 1000, timings, args.io,
                                  args.short_every, args.short_step)
        result["read_finished"] = datetime.datetime.now().astimezone().isoformat()
    except OSError as error:
        result["errno"] = error.errno
        partial = getattr(error, "partial_read", None)
        if partial:
            result["provider_partial"] = partial
    except ValueError as error:
        result["error"] = str(error)
    provider = result.get("provider", result.get("provider_partial"))
    if provider and provider["bytes"]:
        try:
            native = read(args.native_root / relative, args.offset, provider["bytes"], 1 << 20, 0, [])
            result["native"] = native
            key = "sha_equal" if "provider" in result else "partial_sha_equal"
            result[key] = native["sha256"] == provider["sha256"]
        except OSError as error:
            result["native_errno"] = error.errno
        except ValueError as error:
            result["native_error"] = str(error)
    time.sleep(args.settle_seconds)
    result["finished"] = datetime.datetime.now().astimezone().isoformat()
    if args.log:
        start = result["started"][:23].replace("T", " ")
        stop = result["finished"][:23].replace("T", " ")
        with args.log.open() as log:
            lines = [line for line in log if start <= line[:23] <= stop]
        result["materialization_failed_lines"] = sum("materializationFailed" in line for line in lines)
        result["materialization_failed_events"] = sum(
            "materializationFailed" in line and " E " in line[:30] for line in lines)
        result["full_fetches"] = sum("mode=full" in line for line in lines)
        result["partial_fetches"] = sum("mode=partial" in line for line in lines)
    result["read_calls"] = len(timings)
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as output:
        json.dump(dict(result, reads=timings), output)
        output.write("\n")
    print(json.dumps(result), flush=True)
    return 0 if result.get("sha_equal") else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except OSError as error:
        print(json.dumps({"errno": error.errno}), flush=True)
        raise SystemExit(1)
