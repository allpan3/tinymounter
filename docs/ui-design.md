# User interface design

Decision status: accepted for prototyping. The user evaluates it again on the prototype. Section
10 lists the decisions that are still open. Sections 4 and 5 hold the user's decisions on
Duplicate, overlapping locations, saved Keep Downloaded lists and Pause Downloads. Phase 2 built a
subset: M7 built the Settings window, the menu bar item and notifications, and M8 the Storage
pane and folder completion, with the changes listed below.
M14 adds recursive folder requests and aggregate offline status.
M16 adds Not sufficient space, a free-space instruction and automatic kept-download recovery.
Interactive mockup: [ui-mockup.html](ui-mockup.html).

Current setup: Add offers File Provider or Server Volume. A native volume
covers the whole share, uses its server permissions and has no Read only or Keep Downloaded
control. Remove the share's existing locations before switching modes, including locations
saved under another account. Add connects automatically; saved native volumes also have
Show in Finder, Connect/Disconnect and Remove controls. There is one add flow: shares are added
only in a location, and Servers only lists them (section 4.3). In 0.2.0 a sign-in sheet
replaced the Add Server… address dialog, and a folder browser replaced the Folder Select… panel
([section 11](#11-sign-in-and-folder-browser-020)). The original mockup below is historical.

The current build leaves out the Locations folder and Open Locations Folder (Finder's sidebar
already shows each location), the "Keep this much disk space free" control and Export
Diagnostics; About shows diagnostic counts with Copy. Its menu bar item opens a window-style
`MenuBarExtra` panel (section 5). All UI text is in `Prototype/App/UIText.swift`, so the STE
checker reads one file.
Settings opens at launch when there are no locations or the menu bar item is hidden. Otherwise,
the app starts without opening Settings. Storage shows totals per location, not a file list.
Folder completion lists the typed parent folder 150 ms after the last keystroke and suggests at
most 50 subfolders.

## 1. Principles

- **Finder is the main interface.** Users browse, open, download and keep files offline in Finder
  and other file managers. The app is for setup, status and problems.
- **Mac-native.** A SwiftUI `Settings` scene with a `NavigationSplitView` sidebar, a grouped `Form`,
  and standard controls. It looks like System Settings and uses current system materials, with no
  custom chrome.
- **Apple's words.** Use the terms that macOS itself shows (section 2).
- **One form per location.** All settings of a location are in its pane. To add a location, the
  user duplicates one and changes the copy in the same pane (section 4.2). There is no separate
  add window.
- **No speed modes.** Opening a file streams it where the app allows that. Download Now and Keep
  Downloaded fetch full files. The only choice per location is its connection mode.
- **Honest states.** The app shows "Available offline" only when the Mac has a full copy of the
  last version. Error messages tell the user what to do.
- **Quiet by default.** A menu bar item. Notifications only for problems that need the user.
- **Simplified Technical English.** All UI text follows ASD-STE100 (section 8).

## 2. Terms

Checked on 2026-10-11 against macOS 27.0.1 in the VM: Finder and System Settings strings, Finder
Settings › Sidebar, and Apple's Mac User Guide.

| Item | What macOS shows | UI term | Replaces |
| --- | --- | --- | --- |
| A location that our File Provider extension serves | System Settings › General › Login Items & Extensions: "File Providers", with "File provider extensions allow you to see local files and remote storage files in one view in Finder." Finder Settings › Sidebar › Locations: "Cloud Storage". Developer docs: replicated File Provider extension, domain. | **File Provider** | "Integrated" |
| A share that the macOS SMB client mounts | Finder: Go › "Connect to Server…", "server volume", the sidebar group "Connected servers", "Eject". The Mac User Guide: "volumes or shared folders on the server". | **Server Volume** | "Native SMB" |
| The choice between the two, per location | none | **Finder Mode** | "Connection Mode" |
| One folder with an alias to each location | Finder: "alias", "Make Alias" | **Locations folder** | "Shortcuts folder" |
| A kept file with a full, current copy | Finder: Download Now, Remove Download, Keep Downloaded | **Available offline** | "Offline-ready" |

Why these changes:

- **"Native SMB" is not precise.** Both modes use macOS components. The difference is the data
  path. A server volume reads through the macOS SMB client (`smbfs`). File Provider serves local
  APFS copies and downloads missing data when an app reads it.
- **"Integrated" is not an Apple term.** It is Mountain Duck's name for its File Provider mode
  ([research.md](research.md)).
- **"Cloud Storage" is Finder's group name, but a NAS is not cloud storage.** The UI uses the name
  that System Settings shows, "File Provider", with a one-line description.
- **"Shortcuts" is the name of an Apple app,** and it is the Windows word for an alias. "Locations
  folder" agrees with the app's own Locations list.
- **"Ready" is not an approved STE word.** "Available offline" is.

The other docs use these terms too. Measurement docs keep "native SMB" for the baseline: reads
through the macOS SMB client from a server volume. Mountain Duck's mode names stay as Mountain Duck
writes them.

## 3. Surfaces

| Surface | Purpose |
| --- | --- |
| Menu bar item | Status, transfers, recent activity and quick actions. It keeps the reader running, which reads of data that isn't downloaded need. |
| Settings window | Locations, servers, offline storage, general settings, diagnostics |
| Finder | Locations in the sidebar, status decorations, Keep Downloaded and Allow Removal |
| Notifications | The event kinds that General turns on (section 4.3). By default: sign-in problems, failed uploads and downloads, conflict copies and low disk space |

## 4. Settings window

A standard settings window, about 780 × 540 points, resizable. The sidebar has a search field and
two groups:

- **Locations:** each location, with a folder icon for File Provider or a drive icon for Server
  Volume, and its protocol and Finder mode below its name. The location pane shows its status.
  Right-click (Control-click) a location for its shortcut menu: Show in Finder, Duplicate and
  Remove Location…. The `+` button at the bottom adds an empty location (section 4.2). The `−`
  button removes the selected location.
- **Settings:** General, Storage, Servers and About.

### 4.1 Location pane: all settings in one place

Selecting a location shows one grouped form with all of its settings:

1. **Header.** Icon, name, and a status line such as "Connected · 18.4 GB downloaded · 3 items
   available offline", and a Show in Finder button. If macOS disables the File Provider, show
   "File Provider is off.", instructions to enable it, and Open System Settings… instead.
2. **Source.** Protocol, Finder Mode, Server, Share, Folder and Name. Both modes currently use SMB.
   The user types a folder path, with completion, or clicks Select… to browse the share in the app
   ([section 11](#11-sign-in-and-folder-browser-020)). An empty path means the full share.
3. **Finder Mode.** Choose File Provider or Server volume when adding a location. Native
   volumes use the whole share and its actual name; their Folder and Name fields are omitted.
4. **Keep Downloaded** (File Provider only). Each kept file or folder, with its state: Available
   offline, 42% downloaded, Update in progress, or Not sufficient space. Add with `+`, remove with
   `−`. Keeping a folder keeps all items in it, recursively.
   Allow Removal cancels that request and preserves independently kept descendants. Inherited
   retention has no separate Allow Removal action. A folder stays Requested if a descendant
   listing is incomplete or has unsupported contents. M15 refreshes listed materialized and kept
   folders while the app runs, with directory watches and scheduled listings. The app checks the
   kept items of every location while it runs, not only of the location that the pane shows.
5. **Remove Location.** A destructive button. Its confirmation says that the files on the server do
   not change and that the downloaded copies are removed from this Mac. It also asks whether to save
   the Keep Downloaded list. A saved list comes back when the user adds a location on the same share
   that contains those items. If the location has new items that never reached the
   server, the confirmation lists them: macOS keeps them on this Mac in a folder, which
   TinyMounter shows in Finder after the removal. Changes that can be on the server prevent the
   removal, and a dialog names them.

The pending-changes list includes saves held by macOS and offers Retry Pending Changes and
Show in Finder. Existing-file saves no longer have Export Local Copy or Stop Uploading controls.
Copy a pending file outside the location before resolving a missing-target error. Stop Uploading
remains available for new items whose records prove that no remote mutation is in progress. It is
also available for a new file whose upload stopped partway, while no upload of it runs. Its
confirmation then says that TinyMounter deletes the incomplete copy on the server.
All domain removal preserves dirty user data. See the [pending-change contract](pending-changes-plan.md).

The pending-changes list includes permanent deletions. Each row names the selected item and
shows waiting, a failure reason, or an unconfirmed result. Item results show the outcome for
every admitted child and folder, including confirmed deletions in a partly completed request.
Retry continues an unsettled recorded request. Stop Deleting ends further attempts after the
active node ends. Neither action can restore deleted content. Dismiss Notice is available only
after every affected location finishes settlement, and keeps the replay record. Remove Location
names pending deletions that block removal. Transient failure reasons last for the app process;
durable node outcomes remain available after restart. Normal builds enable ordinary
Finder deletion and Replace, and the confirmed **Delete Permanently…** command.

A change to Name applies immediately. A change to Source or Finder Mode shows Revert and Apply
in a bar at the bottom of the pane. Apply replaces the location's File Provider domain. A
confirmation says that this removes the downloaded copies of the location from this Mac, and that
the files on the server do not change. To try a different source and keep this location, use
Duplicate instead.

**Server** lists saved servers as `account@host`. Add Server… opens the sign-in sheet
([section 11](#11-sign-in-and-folder-browser-020)) and then continues to the share.
**Share** lists the server's saved shares and Add Share…, which lists the server's disk shares
over the saved sign-in. This is the only place to add a share. Bonjour discovery remains
unimplemented.

### 4.2 Adding a location: Duplicate

Experiments add many locations that are almost the same. So a new location starts as a copy:

1. Right-click a location in the sidebar and choose **Duplicate**, or press ⌘D for the selected
   location. The copy goes below the original, with its source and connection mode. Keep Downloaded
   items are not copied: a copy is a starting point for a new location. It is named the way Finder
   names a copy, "Documents copy", and it is selected. The Folder field has focus with its text
   selected, so the user can type the new path at once.
2. The user changes only what is different, in the same pane as any other location. The name
   follows the folder name until the user types a name.
3. **Add**, or Return, adds it. The location stays selected and Finder does not open, so the next
   Duplicate is one keystroke away. **Cancel** removes the copy.

Until Add, the copy is marked "Not added" in the sidebar and Finder does not show it. This prevents
a second File Provider domain for the same folder while the user edits the copy. The same folder,
and folders inside each other, can be locations more than once. If a restored kept item is not in
the folder, the list shows "Not on the server".

**New Location** (`+`, ⌘N) works the same way, with the first saved server and no folder. It is for
the first location on a server.

### 4.3 General, Storage, Servers and About

- **General:** Open at login, Show in menu bar, Notifications, and the Locations folder (section 7).
  When the settings file is from an earlier version and can't be read, General also shows the
  problem and Start Fresh…, which removes all locations after a confirmation.
  Notifications is a grid with the columns Event, Notification and Panel, and one switch in each
  cell. Notification posts a macOS notification; Panel adds the event to Recent Activity in the
  menu bar panel. The rows are Sign-in needed, Upload failed, Download failed, Kept a conflict
  copy, Low disk space, Connection lost or restored, and Keep Downloaded finished. The first five
  use both by default; the last two use the panel only. With both off, the event shows nowhere.
  Finished uploads and downloads always show in the panel and never post. When Show in menu bar
  is off, a note says that panel events are not visible. Notifications include the file name, or
  the server name for sign-in and connection events.
- **Storage:** disk space used per location, the total available offline, "Keep this much disk space
  free" for kept downloads, and Remove Downloads for downloads that the user does not keep.
  M16 uses a fixed 2 GiB reserve and explains temporary download space; the reserve control
  remains planned.
- **Servers:** the shares that TinyMounter has access to, grouped by server, in a grouped form.
  Each share row shows the account and share, the locations that use it, and its connection
  state. Servers adds nothing: the location form adds servers and shares (section 4.1). A share
  stays saved after its last location is removed. Forget deletes an unused share; it is
  unavailable while a location uses the share. A server without other
  shares goes with its last share, and its saved password with it. Each server also has a row
  with "Password saved", or "Sign in again." and Sign In Again… when no password is saved, and
  Forget. Forget on a server is unavailable while a location uses it. After a confirmation, it
  deletes the saved password, then forgets the server's shares.
  Connection problems also show in the location's header, with Connect or Sign In Again….
  File Provider locations have no Disconnect: the app reconnects them automatically. Server
  volumes keep Connect and Disconnect in their own pane; Sign In Again… replaces Connect when the
  server refuses the saved password.
  Native volumes reuse reconnect after launch, wake and network changes. An intentional eject
  holds reconnect for the current app session. Network selection policies remain future scope.
- **About:** version, acknowledgements, and Export Diagnostics. The export does not include file
  names, paths or passwords.

## 5. Menu bar item

The icon is a monochrome outline of the selected drive-and-network logo, without the TM.
An arrow inside the drive indicates downloads; an exclamation mark indicates a problem.
Problem status takes precedence. macOS supplies the light/dark menu-bar tint. A click opens a
panel about 340 points wide, in the native look of a window-style `MenuBarExtra`. When the panel
would exceed the screen's usable height, the sections above the actions scroll; the action rows
stay visible. From top to bottom:

- **Locations:** one row for each location and Server Volume, with a status dot, the name and
  the state in secondary text: Connected, Paused, 42% downloaded, Offline (the server does not
  answer), Not connected, Cannot sign in to home-nas, or the problem that the location pane
  shows. A click shows the location in Finder. Under the pointer the row highlights like a menu
  item and shows Show in Finder. A row with a problem shows its action instead, as
  accent-colored text: Sign In Again…, which opens Settings with the sign-in sheet, or Connect.
  A Server Volume shows Mounted or Not mounted, with Connect or Sign In Again… when it is not
  mounted. A settings problem shows above the rows, and "No locations" when there are none.
- **Transfers,** only while something transfers: each upload (a new file or a save) and each
  complete-file download, with ↑ or ↓, the name, "Documents · 3.1 of 8.4 MB" and a thin progress
  bar. Range reads for playback and Quick Look are not listed. An upload waiting for a connection
  or sharing violation (`UploadRecovery.retriesByItself`) shows "Waiting for home-nas" until its next
  attempt, Stop Uploading, or the share's reconnection, when macOS is asked to send every failed
  upload again. A create or save waiting for other changes on the share has no waiting row or
  failure event. Settings keeps its reason: "Other changes on this share must finish first."
  When the blocker settles or its reservation is released, the app asks macOS to resend failed
  uploads in every location on that share. A retry signal repeats with backoff until macOS sends
  the blocked item again, so an early signal cannot leave it waiting. The app reads the progress
  twice a second.
- **Recent Activity:** the newest events first, with the name, what happened, the location and
  the relative time. Six rows show; more scroll. Problem rows have a red symbol. Upload failed
  shows Retry, which runs Retry Pending Changes for that location: macOS releases failed uploads
  only for a whole location. A later successful upload removes that item's earlier failure rows,
  including when the history is loaded after a relaunch.
- **Actions,** as full-width rows that highlight like menu items: Pause Downloads or Resume
  Downloads; Retry Pending Changes with the number of pending changes in all locations,
  unavailable when there are none; Settings… (⌘,) and Quit TinyMounter (⌘Q). Pause stops Keep
  Downloaded downloads and read-ahead; a file that the user opens still downloads. Quit warns
  during downloads, and says that files that are not downloaded cannot open until TinyMounter
  starts again.

Like a menu, the panel closes when an action opens another window: Show in Finder, Settings… and
Sign In Again…. Pause, Retry, Retry Pending Changes and Connect keep it open, so that their result
shows in it.

The events, as Recent Activity names them:

| Event | When |
| --- | --- |
| Uploaded, Upload failed | A new file or a save finishes or fails. A failure that macOS sends again by itself is no event, and a failed upload reports once until it succeeds. Stop Uploading is no failure. The failures of one location share one notification that counts them, until 5 minutes pass without one. |
| Downloaded | A complete-file download of a file that is not kept |
| Kept downloaded | A kept file or folder is verified available offline. The first check after launch only records what is already available offline. |
| Download failed | A download that the user started fails because the share is not connected, once per share per outage |
| Saved a conflict copy | A save that asks to fail on a conflict finds the file changed on the server. TinyMounter makes no conflict copies itself; macOS resolves the conflict. |
| Low disk space | A download first stops because this Mac has not sufficient space, once per location until its stopped downloads have space again |
| Cannot sign in | A server refuses the saved password, once until a new password or a connection |
| Connection lost, Connected again | A share with locations stops answering, and later connects again, once per outage. A lost network is no event: the share connects again by itself. |

The history keeps the newest 100 events across a relaunch, in
`Application Support/tinymounter/Activity.json` in the app's container. It holds file names, so it
is not in the App Group, the logs or Export Diagnostics. Removing a location removes its events.
An unreadable file is logged and the history starts empty.

## 6. Finder

- Each File Provider location shows in Finder's sidebar below **Locations**, in the group that
  Finder Settings calls "Cloud Storage".
- Decorations show *Available offline* (kept, full and current) and *Update in progress*. Whether a
  file is downloaded is Finder's own cloud badge.
- Keep Downloaded transfers publish file progress for Finder's native circle. Files report bytes;
  kept ancestor folders use an indeterminate circle while descendant transfers run. The circle
  clears at transfer completion or failure. This does not establish offline availability.
- The context menu adds **Keep Downloaded** and **Allow Removal** as File Provider custom actions.
  Finder shows one as a separate item near the bottom of the context menu, after the item is
  republished with `userInfo.keep`; the keep state switches the label. Finder's own Keep
  Downloaded is absent; its Download Now and Remove Download stay.
- In the measured VM configurations, double-clicking an uncached file in Finder downloaded it
  fully first. On the physical Mac, playback used partial reads, but the opening routes were not
  recorded. Large full downloads show
  progress in Finder and in the menu bar item.
- A partly downloaded file can still show Download Now. Playback caches requested ranges and
  limited read-ahead; this does not promise a complete copy after the player closes.

## 7. Locations folder: one place to navigate

File Provider locations are under `~/Library/CloudStorage`, and server volumes are under
`/Volumes`. The **Locations folder**, `~/tinymounter` by default, puts them in one place.
TinyMounter keeps one Finder alias per location there, in either connection mode. The user can add
their own subfolders and aliases. The app changes only the aliases that it made, and repairs them
if the path of a location changes.

Tested in the VM: an alias to a folder on a mounted SMB share and an alias to a File
Provider location both open in place in Finder. A video opened through the SMB alias started
immediately. An alias to a server volume cannot point to something that is not on the NAS. What an
alias does when its server is offline (connect again, or fail clearly) is not tested.

## 8. UI text: ASD-STE100

All UI text follows the writing rules of ASD-STE100 Issue 9 (January 2025):

- Approved words with their approved meanings, or technical nouns and verbs for this subject (rules
  1.1–1.13). For example, "show", not "appear" or "display". "Select", not "choose". "Make sure",
  not "ensure". "Necessary", not "need". "Approximately", not "about".
- One technical name for each item (rule 1.11). Section 2 lists them.
- Noun groups of no more than three words (rule 2.1).
- Active voice and simple tenses. No "-ing" forms, except in technical names (rules 3.2–3.6). So the
  status is "42% downloaded", not "Downloading 42%".
- No contractions (rule 4.2) and no semicolons (rule 8.1).
- Instructions: imperative, one instruction in each sentence, 20 words or fewer (rules 5.1–5.3).
  Descriptions: 25 words or fewer (rule 6.3).
- Finder's own command names stay as Finder shows them: Keep Downloaded, Download Now, Remove
  Download. Standard macOS command names also stay: Show in Finder, Duplicate, Settings….

A local script checks the mockup's strings, including those that its script builds, against the
Issue 9 dictionary, sentence length, contractions and semicolons. It cannot check approved meanings
or choices of technical nouns. Those were checked by hand.

| Before | After |
| --- | --- |
| Can't reach home-nas. Check that the NAS is on and this Mac is on the same network. | TinyMounter cannot connect to home-nas. Make sure that home-nas is on. Make sure that this Mac is on the same network. |
| Sign-in needed for home-nas. | home-nas did not accept the password. Type the password again. |
| Not enough space to keep "Photos" downloaded. 12 GB more needed. | There is not sufficient disk space to keep "Photos" downloaded. Make 12 GB more space available on this Mac. |
| Downloading 42% · about 3 min left | 42% downloaded · 3 minutes remaining |
| Coming later | Not available in this version |
| Offline-ready | Available offline |

## 9. Accessibility

Use standard controls everywhere. Status never uses only color: there is always a symbol and text.
Give VoiceOver labels to status symbols, and support full keyboard navigation of the sidebar and
forms. Check Reduce Transparency and Increase Contrast.

## 10. Open decisions

- **Locations folder.** On or off by default, and its name and place. Alternatives to "Locations
  folder": "TinyMounter folder", or "Aliases folder".
- **A settings file for experiments.** Export and import of locations as a text file, to add many
  test locations with a script.
- Limits for kept folders: a size limit per item, or only the free-space setting.


## Write mode

Each File Provider location has one Read only toggle in its Access section. It is off for a new
location; a duplicate takes the original's setting. All supported writes use this one mode:
new files and folders, saves, rename, move and deletion. Do not add another feature switch.
Turning Read only off asks for nothing: there is no share permission or grant, and the
account's permissions on the server apply. The setup has no SMB-only warning or technical
details. Concurrent edits are a synchronization concern; setup must not ask users to certify how
every other app accesses the NAS. The Access section's footer says what writes do, including that
deletion and Finder Replace cannot be undone.

Turning Read only on blocks new remote changes, and is refused while changes are pending. Other
devices can see a new file before its upload finishes. New items that never reached the server
do not prevent removal, because macOS keeps them
([pending-change contract](pending-changes-plan.md)).

## 11. Sign-in and folder browser (0.2.0)

Built in 0.2.0.

**Add Server…** in a location's Server menu opens a sheet: "Type the server address, your name
and your password.", with Server (placeholder `smb://server`), Name, Password, Cancel and
Sign In. A name in the address (`smb://name@server`) counts when Name is empty. The footer says
"TinyMounter keeps the password in your keychain."

Sign In asks the server to check the name and password before it saves anything:

- A refusal shows "The server did not accept this name and password. If the password has
  expired, change it on the server first." in the sheet. The sheet stays open with an empty
  Password field, and nothing is saved. An expired password, or one the server says must
  change, counts as a refusal. A locked or disabled account does not.
- A wrong address shows "This address is not correct. Type an address such as
  smb://server/share."; no name shows "Type the name of your account on the server."
- Success saves the server and the password and closes the sheet. A server that is already saved
  for the same account keeps its record and gets the new password. If the address names a share,
  the location selects it.

**Sign In Again…** opens the same sheet with Server and Name fixed: "Type your password for
home-nas again." It shows on the server's row in Servers when no password is saved, and in a
location's header with the status "Sign in again." when the server refuses the saved password.

A server volume signs in with the same saved password. When the server
refuses it, the volume shows "Not mounted" with Sign In Again… in place of Connect, and every
location of that server shows Sign in again. Connect or Show in Finder then shows "home-nas did
not accept the saved password. If the password has expired, change it on the server. Then click
Sign In Again… and type the password." with Sign In Again…
and Cancel. A refused automatic reconnect posts the server's sign-in notification. Other mount
failures show:

- "The share “Media” is not on home-nas." when the server has no such share.
- "home-nas does not give this account access to the share “Media”." when the account can't
  open it.
- The connection message, "TinyMounter cannot connect to home-nas. Make sure that home-nas is
  on. Make sure that this Mac is on the same network.", when the server doesn't answer.
- "TinyMounter cannot connect to the share “Media” (error N)." for other NetFS statuses.

The password is a generic-password item in the login keychain: service `dev.tinymounter.smb`,
account `name@host` with the host in lowercase. Finder's own internet-password item for the
same server never matches it, so Forget never deletes Finder's item. Settings.json holds only
the server, `{"id", "login": {"remoteProtocol", "host", "account"}}`. A Settings.json from 0.1.2
has no `login` and is refused; General then offers Start Fresh.

**Select…** next to Folder in a File Provider location opens a folder browser in the app, not
a macOS panel: "Select a folder in Media.", an Enclosing Folder button, the path from the share
name, and the folders of one folder at a time, in Finder's order. As in Finder, folders whose
names start with "." don't show; the Folder field still takes them. Double-click opens a folder.
Choose sets Folder to the selected folder, or to the folder that the list shows when none is
selected; Cancel changes nothing. An empty folder shows "No folders"; a failed listing shows
"TinyMounter cannot show the folders. Make sure that the share is connected."
