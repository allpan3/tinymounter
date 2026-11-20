#!/usr/bin/env python3
"""Package an already signed macOS app and its install and licence notices."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-ref", default="HEAD", help="Git commit used to build the signed app")
    args = parser.parse_args()
    app = args.app.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    if app.name != "TinyMounter.app" or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        parser.error("expected TinyMounter.app with a release version")
    commit = subprocess.check_output(["git", "rev-parse", "--verify", "--end-of-options",
                                      args.source_ref + "^{commit}"], cwd=ROOT, text=True).strip()

    def source_file(path):
        return subprocess.check_output(["git", "show", f"{commit}:{path}"], cwd=ROOT)

    source_info = plistlib.loads(source_file("Prototype/Config/App-Info.plist"))
    if any(source_info[key] != info[key] for key in ("CFBundleShortVersionString", "CFBundleVersion")):
        parser.error("source version and build must match the signed app")
    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    arch = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip()
    if arch != "arm64":
        parser.error("this release package is for Apple silicon")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"TinyMounter-{version}-macOS-arm64.dmg"
    if archive.exists():
        parser.error("output archive already exists")
    with tempfile.TemporaryDirectory(prefix="package-", dir=output) as temporary:
        package = Path(temporary) / f"TinyMounter-{version}"
        package.mkdir()
        staged_app = package / app.name
        try:
            subprocess.run(["ditto", str(app), str(staged_app)], check=True)
            (package / "Applications").symlink_to("/Applications")
            (package / "Read Me.txt").write_text(
                "Quit TinyMounter after pending uploads finish.\n"
                "Drag TinyMounter to Applications, replacing the old app, then eject this disk.\n"
                "Open TinyMounter from Applications. If blocked, use System Settings > Privacy & Security > Open Anyway.\n"
                "If Open Anyway is not offered, run this in Terminal, then open TinyMounter again:\n"
                "    xattr -dr com.apple.quarantine /Applications/TinyMounter.app\n"
                "The app is already signed. No Terminal signing command is needed.\n")
            notices = package / "Licences and Source"
            notices.mkdir()
            for source, name in [
                ("LICENSE", "LICENSE.txt"),
                ("Vendor/libsmb2/LICENCE-LGPL-2.1.txt", "libsmb2-LICENSE.txt"),
                ("Vendor/libsmb2/COPYING", "libsmb2-COPYING.txt"),
            ]:
                (notices / name).write_bytes(source_file(source))
            (notices / "Rebuild the SMB library.md").write_bytes((ROOT / "docs/rebuild-smb.md").read_bytes())
            notice = source_file("Vendor/libsmb2/README.md").decode()
            for link in ("../../docs/rebuild-smb.md", "../../docs/release.md#rebuild-and-replace-the-library"):
                notice = notice.replace(f"({link})", "(Rebuild%20the%20SMB%20library.md)")
            (notices / "libsmb2-NOTICES.md").write_text(notice)
            source_archive = notices / f"TinyMounter-{version}-source.tar.gz"
            subprocess.run(["git", "archive", "--format=tar.gz", f"--prefix=TinyMounter-{version}/",
                            "-o", str(source_archive), commit], cwd=ROOT, check=True)
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(staged_app)], check=True)
            subprocess.run(["diskutil", "image", "create", "from", "--volumeName",
                            f"TinyMounter {version}", "--format", "UDZO",
                            str(package), str(archive)], check=True)
        except BaseException:
            archive.unlink(missing_ok=True)
            raise
        finally:
            subprocess.run([LSREGISTER, "-u", str(staged_app)], capture_output=True)
    print(archive)


if __name__ == "__main__":
    main()
