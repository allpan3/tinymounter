import Darwin
import Foundation

public struct InitialFolderName: Codable, Sendable {
    public enum State: String, Codable, Sendable { case prepared, attempting, verified, completed, observed }
    public let source: String
    public let destination: String
    public let name: String
    public var state: State

    public var isPending: Bool { state != .completed && state != .observed }

    func isValid(for record: PendingUpload) -> Bool {
        guard record.kind == .folder, record.state == .completed, record.remoteID != nil, record.item != nil,
              let old = RelativePath(source), let new = RelativePath(destination),
              !old.isRoot, !new.isRoot, RelativePath.isValidComponent(name),
              new.components.last?.utf8.elementsEqual(name.utf8) == true,
              old.components.dropLast().elementsEqual(new.components.dropLast()),
              !source.utf8.elementsEqual(destination.utf8) else { return false }
        let currentPath = isPending ? source : destination
        return record.path.utf8.elementsEqual(currentPath.utf8)
    }
}

public struct FolderNamingFailure: Error {
    public let code: Int32
    public let mayHaveRenamed: Bool

    public init(code: Int32, mayHaveRenamed: Bool) {
        self.code = code
        self.mayHaveRenamed = mayHaveRenamed
    }
}

extension UploadOutbox {
    public func initialNamingRecord(item: String) throws -> PendingUpload {
        guard let record = try records().first(where: { $0.item == item }),
              record.kind == .folder, record.state == .completed, record.remoteID != nil else {
            throw UploadError.readOnly
        }
        return record
    }

    public func nameFolder(_ record: inout PendingUpload, name: String,
                           checkpoint: (InitialFolderName.State) throws -> Void = { _ in },
                           rename: (RelativePath, RelativePath, UInt64, Bool) throws -> Void) throws {
        guard record.kind == .folder, record.state == .completed, record.item != nil,
              let identity = record.remoteID, RelativePath.isValidComponent(name) else {
            throw UploadError.readOnly
        }
        if let naming = record.initialName, !naming.isPending {
            guard naming.name.utf8.elementsEqual(name.utf8) else { throw UploadError.readOnly }
            return
        }
        if record.initialName == nil || record.initialName?.state == .prepared {
            if record.name.utf8.elementsEqual(name.utf8) {
                if record.initialName != nil {
                    record.initialName = nil
                    try save(record)
                }
                return
            }
            guard let source = RelativePath(record.path),
                  let parent = RelativePath(source.components.dropLast().joined(separator: "/")),
                  let destination = parent.appending(name) else { throw UploadError.invalidRequest }
            record.initialName = InitialFolderName(source: source.string, destination: destination.string,
                                                   name: name, state: .prepared)
            try save(record)
            try checkpoint(.prepared)
        }
        guard var naming = record.initialName, naming.name.utf8.elementsEqual(name.utf8),
              let source = RelativePath(naming.source), let destination = RelativePath(naming.destination) else {
            throw UploadError.unresolved
        }
        if naming.state == .verified { return }
        let recovering = naming.state == .attempting
        naming.state = .attempting
        record.initialName = naming
        try save(record)
        try checkpoint(.attempting)
        do {
            try rename(source, destination, identity, recovering)
        } catch let failure as FolderNamingFailure where !recovering && !failure.mayHaveRenamed {
            if failure.code == EEXIST { record.initialName = nil }
            else { record.initialName?.state = .prepared }
            try save(record)
            if failure.code == EEXIST { throw UploadError.collision }
            throw failure
        } catch let failure as FolderNamingFailure where !recovering && failure.code == EEXIST {
            record.initialName = nil
            try save(record)
            throw UploadError.collision
        }
        record.initialName?.state = .verified
        try save(record)
        try checkpoint(.verified)
    }

    public func completeFolderName(_ record: inout PendingUpload) throws {
        guard let naming = record.initialName, naming.state == .verified else { throw UploadError.unresolved }
        record.name = naming.name
        record.path = naming.destination
        record.initialName?.state = .completed
        try save(record)
    }

    public func observeFolderNames(parent: String, listing: DirectoryListing,
                                   apply: (PendingUpload, InitialFolderName) throws -> Void) throws {
        let entries = listing.entries + listing.collisionLosers.compactMap {
            if case .entry(let entry) = $0 { return entry }
            return nil
        }
        for var record in try records() where record.parent == parent {
            guard let naming = record.initialName, naming.state != .observed else { continue }
            let present = entries.contains {
                $0.kind == .folder && $0.fileID == record.remoteID && $0.name == naming.name
            }
            if present {
                if naming.isPending {
                    record.initialName?.state = .verified
                    try save(record)
                    try apply(record, naming)
                    try completeFolderName(&record)
                }
                record.initialName?.state = .observed
                try save(record)
            } else if naming.state == .verified || naming.state == .completed {
                let oldName = RelativePath(naming.source)?.components.last
                if entries.contains(where: { $0.fileID == record.remoteID && $0.name == oldName }) {
                    throw SourceFailure.listingIncomplete
                }
            }
        }
    }
}
