import Foundation

/// All UI text, in ASD-STE100 (docs/ui-design.md §8), so the STE checker reads one file.
enum UIText {
    static let appName = "tinymounter"

    // Sidebar
    static let locations = "Locations"
    static let settings = "Settings"
    static let general = "General"
    static let storage = "Storage"
    static let servers = "Servers"
    static let about = "About"
    static let search = "Search"
    static let notAdded = "Not added"
    static let newLocation = "New Location"
    static let duplicate = "Duplicate"
    static let showInFinder = "Show in Finder"
    static let removeLocationMenu = "Remove Location…"
    static let settingsMenu = "Settings…"

    // Location pane
    static let access = "Access"
    static let readOnly = "Read only"
    static let confirmWriteSetup = "Confirm Write Access"
    static let writeRequirements = "Allow changes only if every program that changes files in this share does so over SMB. Programs on the server itself, such as its apps, sync tools and scripts, bypass tinymounter’s protection. Other computers can see a new file before its upload finishes. During a save, the file is briefly unavailable, and tinymounter keeps hidden temporary files next to it. Do not delete them. An interrupted save can keep the file unavailable until tinymounter recovers it."
    static var writeModeHint: String {
        let base = "Read only prevents changes to files on the server. Turn it off to create items, edit files, and rename or move ordinary files within this location."
        guard SourceReaderBridge.deletionEnabled else {
            return base + " Folder moves, deleting and replacing items remain unavailable."
        }
        return base + " Deletion permanently removes files and folders from the server. tinymounter cannot restore deleted items."
    }
    static let exportEdit = "Export Local Copy…"
    static let retryPending = "Retry Pending Changes"
    static let waitingToUpload = "Waiting to upload"
    static let stopUploading = "Stop Uploading"
    static func stopUploadingTitle(_ path: String) -> String {
        "Stop the upload of “\((path as NSString).lastPathComponent)”?"
    }
    /// macOS sends a stopped item again when its metadata changes, and a new item in a folder changes it.
    static func stopUploadingMessage(_ kind: CatalogRow.Kind) -> String {
        kind == .folder ? """
            The folder and its contents stay on this Mac and are not uploaded. If you change the folder or put an \
            item in it, tinymounter tries to upload the folder again.
            """
            : "The file stays on this Mac and is not uploaded. If you change the file, tinymounter tries to upload it again."
    }
    static let stopRefused = "tinymounter cannot stop this item, because the server can have it. Use Retry Pending Changes to check the server."
    static let stopEditMessage = """
        Save a copy of the changes that did not upload. tinymounter then stops the upload and replaces \
        the file on this Mac with the version on the server.
        """
    static let stopEditRefused = "tinymounter did not stop the upload. The local save is retained."
    /// The default name of a stopped save's copy, such as "Report (not uploaded 2026-11-02).txt".
    static func stoppedEditName(_ path: String, date: Date) -> String {
        let name = URL(fileURLWithPath: path)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let suffix = name.pathExtension.isEmpty ? "" : "." + name.pathExtension
        return name.deletingPathExtension().lastPathComponent + " (not uploaded \(formatter.string(from: date)))" + suffix
    }
    static func editPending(_ path: String) -> String { "Edited file: \(path)" }
    static func deletionPending(_ path: String) -> String { "Permanent deletion: \(path)" }
    static let deletionEffect = "Deletion permanently removes items from the server and its locations. tinymounter cannot restore deleted items."
    static let deletionWaiting = "Waiting to continue deletion"
    static let deletionActive = "Deletion in progress"
    static let deletionSettlement = "Waiting to update the locations"
    static let deletionUnconfirmed = "The deletion result is unconfirmed."
    static let deletionDetails = "Item results"
    static let deletionRetry = "Retry"
    static let deletionRetryHint = "Retry uses the recorded items. It does not add items to this request."
    static let deletionNewRequestHint = "To delete an item that remains, select it again in Finder."
    static let deletionStatusUnavailable = "Cannot read deletion status. Keep this location until its status is available."
    static let stopDeleting = "Stop Deleting"
    static let stopDeletingMessage = "Items already deleted cannot be restored. A request already sent to the server can still delete its item."
    static func stopDeletingTitle(_ path: String) -> String {
        "Stop deleting “\((path as NSString).lastPathComponent)”?"
    }
    static let dismissDeletionTitle = "Dismiss this deletion notice?"
    static let dismissDeletionMessage = "This hides the notice. It does not restore deleted items or confirm an uncertain result."
    static func deletionSummary(_ record: PendingDeletion) -> String {
        "Items confirmed deleted: \(record.summary[.deleted] ?? 0) of \(record.plan.nodes.count)."
    }
    static func deletionFailed(_ reason: DeletionFailure, at date: Date) -> String {
        "\(deletionFailure(reason)) Last try: \(date.formatted(date: .abbreviated, time: .shortened))."
    }
    static func deletionFailure(_ failure: DeletionFailure) -> String {
        switch failure {
        case .changed: "The item changed on the server."
        case .replaced: "Another item is now at this name."
        case .moved: "The item moved on the server."
        case .parentChanged: "A parent folder changed on the server."
        case .unsupported: "tinymounter cannot delete this type of item or this folder."
        case .sharingViolation: "Another program has this item open. Close it before a new deletion request."
        case .accessDenied: "The server does not give permission to delete this item."
        case .cannotDelete: "The server refused to delete this item."
        case .directoryNotEmpty: "The folder still contains items."
        case .unconfirmed: "tinymounter cannot confirm the deletion result."
        case .connection: "There is no connection to the server."
        case .authentication: "The server did not accept the sign-in."
        case .pendingChanges, .busy: "Other changes on this share must finish first."
        case .readOnly: "tinymounter has no write access for this deletion."
        case .cancelled, .stopped: "Deletion was stopped."
        case .storage: "There is not sufficient space on this Mac."
        case .unknown: "tinymounter could not finish the deletion. Retry to check the recorded request."
        }
    }
    static func deletionItemStatus(_ item: DeletionItemProgress) -> String {
        switch item.outcome {
        case .deleted?: "Permanently deleted"
        case .unconfirmed?: deletionUnconfirmed
        case .stopped?: "Not attempted. Deletion was stopped."
        case .changed?: deletionFailure(.changed)
        case .replaced?: deletionFailure(.replaced)
        case .moved?: deletionFailure(.moved)
        case .parentChanged?: deletionFailure(.parentChanged)
        case .unsupported?: deletionFailure(.unsupported)
        case .sharingViolation?: deletionFailure(.sharingViolation)
        case .accessDenied?: deletionFailure(.accessDenied)
        case .cannotDelete?: deletionFailure(.cannotDelete)
        case .directoryNotEmpty?: deletionFailure(.directoryNotEmpty)
        case nil: item.mayHaveBeenRequested ? deletionUnconfirmed : "Not yet attempted"
        }
    }
    static func unnamedPending(_ count: Int) -> String { "Other pending changes: \(count)" }
    static func renameDescription(_ rename: RenameIntent) -> String {
        switch rename {
        case .file(let record):
            return record.views.contains(where: { $0.targetParent != $0.parent })
                ? pendingMove(from: record.oldName, to: record.destination)
                : pendingRename(from: record.oldName, to: record.name)
        case .folder(let record):
            let moved = RelativePath(record.source)?.components.dropLast()
                != RelativePath(record.destination)?.components.dropLast()
            return moved ? pendingMove(from: record.oldName, to: record.destination)
                : pendingRename(from: record.oldName, to: record.name)
        }
    }
    static func newFolderPending(_ path: String) -> String { "New folder: \(path)" }
    static func newFilePending(_ path: String) -> String { "New file: \(path)" }
    static func createFailed(_ reason: String, at date: Date) -> String {
        "Did not upload: \(reason) Last try: \(date.formatted(date: .abbreviated, time: .shortened))."
    }
    static func uploadFailure(_ error: Error) -> String {
        if let upload = error as? UploadError {
            switch upload {
            case .pendingWrites: return "Other changes on this share must finish first."
            case .readOnly: return "tinymounter has no write access to this share."
            case .collision: return "An item with this name is already on the server."
            case .unresolved: return "tinymounter cannot confirm the result on the server."
            case .invalidRequest: return "tinymounter cannot create this item in this folder."
            case .editConflict: return "The item changed on the server."
            case .excluded: return "The upload was stopped."
            }
        }
        if let failure = error as? FolderMutationFailure {
            if failure.mayHaveChanged { return uploadFailure(UploadError.unresolved) }
            switch SourceFailure.classify(errno: failure.code, context: .listing) {
            case .serverUnreachable: return "There is no connection to the server."
            case .notAuthenticated: return "The server did not accept the sign-in."
            default: return "The server refused the change: \(String(cString: strerror(failure.code)))."
            }
        }
        // A system error comes from the share; the Mac's own space check throws a Cocoa error.
        let system = error as NSError
        if system.domain == NSPOSIXErrorDomain, [Int(ENOSPC), Int(EDQUOT)].contains(system.code) {
            return "There is not sufficient space on the server."
        }
        if DownloadSpace.isFull(error) { return "There is not sufficient space on this Mac." }
        switch SourceFailure.classify(error, context: .listing) {
        case .serverUnreachable, .notConnected: return "There is no connection to the server."
        case .notAuthenticated: return "The server did not accept the sign-in."
        case .noPermission: return "The server does not give write access."
        default:
            let failure = error as NSError
            if failure.domain == NSPOSIXErrorDomain, let code = Int32(exactly: failure.code) {
                return "The upload failed: \(String(cString: strerror(code)))."
            }
            return "Error \(failure.domain) \(failure.code)."
        }
    }
    static let editPreparing = "Local save not yet confirmed. Keep the document open."
    static let editNeedsRecovery = "Recovery needed. The local save is retained."
    static let editInterrupted = "Upload not finished. The file on the server has not changed. The local save is retained."
    static let editConflict = "Conflict. The local save is retained."
    static let publishedRecovery = "Saved on the server. Recovery files still need attention."
    static let conflictRecovery = "Saved as a conflict copy. Recovery files still need attention."
    static func savedChangeBytes(_ bytes: Int64) -> String {
        "Local saved copies: " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
    static let savedChangeSpace = "New saves stop when there is not enough space above the 2 GiB reserve. Saved copies are retained."
    static let retiredEdit = "Older save kept for recovery. It will not upload. Newer saves can continue."
    static let pendingStatusUnavailable = "Cannot read pending change status. Local copies are retained."
    static let renameNeedsRecovery = "File change pending or needs recovery. Keep this location until it finishes."
    static func pendingRename(from: String, to: String) -> String { "Rename \(from) to \(to)" }
    static func pendingMove(from: String, to: String) -> String { "Move \(from) to \(to)" }
    static let conflictSaved = "Saved as a conflict copy"
    static let dismissEditNotice = "Dismiss Notice"
    static let writeGrantMessage = "Select the root of this share to confirm write access."
    static let pendingUploadHint = "Keep this location and its source until the changes finish. Pending content stays on this Mac. An interrupted change may need recovery."
    static let uploadAccessError = "Select this share again. Read only cannot be enabled while changes are pending."
    static func pendingUploads(_ count: Int) -> String { "Pending changes: \(count)" }
    static let source = "Source"
    static let server = "Server"
    static let share = "Share"
    static let folder = "Folder"
    static let name = "Name"
    static let fullShare = "Full share"
    static let select = "Select…"
    static let addShare = "Add Share…"
    static let addServer = "Add Server…"
    static let addServerTitle = "Type the address of the server."
    static let addServerDescription = "For example, smb://server. Choose a share when you add a location."
    static let addressPlaceholder = "smb://server"
    static let noServer = "No server"
    static let connect = "Connect"
    static let disconnect = "Disconnect"
    static let noShare = "No share"
    static let connectionMode = "Connection Mode"
    static let fileProvider = "File Provider"
    static let fileProviderDescription = """
        Finder shows the files below Locations. A file downloads when you open it. \
        You can keep files on this Mac for offline use.
        """
    static let serverVolume = "Server volume"
    static let serverVolumeDescription = """
        macOS connects to the share, the same as Connect to Server in Finder. Files open directly from the \
        server. You cannot use it offline. Not available in this version.
        """
    static let keepDownloaded = "Keep Downloaded"
    static let requested = "Requested"
    static let availableOffline = "Available offline"
    static let updateInProgress = "Update in progress"
    static let notSufficientSpace = "Not sufficient space"
    static let lowSpaceHint = "Free space on this Mac. Kept downloads resume automatically."
    static let notOnServer = "Not on the server"
    static let keepHint = "To keep a file or folder downloaded, right-click it in Finder. Then click Keep Downloaded."
    static let draftKeepHint = """
        tinymounter downloads these items after you click Add. If an item is not in the folder, tinymounter \
        shows “Not on the server”.
        """
    static let removeLocationDescription = "Remove this location from this Mac. The files on the server do not change."
    static let draftBar = "Finder does not show this location until you click Add."
    static let applyBar = """
        If you change the source or the connection mode, tinymounter removes the downloaded copies of this \
        location. The files on the server do not change.
        """
    static let add = "Add"
    static let cancel = "Cancel"
    static let apply = "Apply"
    static let revert = "Revert"
    static let removeItem = "Remove"

    // Location state
    static let connected = "Connected"
    static let notConnected = "Not connected"
    static let removalNotComplete = "The removal is not complete."
    static let connectInServers = "Open Servers in tinymounter Settings. Then click Connect."
    static let selectShareAgain = "Select the share again in Servers."
    static let folderNotOnShare = "This folder is not on the share."
    static let catalogUnavailable = "tinymounter cannot read the data for this location. Remove the location. Then add it again."
    static let turnedOff = "File Provider is off."
    static let enableFileProvider = "In Extensions, open TinyMounterPrototype. Then turn on File Provider."
    static let openSystemSettings = "Open System Settings…"
    static let problem = "Problem"

    static func cannotConnect(_ host: String) -> String {
        "tinymounter cannot connect to \(host). Make sure that \(host) is on. Make sure that this Mac is on the same network."
    }

    static func cannotDisconnect(_ share: String) -> String {
        "tinymounter cannot disconnect “\(share)”. Close the files that are open on it. Then try again."
    }

    static func downloaded(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded(.down)))% downloaded"
    }

    static func joined(_ parts: String...) -> String { parts.joined(separator: " · ") }

    static func source(host: String, share: String, folder: String) -> String {
        [host, share, folder.isEmpty ? fullShare : folder].joined(separator: " › ")
    }

    // Confirmations
    static func removeTitle(_ name: String) -> String { "Remove “\(name)” from this Mac?" }
    static let removeMessage = """
        The files on the server do not change. tinymounter removes the downloaded copies of this location \
        from this Mac.
        """
    static func removeStops(_ items: [String]) -> String {
        "These items did not upload. macOS keeps them on this Mac in a folder. tinymounter shows the folder in "
            + "Finder after the removal.\n" + list(items)
    }
    static func removeBlockedTitle(_ name: String) -> String { "tinymounter cannot remove “\(name)” now" }
    static func removeBlockedMessage(_ items: [String]) -> String {
        "These changes can be on the server. Review their recovery actions in Settings. Then remove the location "
            + "again.\n" + list(items)
    }
    private static func list(_ items: [String]) -> String {
        let shown = items.prefix(10).map { "• " + $0 }
        let more = items.count > shown.count ? ["\(items.count - shown.count) more"] : []
        return (shown + more).joined(separator: "\n")
    }
    static let saveKeepList = "Save the Keep Downloaded list"
    static let removeLocation = "Remove Location"
    static func applyTitle(_ name: String) -> String { "Change the source of “\(name)”?" }
    static func downloadTitle(_ count: Int) -> String {
        count == 1 ? "Download 1 kept file now?" : "Download \(count) kept files now?"
    }
    static func downloadMessage(_ name: String) -> String {
        """
        tinymounter found items of the saved Keep Downloaded list in “\(name)”. They are in folders that you \
        did not open in Finder. They download only when you open these folders.
        """
    }
    static let downloadNow = "Download Now"
    static let notNow = "Not Now"

    // Errors
    static let settingsUnreadable = """
        tinymounter cannot read its settings file. You cannot add or change a location. If an earlier \
        version made the file, click Start Fresh in General.
        """
    static let startFresh = "Start Fresh"
    static let startFreshMenu = "Start Fresh…"
    static let startFreshTitle = "Remove all locations and start fresh?"
    static let startFreshMessage = """
        tinymounter cannot read the data of an earlier version. Start Fresh removes all locations from \
        this Mac. Then you add them again. The files on the server do not change. Changes that did not \
        upload are kept in a folder that opens in Finder.
        """
    static let domainsUnreadable = "tinymounter cannot read its locations from macOS. Quit tinymounter. Then open it again."
    static let wrongFolderPath = "This folder path is not correct. Type a path in the share."
    static let wrongName = "This name is not correct. Type a different name."
    static let notVolumeRoot = "This folder is not a share. Select the share, not a folder in it."
    static let notSMBShare = "This volume is not an SMB share. To add a share, click Add Share…."
    static let addressRejected = "tinymounter cannot use the address of this share."
    static let otherShare = "This is a different share. To add it, click Add Share…."
    static let shareNotMounted = "The share is not connected. In Servers, click Connect. Then click Select… again."
    static let wrongAddress = "This address is not correct. Type an address such as smb://server/share."
    static func passwordNotAccepted(_ host: String) -> String {
        "\(host) did not accept the password. Type the password again."
    }
    static let tooManyItems = "This folder has more than 100,000 items. tinymounter cannot show it."
    static let cannotShow = "Finder cannot show this location."
    static let serverInUse = "A location uses this server. Remove the location first."
    static func cannotDo(_ code: String) -> String { "tinymounter cannot do this (\(code))." }

    // Panels
    static let selectShareMessage = "Click Open to give tinymounter access to this share."
    static let selectFolderMessage = "Select a folder in the share."

    // Servers
    static let selectAgain = "Select Again…"
    static let notResponding = "Cannot connect"
    static let selectShareAgainShort = "Select the share again."
    static func accountAndShare(_ account: String, _ share: String) -> String { "\(account) · \(share)" }
    static let noServers = "To add a server, click Add Server…."
    static let noSelectedShares = "No shares selected."
    static let otherConnectedShares = "Other Connected Shares"
    static let useShare = "Use Share"
    static let useOtherAddressTitle = "Use the connection at this other address?"
    static func useOtherAddress(_ address: ShareAddress, server: String) -> String {
        "Use \(address.host) / \(address.share), connected as \(address.account), with \(server)? Disconnect and Remove eject this connection from this Mac."
    }
    static let connectAnotherShare = "Connect Another Share…"
    static let chooseShareDescription = """
        These shares are already connected on this Mac. To use one, select it and click Use Share. \
        To connect another share, click Connect Another Share. macOS asks for the password if necessary. \
        Select “Remember this password in my keychain”, so that tinymounter can connect again.
        """
    static func chooseShareTitle(_ host: String) -> String { "Choose a share for \(host)." }
    static func mountedShare(_ address: ShareAddress) -> String {
        "\(address.host) / \(address.share) · \(address.account)"
    }
    static func serverAddress(_ server: ServerRecord) -> String {
        server.account.map { "\($0)@\(server.host)" } ?? server.host
    }
    static let removeServerTitle = "Disconnect this server's shares and remove the server?"
    static let removeServerMessage = "The files on the server do not change. Other apps lose access to these connections."
    static let cannotRemoveServer = """
        tinymounter cannot remove this server. Its entry has been kept. Close files that are open on its \
        shares. Then try again.
        """
    static let serverSetupHint = "To show files in Finder, add a location under Locations."
    static let disconnectHint = "Disconnect ejects the share from this Mac, including its connection in Finder."

    // General
    static let openAtLogin = "Open at login"
    static let openAtLoginApproval = "Allow tinymounter in System Settings › General › Login Items & Extensions."
    static let showInMenuBar = "Show in menu bar"
    static let menuBarDescription = """
        The menu bar item keeps tinymounter open. tinymounter must be open to read data that is not downloaded.
        """
    static let notifications = "Notifications"
    static let notificationsDescription = "Show a notification when a share disconnects or a download cannot start."

    // Storage
    static let notAvailable = "Not available"
    static let total = "Total"
    static let storageDescription = """
        This includes the kept files. When disk space is low, macOS removes the downloaded files that you do \
        not keep. Remove Downloads removes them immediately. tinymounter leaves 2 GiB free for macOS. \
        A download can need extra temporary space.
        """
    static let removeDownloadsMenu = "Remove Downloads…"
    static let removeDownloads = "Remove Downloads"
    static let cannotRemoveDownloads = "tinymounter cannot remove the downloads of this location."

    static func removeDownloadsTitle(_ name: String) -> String { "Remove the downloads of “\(name)”?" }

    static func removeDownloadsMessage(files: Int, bytes: Int64) -> String {
        let count = files == 1 ? "1 file" : "\(files) files"
        return """
            tinymounter removes the downloaded copies of \(count) (\(size(bytes))) that you do not keep. Kept files \
            stay on this Mac. The files on the server do not change.
            """
    }

    static func downloadsStayed(_ files: Int) -> String {
        let (count, them) = files == 1 ? ("1 downloaded file", "it") : ("\(files) downloaded files", "them")
        return "tinymounter cannot remove \(count). If an app uses \(them), close the app. Then try again."
    }

    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        // A no-break space keeps "307.1 MB" on one line in an alert.
        return formatter.string(fromByteCount: bytes).replacingOccurrences(of: " ", with: "\u{A0}")
    }

    static func downloadedSize(_ bytes: Int64) -> String { "\(size(bytes)) downloaded" }

    static func availableSize(_ bytes: Int64) -> String { "\(size(bytes)) available" }

    // About
    static let version = "Version 0.1 (prototype)"
    static let diagnostics = "Diagnostics"
    static let diagnosticsDescription = "This report helps to find problems. It does not include file names, paths, or passwords."
    static let copy = "Copy"

    // Menu bar
    static let pauseDownloads = "Pause Downloads"
    static let resumeDownloads = "Resume Downloads"
    static let quit = "Quit tinymounter"
    static let noLocations = "No locations"
    static let pauseFailed = "tinymounter cannot stop background downloads for one or more locations."
    static let resumeFailed = "tinymounter cannot start background downloads again for one or more locations."

    // Quit
    static let quitTitle = "Downloads are in progress."
    static let quitMessage = "Files that are not downloaded cannot open until tinymounter starts again."

    // Notifications
    static func shareDisconnected(_ share: String) -> String { "“\(share)” is not connected" }
    static func cannotConnectTitle(_ host: String) -> String { "tinymounter cannot connect to \(host)" }
    static let downloadFailedTitle = "A file cannot download"
    static func onSameNetwork(_ host: String) -> String {
        "Make sure that \(host) is on. Make sure that this Mac is on the same network."
    }
}
