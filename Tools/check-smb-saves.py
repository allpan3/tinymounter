#!/usr/bin/env python3
"""Compare production SMB overwrites with native writes in the disposable macOS VM fixture.

Compile check-smb-saves.swift with TransferCore, SMBEdit.swift, SMBClient.swift and SMBRename.h,
linked to the VM's built libTinyMounterSMB. Pass HELPER SERVER PASSWORD_FILE NEW_EVIDENCE_DIRECTORY;
the file holds the fixture account's password, outside the repository. This creates a fresh
simplify-20261105/saves-* subtree; it refuses existing results. Caches are warmed, residency
unverified. Timing excludes input preparation and hashes; direct reports connection separately.
"""
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import time


def main():
    helper, server, secret, output = sys.argv[1:]
    root = Path(output).resolve()
    mount = Path('/Volumes/tinymounter-single')
    if Path.home() != Path('/Users/user') or not mount.is_mount():
        raise RuntimeError('run only in the macOS VM fixture')
    if not re.fullmatch(r'saves-[a-z0-9-]+', root.name):
        raise ValueError('evidence directory must be named saves-*')
    root.mkdir(exist_ok=False)
    target = mount / 'simplify-20261105' / root.name
    target.mkdir(exist_ok=False)
    samples = []
    for mib in (1, 64):
        data = os.urandom(mib << 20)
        (root / f'input-{mib}.bin').write_bytes(data)
        digest = hashlib.sha256(data).hexdigest()
        for round_number in range(1, 6):
            for label in ('direct', 'native'):
                (target / f'{label}-{mib}-{round_number}.bin').write_bytes(b'0' * len(data))
            order = ('direct', 'native') if round_number % 2 else ('native', 'direct')
            for label in order:
                path = target / f'{label}-{mib}-{round_number}.bin'
                path.read_bytes()
                if label == 'direct':
                    process = subprocess.run([helper, server, secret, str(mib), str(round_number), str(root)],
                                             capture_output=True, text=True, timeout=120)
                    (root / f'{label}-{mib}-{round_number}.log').write_text(process.stdout + process.stderr)
                    process.check_returncode()
                    sample = json.loads(process.stdout)
                else:
                    start = time.monotonic()
                    with path.open('r+b', buffering=0) as file:
                        view = memoryview(data)
                        while view:
                            count = file.write(view)
                            if not count:
                                raise OSError('short native write')
                            view = view[count:]
                        file.truncate()
                        os.fsync(file.fileno())
                    sample = dict(label=label, mib=mib, round=round_number,
                                  seconds=time.monotonic() - start, completed=True)
                sample['digest'] = digest
                samples.append(sample)
                (root / 'samples.json').write_text(json.dumps(samples, indent=2))
                print(json.dumps(sample), flush=True)
    # Audit all files independently on the server; native caching is not proof of remote bytes.


if __name__ == '__main__':
    main()
