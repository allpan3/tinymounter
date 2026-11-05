import Foundation
@testable import TransferCore

extension Catalog {
    func rememberRevision(_ receipt: FileRevision, expectedVersion: String) throws {
        guard try item(id: receipt.item)?.contentVersion == expectedVersion else { throw UploadError.unresolved }
        try database.prepare("UPDATE items SET edit_version = ? WHERE id = ?") {
            try $0.bind(1, receipt.contentVersion)
            try $0.bind(2, receipt.item)
            try $0.run()
        }
    }
}
