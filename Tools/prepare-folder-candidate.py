#!/usr/bin/env python3
"""Prepare an isolated macOS VM candidate for the single-client M22 checks.

Run in macOS VM 1 with a new output directory. The existing Writable location
supplies the approved test-share grant. Launch with --m22-finder setup RUN (or
resume RUN); select a local evidence directory in the app's folder picker.
Write request-RANDOM_UUID.json there using the existing Request structure.
The app exports only this fixture's snapshots and callback events there.
Fresh snapshot labels may start with check- and contain up to 64 lowercase ASCII
letters, digits or hyphens. Each label creates evidence only once.
The checkout and ordinary feature gates are unchanged. --enable permits folder
organization in the candidate; omit it for the matching disabled baseline.
--crash-checks adds run/item-bound stop points controlled by fault.json in the
granted evidence directory. A hit exports its durable intent, then SIGSTOPs the
app. Kill that exact process to test recovery; each control ID fires only once.
--overlap-checks accepts an overlap-setup request to add one registered view of
the same fixture. Later requests export both views, with -peer on the second
snapshot. Catalog and finished-domain stops include both catalogs' current rows.
--deletion-checks records deletion callbacks and durable operations in these views.
--enable-deletion additionally enables deletion only in the generated candidate.
"""
import argparse
from pathlib import Path
import subprocess


def replace(text, old, new, count=1):
    if text.count(old) != count:
        raise RuntimeError(f"candidate source changed: {old[:80]!r}")
    return text.replace(old, new)


def fixture_host():
    """Return the SMB server of the mounted fixture, as macOS reports it."""
    mounts = subprocess.run(["mount"], capture_output=True, text=True, check=True).stdout
    for line in mounts.splitlines():
        source, separator, rest = line.partition(" on /Volumes/tinymounter-single (")
        if separator and source.startswith("//"):
            return source[2:].split("/", 1)[0].rsplit("@", 1)[-1]
    raise RuntimeError("the fixture share is not mounted")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--enable", action="store_true")
    parser.add_argument("--crash-checks", action="store_true")
    parser.add_argument("--overlap-checks", action="store_true")
    parser.add_argument("--deletion-checks", action="store_true")
    parser.add_argument("--enable-deletion", action="store_true")
    args = parser.parse_args()
    if args.enable_deletion and not args.deletion_checks:
        parser.error("--enable-deletion requires --deletion-checks")
    source = Path(__file__).resolve().parent.parent
    if Path.home() != Path("/Users/user") or not Path("/Volumes/tinymounter-single").is_mount():
        raise RuntimeError("run only in the mounted macOS VM fixture")
    subprocess.run(["git", "clone", "--shared", str(source), str(args.output)], check=True)
    root = args.output.resolve()
    helper = (root / "Tools/check-folder-move-finder.swift").read_text()
    helper = helper.replace('"tinymounter-m19-edit-test"', '"tinymounter-single"')
    helper = helper.replace('"127.0.0.1"', f'"{fixture_host()}"')
    helper = helper.replace('"_tinymounter_m19"', '"tmtest"')
    helper = replace(helper, 'M22FinderProbe.labels.contains(request.label)',
        '(M22FinderProbe.labels.contains(request.label) || (request.label.hasPrefix("check-")\n'
        '                        && request.label.utf8.count <= 64 && request.label.utf8.allSatisfy {\n'
        '                            (97...122).contains($0) || (48...57).contains($0) || $0 == 45\n'
        '                        }))')
    helper = replace(helper, "import Darwin", "import CryptoKit\nimport Darwin")
    helper = replace(helper, '        guard value else { throw Failure.check(label) }',
                     '''        guard value else {
            logger.error("m22_fixture_check_failed check=\\(label, privacy: .public)")
            throw Failure.check(label)
        }''')
    helper = replace(helper, '$0.id == UUID(uuidString: "3A9DE695-8327-4D86-B393-2520E71A75D8")',
                     '$0.name == "Writable" && $0.folder == "Writable"')
    helper = replace(helper, 'reference.name == "M21 Files", reference.folder == "probe-m21-finder",',
                     'reference.name == "Writable", reference.folder == "Writable",')
    helper = replace(helper, '"collision-file", "relisted", "named", "replay"]',
                     '"collision-file", "relisted", "named", "replay", "recovery-baseline", '
                     '"recovery-attempting", "recovery-moved", "recovery-verified", "recovery-catalog", '
                     '"recovery-settings", "recovery-finished-domain", "recovery-before-reply", '
                     '"recovery-changed", "recovery-settings-retry", "recovery-catalog-retry", '
                     '"save-ready", "save-visible", "recovery-same-identity", "recovery-stale-save", '
                     '"recovery-replay-fixed", '
                     '"recovery-signal-restored"]')
    start = helper.index("                let root = try session.locationRoot(RelativePath(folder)!)")
    end = helper.index('\n            }\n        }\n        let channel', start)
    helper = helper[:start] + '''                let remote = try SMBEdit(endpoint: endpoint, folder: .root,
                    root: session.root, progress: Progress())
                let path = folder + "/marker.txt"
                let expected = Data(("tinymounter-m22-finder:" + run.uuidString + "\\n").utf8)
                let metadata = try remote.readMetadata(path: path)
                try M22FinderProbe.require(metadata.fingerprint.size == expected.count,
                    "ordinary-fixture-marker")
                let digest = SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
                let range = try ByteRange(offset: 0, length: metadata.fingerprint.size,
                    fileSize: metadata.fingerprint.size)
                try M22FinderProbe.require(try remote.readRangeDigest(path: path, range: range) == digest,
                    "fixture-marker")''' + helper[end:]
    helper = replace(helper, 'let channel = try M22FinderProbe.directory(run)\n            while', '''let channel = try M22FinderProbe.directory(run)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.message = "Choose the local folder for this VM test's evidence."
            guard await panel.begin() == .OK, let export = panel.url else { return }
            let scoped = export.startAccessingSecurityScopedResource()
            defer { if scoped { export.stopAccessingSecurityScopedResource() } }
            try M22FinderProbe.require(try export.resourceValues(forKeys: [.volumeIsLocalKey])
                .volumeIsLocal == true, "local-evidence-directory")
            while''')
    helper = replace(helper, 'contentsOfDirectory(at: channel, includingPropertiesForKeys: nil)',
                     'contentsOfDirectory(at: export, includingPropertiesForKeys: nil)')
    helper = replace(helper, '                try await Task.sleep(for: .seconds(1))', '''                let reports = try FileManager.default.contentsOfDirectory(at: channel,
                    includingPropertiesForKeys: nil)
                let events = export.appending(path: "events")
                try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
                for file in reports where file.pathExtension == "json" {
                    let target = export.appending(path: file.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.copyItem(at: file, to: target)
                    }
                }
                for file in try FileManager.default.contentsOfDirectory(at: channel.appending(path: "events"),
                    includingPropertiesForKeys: nil) {
                    let target = events.appending(path: file.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.copyItem(at: file, to: target)
                    }
                }
                try await Task.sleep(for: .seconds(1))''')
    if args.crash_checks:
        helper = replace(helper, '            while !Task.isCancelled {',
                         '            M22FinderCrash.setExport(export)\n'
                         '            defer { M22FinderCrash.setExport(nil) }\n'
                         '            while !Task.isCancelled {')
    overlap = ""
    if args.overlap_checks:
        overlap = (root / "Tools/check-folder-move-overlap.swift").read_text()
        helper = replace(helper, '"recovery-signal-restored"]',
                         '"recovery-signal-restored", "overlap-setup", "overlap-baseline", '
                         '"overlap-catalog", "overlap-finished", "overlap-retired", '
                         '"overlap-rediscovered", "overlap-relisted"]')
        helper = replace(helper, 'return config.domain == domain ? config : nil',
                         'return try configs(config).first { $0.domain == domain }')
        helper = replace(helper,
            '        for record in settings.locations where grants.contains(record.grantID) && record.id != allowed {',
            '        let taskIDs = try M22FinderProbe.taskLocations(folder: folder)\n'
            '        for record in settings.locations where grants.contains(record.grantID)\n'
            '            && record.id != allowed && !taskIDs.contains(record.id) {')
        helper = replace(helper, '        withoutTask.locations.removeAll { $0.id == config.location }',
            '        let taskIDs = try M22FinderProbe.taskLocations(folder: config.folder)\n'
            '        withoutTask.locations.removeAll { taskIDs.contains($0.id) }')
        helper = replace(helper, '                        try await m22FinderSnapshot(config, label: request.label)',
            '                        if request.label == "overlap-setup" { try await m22FinderAddPeer(config) }\n'
            '                        for (index, view) in try M22FinderProbe.configs(config).enumerated() {\n'
            '                            try await m22FinderSnapshot(view,\n'
            '                                label: request.label + (index == 0 ? "" : "-peer"))\n'
            '                        }')
    if args.deletion_checks:
        helper = replace(helper, '    struct Snapshot: Codable {', '''    struct Deletion: Codable {
        let plan: DeletionPlan
        let progress: DeletionProgress
        let complete: Bool
        let pending: Bool
        let canDismiss: Bool
    }

    struct Snapshot: Codable {''')
        helper = replace(helper, '        let pendingEdits: Int\n',
                         '        let pendingEdits: Int\n        let deletions: [Deletion]\n')
        helper = replace(helper, '        let snapshot = M22FinderProbe.Snapshot(config: config, label: label,',
            '''        let deletions = try await Self.offMain {
            try LocationSource.deletionOutbox().records().filter { operation in
                operation.plan.views.contains { $0.domain == config.domain }
            }.map { operation in
                M22FinderProbe.Deletion(plan: operation.plan, progress: operation.progress,
                    complete: operation.isComplete, pending: operation.isPending,
                    canDismiss: operation.canDismiss)
            }
        }
        let snapshot = M22FinderProbe.Snapshot(config: config, label: label,''')
        helper = replace(helper, '            editBases: bases, pendingEdits: pendingEdits)',
                         '            editBases: bases, pendingEdits: pendingEdits, deletions: deletions)')
    app = root / "Prototype/App/LocationController.swift"
    content = replace(app.read_text(), '        isReady = true\n',
                      '        isReady = true\n        Task {\n'
                      '            try? await Task.sleep(for: .seconds(3))\n'
                      '            await self.runM22FinderFixture()\n        }\n')
    app.write_text(content + "\n" + helper + "\n" + overlap)
    if args.crash_checks:
        app.write_text(app.read_text() + "\n" + (root / "Tools/check-folder-move-crash.swift").read_text())
        moves = root / "Prototype/App/LocationFolderMoves.swift"
        content = replace(moves.read_text(),
            'do { try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote) }',
            '''let admitted = record
        do {
            try FolderMoveTransaction.publish(&record, outbox: outbox, remote: remote) { state in
                try M22FinderCrash.checkpoint(admitted, stage: state.rawValue)
            }
        }''')
        content = replace(content, '            try waitForFolderMoveSettings(current)',
            '            try waitForFolderMoveSettings(current)\n'
            '            try M22FinderCrash.checkpoint(current, stage: "settings")')
        content = replace(content,
            '                    try FolderMoveTransaction.finishDomain(view.domain, record: &current, outbox: outbox)',
            '                    try FolderMoveTransaction.finishDomain(view.domain, record: &current, outbox: outbox)\n'
            '                    try M22FinderCrash.checkpoint(current, stage: "finished-domain",\n'
            '                        sources: participants.map { $0.1 })')
        content = replace(content,
            '                try source.withCatalog { try $0.settleFolderMove(view.move, settlement: settlement.settlement) }\n'
            '            }\n        }',
            '                try source.withCatalog { try $0.settleFolderMove(view.move, settlement: settlement.settlement) }\n'
            '            }\n            try M22FinderCrash.checkpoint(record, stage: "catalog",\n'
            '                sources: participants.map { $0.1 })\n        }')
        content = replace(content, '        try record.requireMoved()\n        return CreateReceipt(item: request.item)',
            '        try record.requireMoved()\n'
            '        try M22FinderCrash.checkpoint(record, stage: "before-reply")\n'
            '        return CreateReceipt(item: request.item)')
        moves.write_text(content)
    provider = root / "Prototype/Provider/FileProviderExtension.swift"
    content = provider.read_text()
    content = replace(content, 'try CatalogEnumerator.make(for: containerItemIdentifier, catalog: catalog, reader: sourceReader, domain: domain)',
        'try M22FinderProbe.enumerator(CatalogEnumerator.make(for: containerItemIdentifier, catalog: catalog, reader: sourceReader, domain: domain), domain: domain.identifier.rawValue, parent: containerItemIdentifier)')
    signature = 'completion: @escaping (URL?, NSFileProviderItem?, NSRange, Error?) -> Void) -> Progress {\n'
    content = replace(content, signature, signature + '''        let completion = M22FinderProbe.fetch(domain: domain.identifier.rawValue,
            item: identifier.rawValue, version: version, range: requested, reply: completion)
''')
    for method, item, base, fields, contents in [
        ("createItem", "itemTemplate", "nil", "fields", "url"),
        ("modifyItem", "item", "version", "changedFields", "newContents"),
    ]:
        start = content.index("    func " + method + "(")
        position = content.index(" -> Progress {\n", start) + len(" -> Progress {\n")
        hook = f'''        let completionHandler = M22FinderProbe.mutation(
            domain: domain.identifier.rawValue, kind: "{method.removesuffix('Item')}", item: {item},
            base: {base}, fields: {fields}, contents: {contents} != nil,
            options: UInt(options.rawValue), reply: completionHandler)
'''
        content = content[:position] + hook + content[position:]
    if args.deletion_checks:
        start = content.index("    func deleteItem(")
        position = content.index(" -> Progress {\n", start) + len(" -> Progress {\n")
        content = content[:position] + '''        let completionHandler = M22FinderProbe.deletion(
            domain: domain.identifier.rawValue, item: identifier, base: version,
            options: options, reply: completionHandler)
''' + content[position:]
        content += '''
extension M22FinderProbe {
    static func deletion(domain: String, item: NSFileProviderItemIdentifier,
                         base: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions,
                         reply: @escaping (Error?) -> Void) -> (Error?) -> Void {
        guard let config = selected(domain) else { return reply }
        let call = UUID()
        emit(config, call: call, kind: "delete-begin", fields: ["item": item.rawValue,
            "baseContent": base.contentVersion.base64EncodedString(),
            "baseMetadata": base.metadataVersion.base64EncodedString(),
            "recursive": String(options.contains(.recursive)), "options": String(options.rawValue)])
        return { error in
            let restored = (error as NSError?)?.userInfo[NSFileProviderErrorItemKey] as? NSFileProviderItem
            emit(config, call: call, kind: "delete-end", fields: failure(error),
                 items: restored.map { [self.item($0)] } ?? [])
            reply(error)
        }
    }
}
'''
    provider.write_text(content + "\n" + helper.split("#if !M22_FINDER_PROVIDER")[0]
                        + "\n" + overlap.split("#if !M22_FINDER_PROVIDER")[0])
    if args.enable:
        gates = root / "Prototype/Shared/SourceReaderProtocol.swift"
        gates.write_text(replace(gates.read_text(), "static let folderOrganizationEnabled = false",
                                "static let folderOrganizationEnabled = true"))
    if args.enable_deletion:
        gates = root / "Prototype/Shared/SourceReaderProtocol.swift"
        gates.write_text(replace(gates.read_text(), "static let deletionEnabled = false",
                                "static let deletionEnabled = true"))
    subprocess.run(["git", "diff", "--stat"], cwd=root, check=True)


if __name__ == "__main__":
    main()
