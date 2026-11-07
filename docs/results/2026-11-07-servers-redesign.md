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

Not verified: the Finder sidebar on a clean Mac (the VM sidebar holds many retained test
domains), Select… connecting a disconnected share, and the Select Again… and Connect header
actions, which need a broken or ejected share.

Local evidence: `results/servers-redesign-20261107/`.
