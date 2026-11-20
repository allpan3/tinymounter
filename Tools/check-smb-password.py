#!/usr/bin/env python3
"""Check 0.2.0 password sessions against the disposable VM Samba fixture.

Run it in the VM after Tools/run-checks.sh built the library. Pass SERVER ACCOUNT PASSWORD_FILE
SHARE DENIED_SHARE NEW_EVIDENCE_DIRECTORY. The password file lies outside the repository and
holds the account's password as UTF-8 without a newline. DENIED_SHARE is a share the account
may not open. The operations create, change and delete one step2-* folder at the share root.
Output names no server and no password.
"""
from pathlib import Path
import json
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
PRODUCTS = ROOT / '.build/xcode/Build/Products/Release'


def build(output):
    sources = sorted(str(path) for path in (ROOT / 'Sources/TransferCore').glob('*.swift'))
    sources += [str(ROOT / name) for name in ('Prototype/App/SMBEdit.swift', 'Prototype/App/SMBClient.swift',
                                              'Prototype/App/SMBWatch.swift', 'Tools/check-smb-password.swift')]
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-name', 'PasswordCheck',
                    '-import-objc-header', str(ROOT / 'Prototype/SMB/SMBRename.h'),
                    '-Xcc', f'-I{ROOT / "Vendor/libsmb2/include"}', *sources,
                    f'-L{PRODUCTS}', '-lTinyMounterSMB', '-lsqlite3', '-Xlinker', '-rpath', '-Xlinker', str(PRODUCTS),
                    '-o', str(output)], check=True)


def main():
    server, account, secret, share, denied, evidence = sys.argv[1:]
    secret = Path(secret).resolve()
    if ROOT in secret.parents:
        raise SystemExit('keep the password file outside the repository')
    evidence = Path(evidence)
    evidence.mkdir(parents=True, exist_ok=False)
    helper = evidence / 'check-smb-password'
    build(helper)
    expectations = [
        ('signin', share, lambda r: r['ok'] and r['listed'] >= 0),
        ('wrong-password', share, lambda r: r['ok'] and r['failure'] == 'notAuthenticated'),
        ('share-refusal', 'step2-missing-share', lambda r: r['ok'] and r['failure'] == 'missing'),
        ('share-refusal', denied, lambda r: r['ok'] and r['failure'] == 'noPermission'),
        ('share-names', '', lambda r: r['ok'] and share in r['shares'] and denied in r['shares']
            and not any(name.endswith('$') for name in r['shares'])),
        ('account-forms', share, lambda r: r['ok'] and r['forms']['name'] == 'signed in'),
        ('operations', share, lambda r: r['ok']),
    ]
    failed = 0
    with (evidence / 'results.jsonl').open('w') as log:
        for case, target, expected in expectations:
            process = subprocess.run([str(helper), server, account, str(secret), case, target],
                                     capture_output=True, text=True, timeout=600)
            output = (process.stdout + process.stderr).replace(server, '<server>')
            try:
                result = json.loads(process.stdout.splitlines()[-1])
                passed = expected(result)
            except (IndexError, KeyError, ValueError):
                passed = False
            failed += not passed
            log.write(json.dumps({'case': case, 'passed': passed, 'output': output}) + '\n')
            print(('PASS' if passed else 'FAIL'), case, output.strip())
    helper.unlink()
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
