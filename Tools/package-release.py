#!/usr/bin/env python3
"""Package an already signed macOS app and its install and licence notices."""
import argparse
from pathlib import Path
import plistlib
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
    if app.name != "TinyMounter.app" or version != "0.1.0":
        parser.error("expected the TinyMounter 0.1.0 app")
    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    arch = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip()
    if arch != "arm64":
        parser.error("this release package is for Apple silicon")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"TinyMounter-{version}-macOS-arm64.zip"
    if archive.exists():
        parser.error("output archive already exists")
    with tempfile.TemporaryDirectory(prefix="package-", dir=output) as temporary:
        package = Path(temporary) / f"TinyMounter-{version}"
        package.mkdir()
        staged_app = package / app.name
        try:
            subprocess.run(["ditto", str(app), str(staged_app)], check=True)
            for source, name in [
                (ROOT / "docs/release.md", "Read Me.md"),
                (ROOT / "LICENSE", "LICENSE.txt"),
                (ROOT / "Vendor/libsmb2/LICENCE-LGPL-2.1.txt", "libsmb2-LICENSE.txt"),
                (ROOT / "Vendor/libsmb2/README.md", "libsmb2-NOTICES.md"),
            ]:
                shutil.copyfile(source, package / name)
            notice = package / "libsmb2-NOTICES.md"
            notice.write_text(notice.read_text().replace("../../docs/release.md", "Read%20Me.md"))
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(staged_app)], check=True)
            subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
                            str(package), str(archive)], check=True)
        except BaseException:
            archive.unlink(missing_ok=True)
            raise
        finally:
            subprocess.run([LSREGISTER, "-u", str(staged_app)], capture_output=True)
    print(archive)


if __name__ == "__main__":
    main()
