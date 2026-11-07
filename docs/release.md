# Install TinyMounter 0.1.1

This release is for personal use on **Apple silicon with macOS 27 or later**.
It uses development signing, without Apple notarization. Intel Macs and older macOS versions
are not supported by this package. Download it while signed in to the private GitHub repository:

[TinyMounter 0.1.1](https://github.com/allpan3/tinymounter/releases/tag/v0.1.1)

## Install or update

1. Download `TinyMounter-0.1.1-macOS-arm64.dmg` and open it.
2. If TinyMounter is running, let pending uploads finish, then quit it from its menu.
3. Drag `TinyMounter.app` to Applications, replacing the existing app, then eject the DMG.
   Keep only one installed copy. The app is already signed; no Terminal signing command is needed.
4. Open TinyMounter from Applications. If macOS blocks it because Apple cannot verify it,
   use **System Settings → Privacy & Security → Open Anyway**, confirm Open Anyway again,
   and authenticate with your Mac administrator account if asked.
   Do not turn off Gatekeeper or change system security settings.
5. If macOS asks, enable TinyMounter under **General → Login Items & Extensions → File Providers**.
   Add your server and select its share once. Choose a folder and click Add; TinyMounter
   connects automatically when needed.

The update retains the installed app's signing identity, bundle identifiers, App Group and
sandbox entitlements. It does not migrate or clear settings. If an older experimental setup
is rejected, finish or export pending files before using Start Fresh and adding locations again.

Use Finder for the move into Applications before opening the app. Launching a quarantined copy
from a temporary location can prevent macOS from enabling its File Provider; TinyMounter reports
this with instructions to quit, move it through Finder, and reopen the installed copy.

The development certificate expires on October 19, 2027. A newly signed release will be needed
before then. This is not a Developer ID distribution build; other Macs have not been qualified.

## What to expect

Browse in Finder, open files on demand, and use Keep Downloaded for offline access. Enable
writes only for locations you want to edit. Ordinary saves, file/folder organization, Finder
file Replace, permanent deletion, Preview/Xcode saves and offline edits have signed VM checks.
Keep NAS snapshots or backups: TinyMounter does not keep previous remote versions or a Trash.

Known limits for this release:

- Severe system-wide disk-pressure eviction remains a future validation task. Low-space refusal
  and offline-edit retention through a full macOS restart passed.
- Repeated outages once hung Apple's SMB authentication service; Finder also could not reconnect.
  Pending upload data survived, but that trial needed VM intervention to restore the native mount.
- List a destination folder online before moving files into it offline.
- The published 0.1.1 predates the [Folder Replace follow-up](results/2026-11-06-folder-replace.md)
  and its automatic-retry fix. Package editing and Finder Merge remain unverified.
  Read-performance targets remain unmet. Daily-use feedback on the physical Mac is the next acceptance step.
- File Provider locations use a hidden SMB mount. Finder hides it, but some file managers,
  such as QSpace Pro, list it as a separate volume. 0.2.0 plans to remove this mount.
- There is no automatic updater. Install later releases by replacing the app after uploads finish.

## Source and licences

TinyMounter's own code is MIT licensed. The separate `libTinyMounterSMB.dylib` contains modified
libsmb2 6.3 under LGPL-2.1-or-later. The DMG includes both licences and the library notices separately from its short Read Me;
the app also includes the library's licence. The release supplies `TinyMounter-0.1.1-source.tar.gz`,
with the complete matching app/library source, modifications and build scripts. This permits
rebuilding the app with a modified library; no signing key is required from the publisher.

### Rebuild and replace the library

Extract the source archive and edit the library under `Vendor/libsmb2`. With Xcode 27 and your
own Apple development team, regenerate and build the app and its embedded library together:

```sh
python3 Tools/generate-project.py
xcodebuild -project TinyMounter.xcodeproj -scheme TinyMounter -configuration Release \
  -derivedDataPath .build/relinked DEVELOPMENT_TEAM=YOUR_TEAM \
  TINYMOUNTER_BUNDLE_ID=your.own.tinymounter \
  TINYMOUNTER_APP_GROUP=YOUR_TEAM.your.own.tinymounter build
```

Use identifiers signed by your own team. This produces your separate app, provider and rebuilt
library with consistent signing; it does not open the publisher's App Group. The library target
is `TinyMounterSMB`, and the app links it dynamically at `@rpath/libTinyMounterSMB.dylib`.
For an unsigned compile check, add `CODE_SIGNING_ALLOWED=NO`; normal File Provider operation
requires a signed app. You may modify, rebuild and debug library changes under its LGPL terms.
Keep the sandbox and matching app/provider identity checks intact.

For this project's development environment, run app builds and checks in the VM as described
in `AGENTS.md`. `Tools/package-release.py` packages a signed app; create the matching source
archive with:

```sh
git archive --format=tar.gz --prefix=TinyMounter-0.1.1/ \
  --output=TinyMounter-0.1.1-source.tar.gz v0.1.1
```
