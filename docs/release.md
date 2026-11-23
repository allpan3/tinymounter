# Install TinyMounter 0.4.2

This release is for personal use on **Apple silicon with macOS 27 or later**.
It uses development signing, without Apple notarization. Intel Macs and older macOS versions
are not supported by this package. Download it from GitHub:

[TinyMounter 0.4.2](https://github.com/allpan3/tinymounter/releases/tag/v0.4.2)

## Install or update

1. Download `TinyMounter-0.4.2-macOS-arm64.dmg` and open it.
2. If TinyMounter is running, let pending uploads finish, then quit it from its menu.
3. Drag `TinyMounter.app` to Applications, replacing the existing app, then eject the DMG.
   Keep only one installed copy. The app is already signed; no Terminal signing command is needed.
4. Open TinyMounter from Applications. If macOS blocks it because Apple cannot verify it,
   use **System Settings → Privacy & Security → Open Anyway**, confirm Open Anyway again,
   and authenticate with your Mac administrator account if asked.
   If Open Anyway is not offered, remove the download quarantine from this app only, in Terminal:
   `xattr -dr com.apple.quarantine /Applications/TinyMounter.app`. Then open it again.
   Do not turn off Gatekeeper or change system security settings.
5. If macOS asks, enable TinyMounter under **General → Login Items & Extensions → File Providers**.
   In the new location, choose Add Server… in the Server menu. Type the server address, your
   name and your password once, click Sign In, then select the share. Choose a folder and click
   Add; TinyMounter connects automatically when needed. If macOS asks to find devices on the
   local network, click Allow.

TinyMounter keeps the password in a login keychain item, `dev.tinymounter.smb`. File Provider
locations no longer mount the share, and the share-access panel is gone. Server Volume
locations use the same saved password.

An update from 0.2.0 through 0.4.1 keeps the locations, saved servers, keep requests, downloaded
copies and pending uploads.

### Update from 0.1.x: Start Fresh is required

0.2.0 and later cannot read 0.1.x settings. It does not convert them. At the first launch it
refuses them, and General offers Start Fresh.

1. Before you replace the app, open 0.1.x and let pending uploads finish. Copy any file whose
   upload does not finish to a local folder.
2. Install 0.4.2 as above, then click **Start Fresh** in General and confirm it.
3. Add each location again with Add Server…, as in step 5. Set Keep Downloaded again where
   you want offline copies.
4. Eject the old hidden share mount: restart the Mac, or run `mount | grep nobrowse` in
   Terminal and then `diskutil unmount` on the `/Volumes/<share>` path it shows. Finder does
   not show this mount, and TinyMounter works while it is there, but Start Fresh does not remove it.

Start Fresh removes all locations, saved servers, keep requests and downloaded copies from this
Mac, and deletes TinyMounter's keychain items. The files on the server do not change. Changes
that did not upload are kept in a folder that opens in Finder; copy them into the new location.
macOS's own keychain item for the server, from the 0.1.x sign-in, stays. You can delete it in
Keychain Access; TinyMounter does not use it.

The update retains the installed app's signing identity, bundle identifiers and App Group.

Use Finder for the move into Applications before opening the app. Launching a quarantined copy
from a temporary location can prevent macOS from enabling its File Provider; TinyMounter reports
this with instructions to quit, move it through Finder, and reopen the installed copy.

The development certificate expires on October 19, 2027. A newly signed release will be needed
before then. This is not a Developer ID distribution build; other Macs have not been qualified.

## What to expect

Browse in Finder, open files on demand, and use Keep Downloaded for offline access. The menu bar
panel shows each location's state, current uploads and downloads, and recent activity with
Retry. **General → Notifications** chooses, for each kind of event, whether it posts a macOS
notification, shows in the panel, both or neither. Enable writes only for locations you want to
edit. Ordinary saves, file/folder organization, Finder file and folder Replace, permanent
deletion and offline edits have signed VM checks on 0.2.0, and the panel, notifications and
upload recovery on 0.3.x and 0.4.0; Preview and Xcode saves were checked on 0.1.x. A file that you save or
copy in keeps its modification time on the server, as with Finder's own SMB copies, and a saved
kept file shows Available offline again. Keep NAS snapshots or backups: TinyMounter does not
keep previous remote versions or a Trash.

Settings identifies SMB separately from the Finder mode, with a folder icon for File Provider
and a drive icon for Server Volume. A full menu scrolls its contents while Settings and Quit
stay visible.

A create or save waiting for other changes on the share retries automatically without a failure
notification or activity row. Settings keeps the reason while it waits. Successful uploads clear
their earlier failure rows. Stop Uploading can settle an abandoned partial new-file upload after
checking its server identity. A changed resend after late cancellation writes the recorded server
file again; a replacement is refused. Date-only changes stay local without a permission error.

Other file managers, such as QSpace Pro, no longer list a hidden volume for File Provider
locations. A change that another device makes in a folder you have open usually shows in a few
seconds. The delete of a folder's last item, or the rename or delete of a kept file, shows
after about 15 s, when a second listing confirms it. If the server refuses the saved password,
or says that the password must change, the location shows "Sign in again." after one logon
attempt and TinyMounter stops trying. Change the password on the server if needed, then click Sign In Again… and type it.

Known limits for this release:

- If macOS loses its synchronization database, TinyMounter preserves differing local and server
  files for manual recovery. Resolve the local file before removing its location.
- Kept downloads retain their offline policy during Pause. Turn off Keep Downloaded before
  manually removing a kept file’s download.
- Repeated outages can hang Apple's SMB authentication service; Finder then cannot reconnect.
  Pending upload data survives.
- List a destination folder online before moving files into it offline.
- Package editing and Finder Merge remain unverified. Writable sequential reads met the target
  in the VM. Read-only sequential reads fell short with warm server pages. Physical-Mac
  throughput still needs a matched native SMB comparison.
- Change notification (`CHANGE_NOTIFY`) is verified against a Samba 4.19 server only, not
  against a UGREEN NAS. If a server does not send notices, changes show at the next listing,
  60 s or more later.
- Each operation opens its own SMB session, so the server's log shows many logons, with a
  burst after a reconnect. Each Server Volume mount also signs in once with TinyMounter's own
  client before macOS mounts it, which is one extra logon per mount.
- A second TinyMounter build with a different signature, such as a test build, uses the same
  keychain item. macOS then asks for the login keychain password before that build can read it.
- An upload cut off by a network loss finishes by itself when the share connects again: the new
  session asks the server to end the lost one. TinyMounter also remembers lost sessions across a
  quit or restart, but a Force Quit or crash forgets the sessions that were still open. After
  that, or with a server that ignores the request, the upload fails with "Text file busy" and
  retries by itself, with delays that grow to 5 minutes, until the server notices the lost
  connection (on Samba's defaults, up to about 2 hours). The data stays on this Mac.
- While macOS retries an upload that the server refuses, such as a new file in a folder without
  write access, a file kept or changed in the meantime can show Requested for up to about
  25 minutes, and its Kept downloaded shows late. The check waits until macOS has no work left
  for the location, and macOS waits longer between attempts until it stops trying. Kept files
  that were already available offline keep their status, also after a relaunch.
- While a new file uploads to a location, files and folders that another device adds there show
  only when the upload ends: macOS waits with new items until then. Changes and deletions of
  items that Finder already shows, and new items during a save of an existing file, appear as
  usual.
- Rename recovery requires stable server identities for parent folders, including their creation
  times. A server that changes a parent's reported creation time can leave recovery pending;
  Retry does not bypass the replacement check.
- Wake and network-change reconnection of 0.2.0 sessions have not had VM checks.
- There is no automatic updater. Install later releases by replacing the app after uploads finish.

## Source and licences

TinyMounter's own code is MIT licensed; that does not relicense its dependencies. The separate
`libTinyMounterSMB.dylib` contains modified libsmb2 6.3 under LGPL-2.1-or-later. The DMG includes both licences and the library notices separately from its short Read Me;
the app also includes the library's licence. The release supplies `TinyMounter-0.4.2-source.tar.gz`,
both inside the DMG and as a separate download, with the matching app and library source,
modifications and build scripts. This permits
rebuilding the app with a modified library; no signing key is required from the publisher.

### Rebuild and replace the library

Follow the [library rebuild instructions](rebuild-smb.md) with the source archive for your app version.

To package a signed build, run the following command from the development checkout. Set
`SOURCE_COMMIT` to the revision used for that build. The DMG includes that revision’s source
archive, the licences and the instructions for rebuilding the SMB library.

```sh
python3 Tools/package-release.py /path/to/TinyMounter.app --source-ref "$SOURCE_COMMIT" --output dist
```
