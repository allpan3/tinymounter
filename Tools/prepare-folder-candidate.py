#!/usr/bin/env python3
"""Prepare an isolated macOS VM candidate for the single-client M22 checks.

Run in macOS VM 1 with a new output directory. The existing Writable location
supplies the approved test-share grant. Launch with --m22-finder setup RUN (or
resume RUN); select a local evidence directory in the app's folder picker.
Write request-RANDOM_UUID.json there using the existing Request structure.
The app exports only this fixture's snapshots and callback events there.
The checkout and ordinary feature gates are unchanged. --enable permits folder
organization in the candidate; omit it for the matching disabled baseline.
--crash-checks adds run/item-bound stop points controlled by fault.json in the
granted evidence directory. A hit exports its durable intent, then SIGSTOPs the
app. Kill that exact process to test recovery; each control ID fires only once.
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
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    if Path.home() != Path("/Users/user") or not Path("/Volumes/tinymounter-single").is_mount():
        raise RuntimeError("run only in the mounted macOS VM fixture")
    subprocess.run(["git", "clone", "--shared", str(source), str(args.output)], check=True)
    root = args.output.resolve()
    helper = (root / "Tools/check-folder-move-finder.swift").read_text()
    helper = helper.replace('"tinymounter-m19-edit-test"', '"tinymounter-single"')
    helper = helper.replace('"127.0.0.1"', f'"{fixture_host()}"')
    helper = helper.replace('"_tinymounter_m19"', '"tmtest"')
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
                     '"recovery-changed"]')
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
    app = root / "Prototype/App/LocationController.swift"
    content = replace(app.read_text(), '        isReady = true\n',
                      '        isReady = true\n        Task {\n'
                      '            try? await Task.sleep(for: .seconds(3))\n'
                      '            await self.runM22FinderFixture()\n        }\n')
    app.write_text(content + "\n" + helper)
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
            '                    try M22FinderCrash.checkpoint(current, stage: "finished-domain")')
        content = replace(content,
            '                try source.withCatalog { try $0.settleFolderMove(view.move, settlement: settlement.settlement) }\n'
            '            }\n        }',
            '                try source.withCatalog { try $0.settleFolderMove(view.move, settlement: settlement.settlement) }\n'
            '            }\n            try M22FinderCrash.checkpoint(record, stage: "catalog")\n        }')
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
    provider.write_text(content + "\n" + helper.split("#if !M22_FINDER_PROVIDER")[0])
    if args.enable:
        gates = root / "Prototype/Shared/SourceReaderProtocol.swift"
        gates.write_text(replace(gates.read_text(), "static let folderOrganizationEnabled = false",
                                "static let folderOrganizationEnabled = true"))
    subprocess.run(["git", "diff", "--stat"], cwd=root, check=True)


if __name__ == "__main__":
    main()
