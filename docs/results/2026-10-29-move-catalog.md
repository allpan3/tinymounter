# Catalog preparation for file moves

Date: 2026-10-29. Within the accepted M21 scope.

The catalog can now record a caller-proven file move while keeping the item's ID, content
version, enumeration key and explicit Keep Downloaded request. Core checks pass in macOS VM 1.
This core-only run predates app integration. The later
[organization checks](2026-10-29-file-organization-protocol.md) cover protected admission and
signed Finder moves. Neither result alone completes M21.

## Behavior and compatibility

A move updates the parent, name and native lookup metadata in one catalog transaction. Retention
inherited from a folder follows the destination folder. Stale sources, collisions and invalid
destinations refuse the commit without changing rows. A repeated commit is idempotent while the
item remains at that destination; the caller must never replay a completed intent after a later
move back.

The old parent's change enumeration now includes the moved item with its new parent. The new
parent and working set receive the same item ID. A move produces no global deletion. Folder
page cursors remain valid when their last item moves away. The later signed overlapping-view
check confirms departure from the old Finder folder while preserving both views' downloads.

Catalog version 7 adds departure history. Versions 1 through 6 migrate without changing rows,
epochs or anchors. Older readers refuse version 7 because they cannot deliver departures.
Settings are unchanged. Native lookup IDs remain distinct from server object identity; this
change neither establishes that identity nor weakens reconciliation checks. Legacy content
versions remain legacy and cannot become verified editing bases through a move.

## Verification

Setup: macOS VM 1, its development clone, synthetic local catalog fixtures. Cache state was
uncontrolled. These are correctness checks, with no performance claim or original-NAS writes.

The focused catalog, move and folder-keep suites passed 77 tests. Tools/run-checks.sh then passed
294 tests with one optional native-fixture skip and no failures, plus project generation,
release CLI/benchmark validation and the unsigned app build. No Swift warnings appeared.
Existing vendor C and SDK metadata warnings remain. No signed runtime build or before/after
recording was needed for this uncalled catalog API; those remain required for M21 integration.

Coverage includes migration, old/new-parent changes, pagination, repeated moves, later deletion,
stale inputs, collisions, inherited and explicit keeps, and preservation of verified and legacy
versions. Logs are in VM .local/phase4/m21-20261029/catalog-tests.log and catalog-run-checks.log.
An earlier accidental host library build was removed and is not verification evidence.

The separate disposable protocol session is still in progress. This catalog result makes no
claim that its fixture has been cleaned up. Installation and publication remain deferred.
