# One add flow and a simpler Servers pane

Date: 2026-11-07. Decision status: accepted by the user and implemented. Signed VM checks passed.
The physical Mac remains on 0.1.1.

## Behavior

Shares are added only through a location. In a new location, Add Server… saves the address and
continues to macOS's share chooser and the share-access panel, which opens on the mounted share.
Add Share… in the Share menu adds another share on a saved server. Select… connects the share
first if necessary.

Servers lists the saved shares by server, with their connection state and the locations that
use them. It adds nothing. Forget ejects an unused share and deletes its access; a server
without other shares goes with its last share. Forget is unavailable while a location uses the
share. Select Again… shows only when the access no longer resolves.

Share access stays saved after the last location on a share is removed, so adding the share
again needs no panel. A location that is not connected shows Connect, and one whose access no
longer resolves shows Select Again…, in its own header. File Provider locations have no
Disconnect, because the app reconnects them. Server volumes keep Connect and Disconnect.
Other Connected Shares is gone; Add Share… still offers existing connections.

## Verification

Setup: macOS VM 1, macOS 27.0.1, signed sandboxed app with the isolated test identity, and the
disposable Samba VM. The location was added and removed without file changes by the test.

- With access retained from an earlier run, Servers showed the share as Not used, with Forget.
  Add created a File Provider location without a panel and connected it. The support mount had
  `nobrowse`. Servers then showed the location's name and disabled Forget.
- After Remove Location, the share stayed saved and still mounted, as Not used. Forget ejected
  it in about 11 s, then removed the share and its server. The buttons were disabled with no
  feedback during that wait, so a progress indicator was added; it was not checked at runtime.
- From an empty setup, Add Server… went straight to the macOS share chooser and then the
  access panel on the share. One Open filled Server, Share and Name.
- About 3 s after Add, Finder replaced the share root's `.DS_Store` through the location
  (one delete, then a new file). This is ordinary Finder behavior on a writable location.
- `Tools/run-checks.sh` passed: 523 tests, one optional fixture skip, zero failures and no Swift
  warnings. A new test covers forgetting used and unused shares and the empty server.

Follow-up the same day, signed test identity, read-only location:

- After the share was ejected, Select… in a draft connected it again, hidden, and opened the
  folder panel on the share.
- After an eject of the location's share, its header showed Connect. Connect mounted it again
  with `nobrowse` and the state returned to Connected. The status line then told the user to
  open the location in Settings, so it now says "Not connected. Click Connect."
- Forget took under a second, too quickly to see the progress indicator.
- UI text shows "TinyMounter", and the mode labels are File Provider and Server Volume.

On the physical Mac, the user installed the first test build. Finder hid the support mount,
but QSpace Pro listed it as a volume; see the [0.2.0 plan](../roadmap.md).

Not verified: Select Again…, which needs access that no longer resolves, and the progress
indicator during a slow eject.

## Recordings

Matched recordings start from empty settings with the same signed test identity, window and
Samba share: add the server and share, add a full-share location, then open Servers. Before,
built from the commit preceding this redesign, needs Servers, + and Add Share… first, then the
location. After starts in the location. The server address is covered in both.
[Before](../media/servers-redesign/before.gif) · [After](../media/servers-redesign/after.gif).
The location and share were removed afterwards and the test app was uninstalled.

Local evidence: `results/servers-redesign-20261107/`.
