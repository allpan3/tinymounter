#!/usr/bin/env python3
"""Package an already signed macOS app and its install and licence notices."""
import argparse
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    if app.name != "TinyMounter.app" or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        parser.error("expected TinyMounter.app with a release version")
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
                (ROOT / "docs/release.md", "Build and Release Notes.md"),
                (ROOT / "LICENSE", "LICENSE.txt"),
                (ROOT / "Vendor/libsmb2/LICENCE-LGPL-2.1.txt", "libsmb2-LICENSE.txt"),
                (ROOT / "Vendor/libsmb2/README.md", "libsmb2-NOTICES.md"),
            ]:
                shutil.copyfile(source, notices / name)
            notice = notices / "libsmb2-NOTICES.md"
            notice.write_text(notice.read_text().replace("../../docs/release.md", "Build%20and%20Release%20Notes.md"))
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
