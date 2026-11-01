#!/usr/bin/env python3
"""Keep real server, share, account and NAS file names out of published text.

The denylist lives in the Git directory (info/private-names), so it is never committed or
pushed. The pre-push hook checks every commit that the remote doesn't have yet.

  check-private-names.py refresh --mount PATH NAME...  build the denylist from a mounted share
  check-private-names.py install                       install the pre-push hook
  check-private-names.py text [FILE...]                check PR or issue text (stdin without FILE)
  check-private-names.py pre-push REMOTE [URL]         run by the hook
"""

import argparse
import os
import re
import shutil
import subprocess
import sys

# Private IPv4 ranges. Real addresses are as private as names.
PRIVATE_IP = re.compile(
    r"(?<![\d.])(?:10\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])|192\.168)\.\d{1,3}\.\d{1,3}(?![\d.])")
MIN_FILE_NAME = 6

HOOK = """#!/bin/sh
# Installed by check-private-names.py install; older checkouts use the copy beside it.
script="$(git rev-parse --show-toplevel)/Tools/check-private-names.py"
[ -f "$script" ] || script="$(dirname "$0")/check-private-names.py"
exec python3 "$script" pre-push "$@"
"""


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True,
                          errors="replace").stdout


def common_dir():
    return os.path.abspath(git("rev-parse", "--git-common-dir").strip())


def denylist_path():
    return os.path.join(common_dir(), "info", "private-names")


WORD = re.compile(r"[a-z0-9]+")


def matches(names, text):
    """Names in text, case-insensitive, not inside a longer word."""
    text = text.lower()
    words = set(WORD.findall(text))
    found = set()
    for name in names:
        lowered = name.lower()
        parts = WORD.findall(lowered)
        # Cheap prefilter: every word of the name must occur somewhere in the text.
        if parts and all(p in words for p in parts) and re.search(
                r"(?<![a-z0-9])" + re.escape(lowered) + r"(?![a-z0-9])", text):
            found.add(lowered)
    return found


def share_names(mount, depth):
    names, pending = set(), [(mount, 0)]
    while pending:
        folder, level = pending.pop()
        try:
            entries = list(os.scandir(folder))
        except OSError:
            continue
        for entry in entries:
            if entry.name.startswith("."):
                continue
            names.add(entry.name)
            if level < depth and entry.is_dir(follow_symlinks=False):
                pending.append((entry.path, level + 1))
    return names


def refresh(args):
    names = {n for n in share_names(args.mount, args.depth) if len(n) >= MIN_FILE_NAME}
    names -= {n for n in names if "\n" in n}
    # A name already in the published history is a generic word such as "backup", not a leak:
    # the history was checked when this list was introduced.
    generic = matches(names, git("log", "-p", "--format=%B", args.published))
    from_share = {n for n in names if n.lower() not in generic}
    kept = sorted(from_share | {n for n in args.names if n.strip()})
    if not kept:
        sys.exit("No names to write.")
    path = denylist_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as out:
        out.write("\n".join(kept) + "\n")
    print(f"Wrote {len(kept)} names to {path}: {len(args.names)} given, {len(from_share)} "
          f"from the share; {len(names) - len(from_share)} generic names left out.")


def install(_):
    path = os.path.join(common_dir(), "hooks", "pre-push")
    if os.path.exists(path) and "check-private-names.py install" not in open(path).read():
        sys.exit(f"{path} already exists; merge it by hand.")
    with open(path, "w") as out:
        out.write(HOOK)
    os.chmod(path, 0o755)
    shutil.copy(__file__, os.path.join(os.path.dirname(path), "check-private-names.py"))
    print(f"Installed {path}.")


def report(label, text):
    denylist = denylist_path()
    if not os.path.exists(denylist):
        sys.exit(f"No denylist at {denylist}. Run: Tools/check-private-names.py refresh "
                 "--mount <mounted share> <server> <share> <account> ...")
    names = [n for n in open(denylist).read().splitlines() if n.strip()]
    problems = sorted(matches(names, text)) + sorted(set(PRIVATE_IP.findall(text)))
    if problems:
        print(f"{label} contains private names or addresses: {', '.join(problems)}",
              file=sys.stderr)
        for line in text.splitlines():
            lowered = line.lower()
            if any(p in lowered for p in problems):
                print(f"  {line.strip()[:160]}", file=sys.stderr)
    return not problems


def check_text(args):
    texts = [(f, open(f, errors="replace").read()) for f in args.files] or [
        ("stdin", sys.stdin.read())]
    if not all([report(label, text) for label, text in texts]):
        sys.exit(1)


def pre_push(args):
    clean = True
    for line in sys.stdin:
        local_ref, local_sha, _, _ = line.split()
        if set(local_sha) == {"0"}:
            continue
        # Everything the remote doesn't have yet, also after a force push.
        outgoing = [local_sha, "--not", f"--remotes={args.remote}"]
        messages = git("log", "--format=%B", *outgoing)
        diffs = git("log", "-p", "-M", "--format=", *outgoing).splitlines()
        added = [l for l in diffs if l.startswith(("+", "rename to ", "copy to "))]
        clean &= report(f"Push of {local_ref}", messages + "\n".join(added))
    if not clean:
        sys.exit("Push refused. Replace the names with placeholders such as home-nas, <share> "
                 "and account@nas.local, then rewrite the commits.")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(required=True)
    p = commands.add_parser("refresh")
    p.add_argument("--mount", required=True, help="the mounted real share")
    p.add_argument("--depth", type=int, default=3, help="folder levels below the share root")
    p.add_argument("--published", default="origin/main", help="history known to be clean")
    p.add_argument("names", nargs="+", help="server, share, account and host names")
    p.set_defaults(run=refresh)
    commands.add_parser("install").set_defaults(run=install)
    p = commands.add_parser("text")
    p.add_argument("files", nargs="*")
    p.set_defaults(run=check_text)
    p = commands.add_parser("pre-push")
    p.add_argument("remote")
    p.add_argument("url", nargs="?")
    p.set_defaults(run=pre_push)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
