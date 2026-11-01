#!/usr/bin/env python3
"""Measure File Provider reads against matched native SMB reads for one installed build.

Parent-operated, in macOS VM 1 only. The tool never builds, signs, installs, launches,
mounts, evicts, writes a share, changes settings or resets caches. It reads four
fixture paths and writes only inside a new local results folder. Run `run` once per
build and access mode, each with its own contemporaneous native controls, then
`compare` two run folders. There is no pass threshold and no combined score.

WORKLOADS, interleaved each round; order alternates between rounds:
  full     native SMB read of the whole FULL fixture (transfer-bench, 1 MiB preads,
           F_NOCACHE) and a coordinated full download of its evicted provider copy.
           Timed from the coordination request to accessor entry by the Swift helper.
           Completion means SF_DATALESS cleared and the full length allocated
           afterwards, not a download-request acknowledgment.
  cached   the just-downloaded provider copy and a local APFS clone of it, read with
           hydration disabled. Local storage/cache speed, not SMB.
  partial  one sequential range of PARTIAL (default 512 MiB) natively and through the
           provider (--allow-hydration): rate and first-read latency, the first 1 MiB
           pread. Each round uses an unused slot; the provider's allocation must grow
           by at least the range length during the sample, or the sample is invalid.
Provider copies and ranges are hashed with hydration disabled, outside timing, and
compared at the end with native hashes. Rates are decimal MB/s. Failed samples stay
in samples.jsonl and results.json; only valid samples enter medians. Remote samples
also require SMB receive counters to cover the requested bytes. Full downloads need
one matching full callback from the selected app's provider.

The fetch log (subsystem dev.tinymounter.prototype, category fetch) is streamed for
the run. Each provider sample records its callbacks: count, modes, bytes, and the
callback time beyond the app's transfer time. In a writable location an initial full
fetch uses protectedTransfer (FileProviderExtension.swift establishEditBase,
ShareAccess.swift transfer), which adds an SMB connection and whole-file version
proof, and later fetches of an e1 version take the same path. No log line names that
path or the version, so --access-mode is declared by the parent and the extra cost
appears only as callback time beyond transfer. Never compare the modes unlabeled.

HISTORY, context only and never a substitute for a baseline run: on this VM, full
downloads exceeded 90% of matched native (2026-10-11 full-download and cache-states
logs). Sequential partial reads have always missed 90% (45.2% for 512 MiB on
2026-10-15, read-ahead-window log). A partial ratio below 90% in both builds is that
old deficit; a regression is the current build below the baseline build under matched
setup and mode. 90% is the accepted target in benchmark-plan.md section 6.

BASELINE: c2f52a0 (M17, the last build before write support: no libsmb2, Settings v3,
catalog schema 2, the same 16 MiB read-ahead and fetch log line as now). Build it from
`git archive` exactly like the current candidate, in its own bundle identity and App
Group, so it never opens Settings or catalogs that a later build wrote. Never downgrade.

PRECONDITIONS, manual, for each run:
  1. Release transfer-bench and the helper from THIS checkout, used for every run:
       swift build -c release
       swiftc -O Tools/check-performance-regression.swift -o .build/check-performance-regression
  2. The measured build is installed and running, its location set up in its own state,
     on the same Finder-mounted share with the same SMB security settings. --access-mode
     states the location's mode: read-only, or writable (approved disposable fixture
     only; this tool still writes nothing there).
  3. The location holds two immutable fixtures, neither kept (Keep Downloaded off):
     FULL, e.g. the 2.55 GiB MKV used since 2026-10-11, with its provider copy evicted;
     PARTIAL, large enough for the slots (8.5 GiB by default; the 35.02 GiB control
     fits), never read in this state, so its provider allocation is 0. In writable mode
     record whether PARTIAL was ever fully downloaded there, which makes it e1. A 2 GiB
     PARTIAL fits five slots with --partial-length 268435456 --partial-gap 67108864
     --partial-start 67108864; use the same geometry for both builds.
  4. A private setup JSON in results/, with absolute paths:
       {"native_full": ..., "provider_full": ..., "native_partial": ..., "provider_partial": ...}
  5. No builds, tests, hashing or other heavy work in the VM during timing.

SEQUENCE, per build and mode; the results folder must be new and local:
  python3 -I Tools/check-performance-regression.py preflight --setup SETUP --app APP
  python3 -I Tools/check-performance-regression.py run --setup SETUP --app APP \
      --build-label baseline --build-commit c2f52a0 --access-mode read-only \
      --results-dir results/perf-20261031-baseline
Preflight opens every provider fixture without reading data. Accept any managed-file
privacy prompt there, then repeat preflight; a prompt must never fall inside timing.
Between rounds `run` waits up to --evict-timeout for the parent to evict only FULL's
provider copy (Finder Remove Download; retry after a few seconds on Resource busy). It
polls allocation and SF_DATALESS and never evicts. Afterwards:
  python3 -I Tools/check-performance-regression.py compare BASE_DIR CURRENT_DIR
For a mode pair at one build, pass the read-only run first.
compare lists every setup difference and says what the pair can attribute: a build
difference at matched mode, or a mode difference at matched build.

NOT COVERED: server cache state (unknown; no per-file eviction there), Finder or player
opens, first frame and seeks, listing contention during reads, several readers, the
physical Mac. The two builds cannot be interleaved, so drift between runs is limited
only by each run's own native controls. Slot gaps (default 1 GiB) must exceed the build's
read-ahead (16 MiB in both builds). Ordinary output never prints paths; the results
folder keeps them and is private.
"""
import argparse
import ctypes
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
BENCH = ROOT / ".build/release/transfer-bench"
HELPER = ROOT / ".build/check-performance-regression"
SETUP_KEYS = ("native_full", "provider_full", "native_partial", "provider_partial")
SF_DATALESS = 0x40000000
F_NOCACHE = 48
MIB, GIB = 1024**2, 1024**3
ACCEPTED_TARGET = 0.90  # benchmark-plan.md section 6; context, not a pass/fail verdict here
GROUPS = [  # (group, control workload, provider workload)
    ("full", "native-full", "provider-full"),
    ("cached", "local-clone", "provider-cached"),
    ("partial", "native-partial", "provider-partial"),
]
LABELS = {
    "native-full": "NAS cache unknown; F_NOCACHE requested",
    "provider-full": "NAS cache unknown; provider copy verified evicted before the sample",
    "provider-cached": "provider copy fully local; hydration disabled; local caches not flushed",
    "local-clone": "APFS clone of the provider copy; local caches not flushed",
    "native-partial": "NAS cache unknown; F_NOCACHE requested",
    "provider-partial": "NAS cache unknown; unused slot; allocation growth checked",
}
FETCH_LINE = re.compile(
    r"mode=(\w+) kind=(\S+) .*?bytes=(\d+) queue_seconds=(\S+) callback_seconds=(\S+) transfer_seconds=(\S+)")


class Stop(Exception):
    """A run-level failure; its message never contains a path."""


def label(error):
    if isinstance(error, OSError):
        return f"{type(error).__name__} errno {error.errno}"
    if isinstance(error, subprocess.TimeoutExpired):
        return "timeout"
    return str(error)


def now_utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def capture(command, timeout=60):
    result = subprocess.run(command, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise Stop(f"{Path(command[0]).name} exited {result.returncode}")
    return result.stdout


def disable_hydration():
    """Children inherit this; transfer-bench --allow-hydration and the helper turn it on."""
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.setiopolicy_np(3, 0, 1) != 0 or libc.getiopolicy_np(3, 0) != 1:
        raise Stop("cannot disable hydration for this process")


def state(path):
    value = os.lstat(path)
    return {"size": value.st_size, "allocated": value.st_blocks * 512,
            "dataless": bool(value.st_flags & SF_DATALESS), "mtimeNs": value.st_mtime_ns}


def smb_rx():
    try:
        text = capture(["smbutil", "multichannel", "-a"], timeout=20)
    except (Stop, OSError, subprocess.SubprocessError):
        return "", None
    totals = {}
    for section in re.split(r"(?m)^Session: ", text)[1:]:
        rx = re.search(r"Total RX Bytes: (\d+)", section)
        if rx:
            totals[section.splitlines()[0]] = int(rx[1])
    return text, totals


def sha256(path, offset, length, nocache):
    digest = hashlib.sha256()
    descriptor = os.open(path, os.O_RDONLY)
    try:
        if nocache:
            fcntl.fcntl(descriptor, F_NOCACHE, 1)
        position, end = offset, offset + length
        while position < end:
            chunk = os.pread(descriptor, min(8 * MIB, end - position), position)
            if not chunk:
                raise RuntimeError("short read while hashing")
            digest.update(chunk)
            position += len(chunk)
    finally:
        os.close(descriptor)
    return digest.hexdigest()


def load_setup(path):
    setup = json.loads(Path(path).read_text())
    missing = [key for key in SETUP_KEYS if not isinstance(setup.get(key), str) or not os.path.isabs(setup[key])]
    if missing:
        raise Stop("setup needs absolute paths for " + ", ".join(missing))
    if len({setup[key] for key in SETUP_KEYS}) != 4:
        raise Stop("setup paths must be four different files")
    return setup


def slot_offset(args, slot):
    return args.partial_start + slot * (args.partial_length + args.partial_gap)


def bench_record(path, *extra, timeout=60):
    result = subprocess.run([str(BENCH), path, *extra], text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"transfer-bench exited {result.returncode}")
    return json.loads(result.stdout.splitlines()[0])


def codesign_info(bundle):
    result = subprocess.run(["codesign", "-dvvv", str(bundle)], text=True, capture_output=True, timeout=30)
    fields = {}
    for line in result.stderr.splitlines():
        key, _, value = line.partition("=")
        if key in ("Identifier", "CDHash", "TeamIdentifier", "Timestamp", "Signed Time"):
            fields[key] = value
    try:
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        fields.update(shortVersion=info.get("CFBundleShortVersionString"), bundleVersion=info.get("CFBundleVersion"))
    except OSError as error:
        fields["infoPlist"] = label(error)
    fields["codesignExit"] = result.returncode
    return fields


def provider_bundle(app):
    found = sorted((app / "Contents/PlugIns").glob("*.appex"))
    return found[0] if len(found) == 1 else None


def app_running(app):
    """True if the app's own executable, not only its extension, runs from this bundle."""
    prefix = str(app.resolve() / "Contents/MacOS") + "/"
    commands = subprocess.run(["ps", "-axo", "comm="], text=True, capture_output=True).stdout.splitlines()
    return any(command.strip().startswith(prefix) for command in commands)


def preflight_checks(args, setup):
    """Returns (problems, facts). Opens provider fixtures without reading content."""
    problems, facts = [], {}
    for binary, hint in [(BENCH, "swift build -c release"), (HELPER, "compile the helper with swiftc -O")]:
        if not binary.is_file():
            problems.append(f"{binary.name} missing: {hint}")
    if provider_bundle(args.app) is None:
        problems.append("--app is not an app bundle with exactly one provider extension")
    elif not app_running(args.app):
        problems.append("the app is not running from --app")
    if problems:
        return problems, facts
    for key in SETUP_KEYS:
        try:
            facts[key] = state(setup[key])
            record = bench_record(setup[key], "--length", "0")
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
            problems.append(f"{key}: {label(error)}")
            continue
        system = record["sourceFilesystem"]
        facts[key]["filesystem"] = system["type"]
        if key.startswith("native") and system["type"] != "smbfs":
            problems.append(f"{key} is not on smbfs")
        if key.startswith("provider") and (system["type"] == "smbfs" or not system["isLocal"]):
            problems.append(f"{key} is not a local provider file")
    if problems:
        return problems, facts
    for kind in ("full", "partial"):
        native, provider = facts["native_" + kind], facts["provider_" + kind]
        if native["size"] != provider["size"]:
            problems.append(f"{kind}: native and provider sizes differ")
        if native["mtimeNs"] // 10**9 != provider["mtimeNs"] // 10**9:
            problems.append(f"{kind}: native and provider modification times differ")
    full = facts["provider_full"]
    if full["allocated"] or not full["dataless"]:
        problems.append("full: provider copy is not evicted")
    end = slot_offset(args, args.first_slot + args.rounds) - args.partial_gap
    if end > facts["native_partial"]["size"]:
        problems.append(f"partial: slots need {end / GIB:.2f} GiB; fixture has "
                        f"{facts['native_partial']['size'] / GIB:.2f} GiB")
    return problems, facts


def print_checks(problems, facts):
    for kind in ("full", "partial"):
        if "native_" + kind in facts:
            fact = facts["native_" + kind]
            print(f"{kind} fixture: {fact['size'] / GIB:.2f} GiB ({fact['size']} bytes)")
    if "provider_partial" in facts:
        print(f"partial provider allocation: {facts['provider_partial']['allocated'] / MIB:.1f} MiB")
    for problem in problems:
        print("FAIL " + problem)
    print("Preflight passed." if not problems else "Preflight failed.")


class Series:
    def __init__(self, args, setup, folder):
        self.args, self.setup, self.folder = args, setup, folder
        self.samples, self.hashes, self.native_snapshots = [], {}, {}
        self.clone = folder / "local-control" / "clone.bin"
        self.evidence = folder / "samples"
        self.evidence.mkdir()
        self.lines = (folder / "samples.jsonl").open("x")
        self.log_file = (folder / "fetch-log.ndjson").open("x")
        predicate = 'subsystem == "dev.tinymounter.prototype" AND category == "fetch"'
        try:
            self.log = subprocess.Popen(["log", "stream", "--info", "--style", "ndjson", "--predicate", predicate],
                                        stdout=self.log_file, stderr=subprocess.DEVNULL)
        except OSError:
            self.log = None
        time.sleep(2)  # log stream needs a moment before it delivers events
        self.log_status = "captured" if self.log and self.log.poll() is None else "unavailable"

    def measure(self, round_number, workload, body):
        sample = {"id": f"{round_number:02d}-{workload}", "round": round_number, "workload": workload,
                  "cacheLabel": LABELS[workload], "startedUTC": now_utc(), "valid": False, "failure": None}
        before_text, before = smb_rx()
        (self.evidence / (sample["id"] + "-smb-before.txt")).write_text(before_text)
        sample["wallStart"] = time.time()
        try:
            body(sample)
            sample["valid"] = True
        except Stop as error:
            sample["failure"] = str(error)
            self.record(sample, before)
            raise
        except (OSError, RuntimeError, ValueError, KeyError, IndexError, subprocess.SubprocessError) as error:
            sample["failure"] = label(error)
        self.record(sample, before)
        return sample

    def record(self, sample, before):
        sample.setdefault("wallEnd", time.time())
        after_text, after = smb_rx()
        (self.evidence / (sample["id"] + "-smb-after.txt")).write_text(after_text)
        if before is not None and after is not None:
            sample["smbRxDelta"] = sum(after[key] - before[key] for key in after.keys() & before.keys())
        if sample["valid"] and sample["workload"] in (
                "native-full", "provider-full", "native-partial", "provider-partial"):
            if sample.get("smbRxDelta", -1) < sample["bytes"]:
                sample["valid"] = False
                sample["failure"] = "SMB counters do not establish payload ingress"
        self.samples.append(sample)
        self.lines.write(json.dumps(sample) + "\n")
        self.lines.flush()
        if sample["valid"]:
            detail = f"{sample['mbps']:.1f} MB/s"
            if sample.get("firstReadSeconds") is not None:
                detail += f"; first read {sample['firstReadSeconds']:.3f} s"
        else:
            detail = "FAILED: " + sample["failure"]
        print(f"{sample['id']}: {detail}", flush=True)

    def bench(self, sample, path, *extra):
        command = [str(BENCH), path, *extra, "--cache-label", sample["cacheLabel"]]
        result = subprocess.run(command, text=True, capture_output=True, timeout=self.args.sample_timeout)
        sample["wallEnd"] = time.time()
        (self.evidence / (sample["id"] + ".jsonl")).write_text(result.stdout)
        (self.evidence / (sample["id"] + ".stderr")).write_text(result.stderr)
        if result.returncode:
            raise RuntimeError(f"transfer-bench exited {result.returncode}")
        record = json.loads(result.stdout.splitlines()[0])
        metrics = record["metrics"]
        sample.update(bytes=metrics["bytes"], seconds=metrics["transferSeconds"], mbps=record["megabytesPerSecond"],
                      firstReadSeconds=metrics.get("firstReadSeconds"), openSeconds=record["openSeconds"],
                      filesystem=record["sourceFilesystem"], hydrationPolicy=record["effectiveHydrationPolicy"])
        return record

    def check_native(self, record, kind):
        if record["sourceFilesystem"]["type"] != "smbfs":
            raise Stop("native source is not on smbfs")
        reference = self.native_snapshots.setdefault(kind, record["sourceSnapshot"])
        if record["sourceSnapshot"] != reference:
            raise Stop(f"native {kind} fixture metadata changed during the run")

    def native_full(self, sample):
        self.check_native(self.bench(sample, self.setup["native_full"], "--no-cache"), "full")

    def provider_full(self, sample):
        path = self.setup["provider_full"]
        sample["stateBefore"] = before = state(path)
        if before["allocated"] or not before["dataless"]:
            raise RuntimeError("provider copy was not evicted; not timed")
        result = subprocess.run([str(HELPER), path], text=True, capture_output=True, timeout=self.args.sample_timeout)
        sample["wallEnd"] = time.time()
        (self.evidence / (sample["id"] + ".stderr")).write_text(result.stderr)
        sample["stateAfter"] = after = state(path)
        lines = result.stdout.splitlines()
        sample["helper"] = helper = json.loads(lines[0]) if lines else {}
        if result.returncode or "accessorSeconds" not in helper:
            raise RuntimeError(f"coordination failed: {helper.get('errorDomain')} {helper.get('errorCode')}")
        if after["dataless"] or after["allocated"] < after["size"]:
            raise RuntimeError("accessor entered before the copy was fully local")
        seconds = helper["accessorSeconds"]
        sample.update(bytes=after["size"], seconds=seconds, mbps=after["size"] / seconds / 1e6)

    def provider_cached(self, sample):
        path = self.setup["provider_full"]
        sample["stateBefore"] = before = state(path)
        if before["dataless"] or before["allocated"] < before["size"]:
            raise RuntimeError("provider copy is not fully local; not timed")
        record = self.bench(sample, path, "--no-cache")
        if record["hydrationAllowed"] or record["effectiveHydrationPolicy"] != 1:
            raise RuntimeError("hydration was not disabled")
        if not record["sourceFilesystem"]["isLocal"] or state(path)["allocated"] != before["allocated"]:
            raise RuntimeError("cached read changed the provider copy")

    def local_clone(self, sample):
        if not self.clone.exists():
            raise RuntimeError("no local clone; not timed")
        if not self.bench(sample, str(self.clone), "--no-cache")["sourceFilesystem"]["isLocal"]:
            raise RuntimeError("local control is not on a local volume")

    def native_partial(self, sample, slot):
        offset = slot_offset(self.args, slot)
        sample.update(slot=slot, offset=offset)
        record = self.bench(sample, self.setup["native_partial"], "--offset", str(offset),
                            "--length", str(self.args.partial_length), "--no-cache")
        self.check_native(record, "partial")

    def provider_partial(self, sample, slot):
        path, offset = self.setup["provider_partial"], slot_offset(self.args, slot)
        sample.update(slot=slot, offset=offset)
        sample["stateBefore"] = before = state(path)
        record = self.bench(sample, path, "--offset", str(offset), "--length", str(self.args.partial_length),
                            "--no-cache", "--allow-hydration")
        sample["stateAfter"] = after = state(path)
        sample["allocationGrowth"] = growth = after["allocated"] - before["allocated"]
        if record["sourceFilesystem"]["type"] == "smbfs":
            raise RuntimeError("provider source is on smbfs")
        if growth < self.args.partial_length:
            raise RuntimeError("range was not fresh: allocation grew less than its length")

    def hash_into(self, key, path, offset, length, nocache=False):
        try:
            self.hashes[key] = {"sha256": sha256(path, offset, length, nocache)}
        except OSError as error:
            # EDEADLK (11) here means bytes were missing and hydration was off.
            self.hashes[key] = {"failure": label(error)}
        except RuntimeError as error:
            self.hashes[key] = {"failure": str(error)}

    def make_clone(self):
        self.clone.parent.mkdir()
        if subprocess.run(["cp", "-c", self.setup["provider_full"], str(self.clone)], capture_output=True).returncode:
            print("Local clone failed; local-clone samples will fail.", flush=True)
            self.clone.unlink(missing_ok=True)

    def wait_for_eviction(self, finished_round):
        print(f"Round {finished_round} done. Evict only the full fixture's provider copy now; "
              f"waiting up to {self.args.evict_timeout} s.", flush=True)
        path, start = self.setup["provider_full"], time.monotonic()
        while time.monotonic() - start < self.args.evict_timeout:
            current = state(path)
            if not current["allocated"] and current["dataless"]:
                time.sleep(5)  # let fileproviderd settle before the next timed sample
                self.evictions.append({"afterRound": finished_round, "waitSeconds": time.monotonic() - start,
                                       "partialAllocated": state(self.setup["provider_partial"])["allocated"]})
                print("Eviction verified.", flush=True)
                return
            time.sleep(2)
        raise Stop(f"full fixture was not evicted within {self.args.evict_timeout} s")

    def run(self):
        self.evictions = []
        for round_number in range(1, self.args.rounds + 1):
            forward = round_number % 2 == 1
            if round_number > 1:
                self.wait_for_eviction(round_number - 1)
            pair = [("native-full", self.native_full), ("provider-full", self.provider_full)]
            for workload, body in pair if forward else pair[::-1]:
                self.measure(round_number, workload, body)
            full = state(self.setup["provider_full"])
            local = not full["dataless"] and full["allocated"] >= full["size"]
            if local and not self.clone.exists() and not self.clone.parent.exists():
                self.make_clone()
            pair = [("provider-cached", self.provider_cached), ("local-clone", self.local_clone)]
            for workload, body in pair if forward else pair[::-1]:
                self.measure(round_number, workload, body)
            if local:
                self.hash_into(f"{round_number:02d}-provider-full", self.setup["provider_full"], 0, full["size"])
            slot = self.args.first_slot + round_number - 1
            pair = [("native-partial", lambda s: self.native_partial(s, slot)),
                    ("provider-partial", lambda s: self.provider_partial(s, slot))]
            results = {workload: self.measure(round_number, workload, body)
                       for workload, body in (pair if forward else pair[::-1])}
            if results["provider-partial"]["valid"]:
                self.hash_into(f"{round_number:02d}-provider-partial", self.setup["provider_partial"],
                               slot_offset(self.args, slot), self.args.partial_length)

    def finish(self, complete):
        if self.log:
            time.sleep(2)
            if self.log.poll() is not None:
                self.log_status = "log stream exited early; callbacks incomplete"
            self.log.terminate()
            self.log.wait(timeout=10)
        self.log_file.close()
        self.lines.close()
        if complete:
            print("Hashing native references and the local clone outside timing.", flush=True)
            full_size = os.stat(self.setup["native_full"]).st_size
            self.hash_into("native-full", self.setup["native_full"], 0, full_size, nocache=True)
            for slot in range(self.args.first_slot, self.args.first_slot + self.args.rounds):
                self.hash_into(f"native-slot-{slot}", self.setup["native_partial"], slot_offset(self.args, slot),
                               self.args.partial_length, nocache=True)
            if self.clone.exists():
                self.hash_into("local-clone", str(self.clone), 0, full_size)
        if self.clone.exists():
            self.clone.unlink()
        callbacks = parse_fetch_log(self.folder / "fetch-log.ndjson", self.args.app)
        for sample in self.samples:
            sample["verification"] = self.verification(sample) if complete else "not performed: run incomplete"
            sample["finalValid"] = sample["valid"] and sample["verification"] in ("matched", "native reference")
            if sample["workload"].startswith("provider"):
                sample["fetchCallbacks"] = summarize_callbacks(callbacks, sample["wallStart"], sample["wallEnd"])
                if sample["workload"] == "provider-full":
                    observed = sample["fetchCallbacks"]
                    if (self.log_status != "captured" or observed["count"] != 1 or observed["failed"]
                            or observed["modes"] != ["full/full"] or observed["bytes"] != sample.get("bytes")):
                        sample["finalValid"] = False
                        sample["failure"] = "full-download callback evidence is missing or inconsistent"

    def verification(self, sample):
        def match(key, reference):
            got, want = self.hashes.get(key, {}), self.hashes.get(reference, {})
            if "sha256" not in got or "sha256" not in want:
                return "hash unavailable: " + (got.get("failure") or want.get("failure") or "not hashed")
            return "matched" if got["sha256"] == want["sha256"] else "MISMATCH"
        round_key = f"{sample['round']:02d}"
        workload = sample["workload"]
        if workload in ("native-full", "native-partial"):
            return "native reference"
        if workload in ("provider-full", "provider-cached"):
            return match(f"{round_key}-provider-full", "native-full")
        if workload == "local-clone":
            return match("local-clone", "native-full")
        return match(f"{round_key}-provider-partial", f"native-slot-{sample['slot']}")


def parse_fetch_log(path, app):
    callbacks = []
    for line in path.read_text(errors="replace").splitlines():
        try:
            event = json.loads(line)
            when = datetime.datetime.strptime(event["timestamp"], "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
        except (ValueError, KeyError, TypeError):
            continue
        if not event.get("processImagePath", "").startswith(str(app) + "/Contents/PlugIns/"):
            continue
        message = event.get("eventMessage", "")
        found = FETCH_LINE.search(message)
        if found:
            callbacks.append({"time": when, "mode": found[1], "kind": found[2], "bytes": int(found[3]),
                              "queue": float(found[4]), "callback": float(found[5]), "transfer": float(found[6])})
        elif " failed " in message:
            callbacks.append({"time": when, "mode": "failed"})
    return callbacks


def summarize_callbacks(callbacks, start, end):
    inside = [item for item in callbacks if start <= item["time"] <= end]
    done = [item for item in inside if item["mode"] != "failed"]
    return {"count": len(done), "failed": len(inside) - len(done),
            "modes": sorted({f"{item['mode']}/{item['kind']}" for item in done}),
            "bytes": sum(item["bytes"] for item in done),
            "callbackSeconds": sum(item["callback"] for item in done),
            "appTransferSeconds": sum(item["transfer"] for item in done),
            "beyondTransferSeconds": sum(item["callback"] - item["transfer"] for item in done)}


def spread(values):
    if not values:
        return None
    return {"n": len(values), "median": statistics.median(values), "min": min(values), "max": max(values)}


def group_stats(samples, control, provider):
    valid = [sample for sample in samples if sample.get("finalValid")]
    by_round = lambda name: {s["round"]: s for s in valid if s["workload"] == name}
    controls, providers = by_round(control), by_round(provider)
    total = lambda name: sum(1 for s in samples if s["workload"] == name)
    paired = [providers[r]["mbps"] / controls[r]["mbps"] for r in sorted(controls.keys() & providers.keys())]
    result = {"control": spread([s["mbps"] for s in controls.values()]),
              "provider": spread([s["mbps"] for s in providers.values()]),
              "pairedRatio": spread(paired),
              "invalid": {control: total(control) - len(controls), provider: total(provider) - len(providers)}}
    if result["control"] and result["provider"]:
        result["ratioOfMedians"] = result["provider"]["median"] / result["control"]["median"]
    def first(group):
        return spread([s["firstReadSeconds"] for s in group.values() if s.get("firstReadSeconds") is not None])
    if provider == "provider-partial":
        result.update(controlFirstRead=first(controls), providerFirstRead=first(providers))
    beyond = [s["fetchCallbacks"]["beyondTransferSeconds"] for s in providers.values()
              if s.get("fetchCallbacks", {}).get("count")]
    result["callbackBeyondTransfer"] = spread(beyond)
    return result


def describe(value, unit="MB/s", scale=1.0, digits=1):
    if not value:
        return "no valid samples"
    return (f"{value['median'] * scale:.{digits}f} {unit} median, {value['min'] * scale:.{digits}f}–"
            f"{value['max'] * scale:.{digits}f}, n={value['n']}")


def summarize(samples):
    return {group: group_stats(samples, control, provider) for group, control, provider in GROUPS}


def print_summary(summary):
    names = {"full": ("native", "provider download"), "cached": ("local clone", "provider cached"),
             "partial": ("native", "provider")}
    for group, stats in summary.items():
        control, provider = names[group]
        print(f"{group}: {provider} {describe(stats['provider'])}; {control} {describe(stats['control'])}")
        if stats.get("ratioOfMedians") is not None:
            print(f"  ratio of medians {stats['ratioOfMedians']:.1%}; paired "
                  f"{describe(stats['pairedRatio'], '%', 100)}")
        if group == "partial":
            print(f"  first read: provider {describe(stats['providerFirstRead'], 's', 1, 3)}; "
                  f"native {describe(stats['controlFirstRead'], 's', 1, 3)}")
        if stats["callbackBeyondTransfer"]:
            print(f"  callback time beyond app transfer {describe(stats['callbackBeyondTransfer'], 's', 1, 3)}")
        invalid = {name: count for name, count in stats["invalid"].items() if count}
        if invalid:
            print("  invalid samples: " + ", ".join(f"{name} {count}" for name, count in invalid.items()))


def command_preflight(args):
    disable_hydration()
    problems, facts = preflight_checks(args, load_setup(args.setup))
    print_checks(problems, facts)
    return 1 if problems else 0


def command_run(args):
    disable_hydration()
    setup = load_setup(args.setup)
    problems, facts = preflight_checks(args, setup)
    if problems:
        print_checks(problems, facts)
        return 1
    folder = args.results_dir.absolute()
    folder.parent.mkdir(parents=True, exist_ok=True)
    # The core's MNT_LOCAL check refuses a stage directory on SMB or NFS.
    capture([str(BENCH), str(BENCH), "--length", "0", "--stage-dir", str(folder.parent)])
    folder.mkdir()
    status = subprocess.run(["git", "-C", str(ROOT), "status", "--porcelain"], text=True, capture_output=True).stdout
    manifest = {
        "startedUTC": now_utc(), "localTime": datetime.datetime.now().astimezone().isoformat(),
        "buildLabel": args.build_label, "buildCommitDeclared": args.build_commit, "accessMode": args.access_mode,
        "app": codesign_info(args.app), "provider": codesign_info(provider_bundle(args.app)),
        "toolsCommit": capture(["git", "-C", str(ROOT), "rev-parse", "HEAD"]).strip(), "toolsClean": not status,
        "setup": setup, "fixtures": facts, "rounds": args.rounds, "blockSize": MIB,
        "partial": {"length": args.partial_length, "gap": args.partial_gap, "start": args.partial_start,
                    "firstSlot": args.first_slot},
        "nasCacheState": "unknown; not controlled", "cacheLabels": LABELS,
        "note": args.note,
    }
    (folder / "manifest.json").write_text(json.dumps(manifest, indent=2))
    for name, command in [("smb-settings", ["smbutil", "statshares", "-a"]),
                          ("hardware", ["sysctl", "hw.model", "hw.memsize", "hw.ncpu"]), ("os", ["sw_vers"])]:
        (folder / (name + ".txt")).write_text(capture(command))
    series = Series(args, setup, folder)
    complete = False
    try:
        series.run()
        complete = True
    except Stop as error:
        print(f"Run stopped: {error}", file=sys.stderr)
    finally:
        series.finish(complete)
        summary = summarize(series.samples)
        (folder / "results.json").write_text(json.dumps(
            {"complete": complete, "manifest": manifest, "samples": series.samples, "hashes": series.hashes,
             "evictions": series.evictions, "fetchLog": series.log_status, "summary": summary}, indent=2))
    print(f"{args.build_label}, {args.access_mode}: " + ("complete" if complete else "INCOMPLETE")
          + f"; fetch log {series.log_status}")
    print_summary(summary)
    unexpected = [s["id"] for s in series.samples if s["workload"] == "provider-full" and s["valid"]
                  and s["fetchCallbacks"]["modes"] != ["full/full"]]
    if unexpected:
        print("Provider downloads without exactly full-mode callbacks in the log: " + ", ".join(unexpected))
    mismatches = [s["id"] for s in series.samples if s["verification"] == "MISMATCH"]
    if mismatches:
        print("HASH MISMATCH: " + ", ".join(mismatches))
    return 0 if complete and all(sample["finalValid"] for sample in series.samples) else 1


def environment(results):
    manifest = results["manifest"]
    hardware = Path(results["folder"], "hardware.txt").read_text()
    os_text = Path(results["folder"], "os.txt").read_text()
    fixtures = {key: (value["size"], value["mtimeNs"]) for key, value in manifest["fixtures"].items()
                if key.startswith("native")}
    return {"fixtures": fixtures, "partial geometry": manifest["partial"], "rounds": manifest["rounds"],
            "native hashes": {key: value.get("sha256") for key, value in results["hashes"].items()
                              if key.startswith("native-")},
            "SMB settings": Path(results["folder"], "smb-settings.txt").read_text(),
            "tools commit": manifest["toolsCommit"], "hardware": hardware, "OS": os_text}


def comparison_line(base, current):
    if not base or not current:
        return "no paired ratios to compare"
    if current["max"] < base["min"]:
        return "every current pair is below every baseline pair"
    if current["min"] > base["max"]:
        return "every current pair is above every baseline pair"
    return "paired ranges overlap; no difference shown at this sample size"


def command_compare(args):
    runs = []
    for folder in (args.baseline, args.current):
        results = json.loads((folder / "results.json").read_text())
        results["folder"] = str(folder)
        if not results["complete"]:
            raise Stop("a run is incomplete; repeat it")
        runs.append(results)
    base, current = runs
    labels = [f"{r['manifest']['buildLabel']} ({r['manifest']['buildCommitDeclared']}, "
              f"{r['manifest']['accessMode']})" for r in runs]
    print(f"Baseline: {labels[0]}\nCurrent: {labels[1]}")
    old_environment, new_environment = environment(base), environment(current)
    differences = [key for key, value in old_environment.items() if new_environment[key] != value]
    for key in differences:
        print(f"Not matched: {key}")
    hashes = [run["manifest"]["app"].get("CDHash") for run in runs]
    if None in hashes:
        print("Not matched: an app signature is unavailable, so build identity is unknown")
    same_build = None not in hashes and hashes[0] == hashes[1]
    same_mode = base["manifest"]["accessMode"] == current["manifest"]["accessMode"]
    if differences or None in hashes:
        print("Attributes: nothing; setup or build identity is not matched. Each run's own ratios stand.")
    elif same_mode and not same_build:
        print("Attributes: a build difference at matched access mode.")
    elif same_build and not same_mode:
        print("Attributes: an access-mode difference at matched build.")
    else:
        print("Attributes: nothing; build and access mode " + ("both differ." if not same_build else "both match."))
    for group, _, _ in GROUPS:
        old, new = base["summary"][group], current["summary"][group]
        print(f"{group}:")
        for name, stats in (("baseline", old), ("current", new)):
            ratio = stats.get("ratioOfMedians")
            ratio_text = f"{ratio:.1%}" if ratio is not None else "n/a"
            print(f"  {name}: ratio of medians {ratio_text}; paired {describe(stats['pairedRatio'], '%', 100)}; "
                  f"provider {describe(stats['provider'])}")
            if stats["pairedRatio"] and stats["pairedRatio"]["n"] < 5:
                print(f"  {name}: fewer than five valid pairs; not comparable")
            if group != "cached" and ratio is not None:
                met = "meets" if ratio >= ACCEPTED_TARGET else "is below"
                print(f"  {name}: {met} the accepted 90% target")
        print("  " + comparison_line(old["pairedRatio"], new["pairedRatio"]))
        if group == "partial":
            for name, stats in (("baseline", old), ("current", new)):
                print(f"  {name} first read: provider {describe(stats['providerFirstRead'], 's', 1, 3)}; "
                      f"native {describe(stats['controlFirstRead'], 's', 1, 3)}")
            if old["providerFirstRead"] and new["providerFirstRead"]:
                if new["providerFirstRead"]["min"] > old["providerFirstRead"]["max"]:
                    print("  every current provider first read is slower than every baseline one")
            print("  partial reads have missed 90% since the first measurement; below 90% in both is that deficit")
        for name, stats in (("baseline", old), ("current", new)):
            if stats["callbackBeyondTransfer"]:
                print(f"  {name} callback beyond app transfer: {describe(stats['callbackBeyondTransfer'], 's', 1, 3)}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("preflight", "run"):
        sub = commands.add_parser(name)
        sub.add_argument("--setup", type=Path, required=True)
        sub.add_argument("--app", type=Path, required=True, help="the installed, running app bundle")
        sub.add_argument("--rounds", type=int, default=5, choices=range(1, 11), metavar="1..10")
        sub.add_argument("--first-slot", type=int, default=0, choices=range(0, 100), metavar="0..99")
        sub.add_argument("--partial-length", type=int, default=512 * MIB)
        sub.add_argument("--partial-gap", type=int, default=GIB)
        sub.add_argument("--partial-start", type=int, default=GIB)
        if name == "run":
            sub.add_argument("--results-dir", type=Path, required=True, help="new local directory")
            sub.add_argument("--build-label", required=True)
            sub.add_argument("--build-commit", required=True, help="declared by the parent; not verifiable here")
            sub.add_argument("--access-mode", required=True, choices=["read-only", "writable"])
            sub.add_argument("--note", default="", help="setup facts the tool cannot see, e.g. PARTIAL e1 history")
            sub.add_argument("--sample-timeout", type=int, default=900)
            sub.add_argument("--evict-timeout", type=int, default=900)
    sub = commands.add_parser("compare")
    sub.add_argument("baseline", type=Path)
    sub.add_argument("current", type=Path)
    args = parser.parse_args()
    if args.command != "compare":
        if not 64 * MIB <= args.partial_length <= 4 * GIB or args.partial_length % MIB:
            parser.error("--partial-length must be whole MiB, 64 MiB..4 GiB")
        if args.partial_gap < 64 * MIB or args.partial_start < 0:
            parser.error("--partial-gap must be at least 64 MiB and --partial-start non-negative")
        args.app = args.app.absolute()
    handler = {"preflight": command_preflight, "run": command_run, "compare": command_compare}[args.command]
    return handler(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Stop, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"Stopped: {label(error)}", file=sys.stderr)
        sys.exit(1)
