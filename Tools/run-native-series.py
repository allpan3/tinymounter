#!/usr/bin/env python3
"""Interleave native reads and local staging; never write the mounted source.

Build transfer-bench in Release first. Results include local paths/server details.
SMB counters cover the entire session and may include unrelated traffic.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time


def positive(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def capture(command, timeout=20):
    result = subprocess.run(command, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"{command[0]} failed: {result.stderr}")
    return result.stdout


def counters(text):
    sections = re.split(r"(?m)^Session: ", text)[1:]
    result = {}
    for section in sections:
        name = section.splitlines()[0]
        rx = re.search(r"Total RX Bytes: (\d+)", section)
        tx = re.search(r"Total TX Bytes: (\d+)", section)
        if rx and tx:
            result[name] = {"rx": int(rx[1]), "tx": int(tx[1])}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--results-dir", type=Path, required=True, help="new local directory")
    parser.add_argument("--bytes", type=positive, default=2 * 1024**3)
    parser.add_argument("--rounds", type=positive, default=5)
    parser.add_argument("--timeout", type=positive, default=180)
    args = parser.parse_args()
    if args.rounds > 20:
        parser.error("at most 20 rounds per series")
    root = Path(__file__).resolve().parents[1]
    binary = root / ".build/release/transfer-bench"
    if not binary.is_file():
        parser.error("build the benchmark using swift build -c release")
    folder = args.results_dir.absolute()
    # Refuse to create result files on SMB/NFS volumes.
    folder.parent.mkdir(parents=True, exist_ok=True)
    # Use the core's fstatfs/MNT_LOCAL check; statvfs flags differ from mount flags.
    # A zero-byte local fixture probe creates and cleans up one exclusive local stage.
    capture([str(binary), str(binary), "--length", "0", "--stage-dir", str(folder.parent)])
    folder.mkdir(exist_ok=False)
    stage = folder / "staging"
    stage.mkdir()
    manifest = {
        "source": str(args.source.absolute()), "length": args.bytes, "rounds": args.rounds,
        "started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "cache_state": "unknown; repeated same range with F_NOCACHE requested; no cache flush",
        "counter_scope": "per SMB session, includes any unrelated traffic",
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "block_size": 1024**2, "sync_staging": False,
    }
    (folder / "manifest.json").write_text(json.dumps(manifest, indent=2))
    for name, command in [
        ("smb-settings", ["smbutil", "statshares", "-a"]),
        ("hardware", ["sysctl", "hw.model", "hw.memsize", "hw.ncpu"]),
        ("os", ["sw_vers"]),
    ]:
        (folder / (name + ".txt")).write_text(capture(command))
    expected_snapshot = None
    with (folder / "samples.jsonl").open("x") as samples:
        for round_number in range(1, args.rounds + 1):
            modes = ["sink", "stage"] if round_number % 2 else ["stage", "sink"]
            for mode in modes:
                name = f"{round_number:02d}-{mode}"
                before = capture(["smbutil", "multichannel", "-a"])
                (folder / (name + "-before.txt")).write_text(before)
                command = [str(binary), str(args.source.absolute()), "--length", str(args.bytes),
                           "--no-cache", "--cache-label", "repeated-range-NAS-cache-unknown"]
                if mode == "stage":
                    command += ["--stage-dir", str(stage)]
                print(f"Starting {name}", flush=True)
                start = time.monotonic()
                process = subprocess.run(command, text=True, capture_output=True, timeout=args.timeout)
                wall_seconds = time.monotonic() - start
                (folder / (name + ".jsonl")).write_text(process.stdout)
                (folder / (name + ".stderr")).write_text(process.stderr)
                after = capture(["smbutil", "multichannel", "-a"])
                (folder / (name + "-after.txt")).write_text(after)
                if process.returncode:
                    raise RuntimeError(f"{name} failed: {process.stderr}")
                record = json.loads(process.stdout)
                if record["sourceFilesystem"]["type"] != "smbfs":
                    raise RuntimeError("Selected source is not on an SMB filesystem")
                snapshot = record["sourceSnapshot"]
                if expected_snapshot is not None and snapshot != expected_snapshot:
                    raise RuntimeError("Source metadata changed between runs")
                expected_snapshot = snapshot
                previous, current = counters(before), counters(after)
                delta = {key: {field: current[key][field] - previous[key][field] for field in ["rx", "tx"]}
                         for key in current.keys() & previous.keys()}
                record.update(seriesRound=round_number, seriesMode=mode,
                              smbSessionCounterDeltas=delta, processWallSeconds=wall_seconds)
                samples.write(json.dumps(record) + "\n")
                samples.flush()
                if list(stage.iterdir()):
                    raise RuntimeError("Unexpected staging leftovers")
                print(f"Finished {name}: {record['megabytesPerSecond']:.1f} MB/s; "
                      f"first read {record['metrics'].get('firstReadSeconds', 0):.3f} s; "
                      f"SMB counters {delta}", flush=True)
    print(f"Series complete: {folder}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Benchmark stopped: {error}. Inspect the dedicated staging folder after interruption.", file=sys.stderr)
        sys.exit(1)
