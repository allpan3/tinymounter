# Rebuild and replace the SMB library

Extract the source archive and edit the library under `Vendor/libsmb2`. With Xcode 27 and your
own Apple development team, run the following commands from the extracted directory.

```sh
python3 Tools/generate-project.py
xcodebuild -project TinyMounter.xcodeproj -scheme TinyMounter -configuration Release \
  -derivedDataPath .build/relinked DEVELOPMENT_TEAM=YOUR_TEAM \
  TINYMOUNTER_BUNDLE_ID=your.own.tinymounter \
  TINYMOUNTER_APP_GROUP=YOUR_TEAM.your.own.tinymounter build
```

Use identifiers signed by your own team. This produces your separate app, provider and rebuilt
library, with a separate App Group. The library target
is `TinyMounterSMB`, and the app links it dynamically at `@rpath/libTinyMounterSMB.dylib`.
For an unsigned compile check, add `CODE_SIGNING_ALLOWED=NO`. File Provider requires a
signed app at runtime. You may modify, rebuild and debug library changes under its LGPL terms.
Keep the sandbox and matching app/provider identity checks intact.
