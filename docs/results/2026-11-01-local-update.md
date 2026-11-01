# Physical-Mac update

Date: 2026-11-01. The user requested installation of the latest version before development
continued. The normal Release build is installed in Applications, and both app and provider
run from that bundle. Folder organization and deletion remain disabled.

The candidate was built in VM 1 from the source of the October 31 performance checkpoint.
Production code is unchanged from its passing required checks: 569 tests, one optional skip,
no failures, and 7,205 encryption cases. The installation build produced no Swift warnings.
The app, provider and SMB library passed strict/deep signature verification. The installed
bundle identifiers, App Group and entitlements, including the sandbox, are unchanged.

The installer collected startup diagnostics, quit normally, backed up the old bundle, replaced
it and launched the new app in the background. Before and after, launch reconciliation reports
one location, catalog and domain, with no unknown domains or failed sequences.
Diagnostics report two tombstones, 3,395 listed folders, zero keep requests and
zero staging files in both launches. Live items increased from 12,928 to 12,932 between the
snapshots; these are live discovery counts, not a frozen inventory comparison. The new app
reports one connected share session.

macOS denied direct Settings and catalog access. These checks establish retained registration
counts, not equality of every item ID or downloaded byte. The installer
changed no locations, grants, write-mode settings, mounts or caches. Only the app and its own
provider were stopped. No NAS mutation, physical-Mac performance test, publication or push ran.

Private build and installation evidence is in `results/latest-install-20261101/` on the Mac
and `.local/phase4/latest-install-20261101/` in VM 1. The previous bundle is retained as evidence;
its older catalog support means it must not be relaunched against the migrated state.
