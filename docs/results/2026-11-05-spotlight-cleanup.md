# Spotlight app cleanup

Date: 2026-11-05. On the physical Mac, macOS 27.0.1 (26A434), removed 156 leftover
TinyMounter app bundles: eight installation backups and 148 build, signing and test copies.
Targeted LaunchServices unregistration also removed entries for already-deleted copies.
The final registry contains only the installed app in Applications and its embedded provider;
PlugInKit likewise lists only that provider. The Spotlight UI was not rechecked visually.

Installers retained rollback copies as runnable app bundles, and signing jobs left their
packaged input bundles in development folders. Several test variants used separate bundle
identifiers with the same display name. Unregistering a bundle without removing it left it
available for macOS to discover again.

The cleanup inspected bundle identifiers and running processes before deletion. The installed
app's executable, provider executable and Info.plist retained their inode, size and modification
time; strict/deep signature verification passes and the same app process remains running.
Settings, pending uploads, catalogs, test logs and packaged evidence were not removed.
A concurrent VM signing job removed its new host app copy after transfer and updated its script
to package, unregister and remove future copies. No extra app bundles remain under `.build/`,
`results/` or `.local/` at the final check.

The installation guidance now requires removal of temporary signing/transfer bundles and,
after installation verification, the temporary rollback copy. App backups are not retained.
No production code changed in this cleanup. The concurrent development task will include these
documentation changes in its next required VM check pass; no host app build ran here.

Private inventory and verification evidence: `results/spotlight-cleanup-20261105.json`.
