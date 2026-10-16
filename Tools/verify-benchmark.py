#!/usr/bin/env python3
"""Local correctness checks, not a NAS or throughput benchmark. Build Release first."""
import hashlib
import ctypes
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
bench = root / ".build/release/transfer-bench"
with tempfile.TemporaryDirectory(prefix="tinymounter-cli-check-") as temporary:
    directory = Path(temporary)
    fixture = directory / "fixture with spaces.bin"
    stage = directory / "staging"
    stage.mkdir()
    payload = os.urandom(8 * 1024 * 1024 + 173)
    fixture.write_bytes(payload)
    cases = [[], ["--offset", "12345", "--length", "51119", "--stage-dir", str(stage), "--verify", "--sync"],
             ["--stage-dir", str(stage), "--verify", "--no-cache"], ["--runs", "2"],
             ["--allow-hydration", "--runs", "2"]]
    libc = ctypes.CDLL(None, use_errno=True)
    inherited_policy = libc.getiopolicy_np(3, 0)
    assert inherited_policy >= 0
    assert libc.setiopolicy_np(3, 0, 1) == 0
    for args in cases:
        result = subprocess.run([str(bench), str(fixture), *args], text=True, capture_output=True, check=True)
        records = [json.loads(line) for line in result.stdout.splitlines()]
        assert len(records) == (2 if "--runs" in args else 1)
        for record in records:
            assert record["cacheStateVerified"] is False
            assert record["sourceFilesystem"]["isLocal"] is True
            assert record["ignoresMaterializationChangeTime"] is False
            assert record["inheritedHydrationPolicy"] == 1
            assert record["hydrationAllowed"] == ("--allow-hydration" in args)
            assert record["effectiveHydrationPolicy"] == (2 if "--allow-hydration" in args else 1)
            if "--verify" in args:
                extent = record["range"]
                expected = payload[extent["offset"]:extent["offset"] + extent["length"]]
                assert record["sha256"] == hashlib.sha256(expected).hexdigest()
            assert record["metrics"]["bytes"] == record["range"]["length"]
        assert not list(stage.iterdir())
        assert fixture.read_bytes() == payload
        print("PASS", args or ["read-to-sink"])
    for args in [["--offset", str(len(payload) + 1)], ["--length", str(len(payload) + 1)],
                 ["--block-size", "0"], ["--runs", "0"], ["--verify"]]:
        result = subprocess.run([str(bench), str(fixture), *args], text=True, capture_output=True)
        assert result.returncode != 0 and not result.stdout
        print("PASS invalid input rejected", args)
    assert libc.getiopolicy_np(3, 0) == 1
    assert libc.setiopolicy_np(3, 0, inherited_policy) == 0
print("Local CLI checks passed. No NAS measurement performed.")
