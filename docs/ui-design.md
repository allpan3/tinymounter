# User interface design

Date: 2026-10-11, revised three times the same day after the user's review. Decision status:
accepted for prototyping on 2026-10-11. The user evaluates it again on the prototype. Section 10
lists the decisions that are still open. On 2026-10-12 the user decided Duplicate, overlapping
locations, saved Keep Downloaded lists and Pause Downloads (sections 4 and 5). Phase 2 builds the
subset in [phase2-plan.md](phase2-plan.md#1-decisions); M7 built the Settings window, the menu
bar item and notifications, with the changes that [phase 2 §8](phase2-plan.md#8-ui) records.
Interactive mockup: [ui-mockup.html](ui-mockup.html).

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
| A share that the macOS SMB client mounts | Finder: Go › "Connect to Server…", "server volume", the sidebar group "Connected servers", "Eject". The Mac User Guide: "volumes or shared folders on the server". | **Server volume** | "Native SMB" |
| The choice between the two, per location | none | **Connection Mode** | "Appears as", "View" |
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
| Menu bar item | Status, transfers and quick actions. It keeps the reader running, which reads of data that isn't downloaded need. |
| Settings window | Locations, servers, offline storage, general settings, diagnostics |
| Finder | Locations in the sidebar, status decorations, Keep Downloaded and Allow Removal |
| Notifications | Sign-in problems, no connection during a download, low disk space for kept files |

## 4. Settings window

A standard settings window, about 780 × 540 points, resizable. The sidebar has a search field and
two groups:

- **Locations:** each location, with a status symbol: connected, offline, or a problem.
  Right-click (Control-click) a location for its shortcut menu: Show in Finder, Duplicate and
  Remove Location…. The `+` button at the bottom adds an empty location (section 4.2). The `−`
  button removes the selected location.
- **Settings:** General, Storage, Servers and About.

### 4.1 Location pane: all settings in one place

Selecting a location shows one grouped form with all of its settings:

1. **Header.** Icon, name, and a status line such as "Connected · 18.4 GB downloaded · 3 items
   available offline", and a Show in Finder button.
2. **Source.** Server, Share, Folder and Name. The user types a folder path, with completion, or
   clicks Select… to browse. An empty path means the full share.
3. **Connection Mode.** File Provider, or Server volume. Server volume shows "Not available in this
   version" until that phase.
4. **Keep Downloaded** (File Provider only). Each kept file or folder, with its state: Available
   offline, 42% downloaded, Update in progress, or Not sufficient space. Add with `+`, remove with
   `−`. Keeping a folder keeps all items in it, recursively.
5. **Remove Location.** A destructive button. Its confirmation says that the files on the server do
   not change and that the downloaded copies are removed from this Mac. It also asks whether to save
   the Keep Downloaded list. A saved list comes back when the user adds a location on the same share
   that contains those items.

A change to Name applies immediately. A change to Source or Connection Mode shows Revert and Apply
in a bar at the bottom of the pane. Apply replaces the location's File Provider domain. A
confirmation says that this removes the downloaded copies of the location from this Mac, and that
the files on the server do not change. To try a different source and keep this location, use
Duplicate instead.

**Server** lists saved servers and Bonjour servers. Each server keeps its account and Keychain
password once, in the Servers pane. "Add Server…" opens a small sheet: address, account and
password.

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
- **Storage:** disk space used per location, the total available offline, "Keep this much disk space
  free" for kept downloads, and Remove Downloads for downloads that the user does not keep.
- **Servers:** one row per server: address, account, Keychain password, connection state, SMB
  dialect and signing. Edit… changes the account or password for all locations on that server.
  Later, for server volumes: connect again after sleep and network changes, and which networks to
  use.
- **About:** version, acknowledgements, and Export Diagnostics. The export does not include file
  names, paths or passwords.

## 5. Menu bar item

The icon is a drive symbol. It shows a small badge during transfers and a warning badge when there
is a problem. The menu shows:

- one line per location, with its state, and a progress bar for active transfers;
- Open Locations Folder (⌘O) and Pause Downloads. Pause stops Keep Downloaded downloads and
  read-ahead; a file that the user opens still downloads;
- Settings… and Quit tinymounter. Quit warns during downloads, and says that files that are not
  downloaded cannot open until tinymounter starts again.

## 6. Finder

- Each File Provider location shows in Finder's sidebar below **Locations**, in the group that
  Finder Settings calls "Cloud Storage".
- Decorations show *Available offline* (kept, full and current) and *Update in progress*. Whether a
  file is downloaded is Finder's own cloud badge.
- The context menu adds **Keep Downloaded** and **Allow Removal** as File Provider custom actions.
  In the macOS 27.0.1 VM on 2026-10-12, Finder showed one as a separate item near the bottom of the
  context menu, after the fixture item was republished with `userInfo.keep`. The harness's keep
  state switched the label. Finder's own Keep Downloaded was absent; its Download Now and Remove
  Download stay. An Allow Removal click reached the extension, which only logs in the M3 spike.
  Action effects and decorations remain unverified. See the
  [M3 results](results/2026-10-12-share-grant.md).
- Double-clicking a file in Finder downloads the full file first if it is not downloaded (measured).
  Large files show progress in Finder and in the menu bar item.

## 7. Locations folder: one place to navigate

File Provider locations are under `~/Library/CloudStorage`, and server volumes are under
`/Volumes`. The **Locations folder**, `~/tinymounter` by default, puts them in one place.
tinymounter keeps one Finder alias per location there, in either connection mode. The user can add
their own subfolders and aliases. The app changes only the aliases that it made, and repairs them
if the path of a location changes.

Tested on 2026-10-11 in the VM: an alias to a folder on a mounted SMB share and an alias to a File
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
| Can't reach home-nas. Check that the NAS is on and this Mac is on the same network. | tinymounter cannot connect to home-nas. Make sure that home-nas is on. Make sure that this Mac is on the same network. |
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
  folder": "tinymounter folder", or "Aliases folder".
- **A settings file for experiments.** Export and import of locations as a text file, to add many
  test locations with a script.
- Whether Settings opens at first launch, or only the menu bar item.
- Limits for kept folders: a size limit per item, or only the free-space setting.
- Whether Storage shows each file, or only totals per location.
