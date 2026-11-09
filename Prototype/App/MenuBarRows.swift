import SwiftUI

enum PanelLayout {
    static let width: CGFloat = 340
    static let inset: CGFloat = 14
    static let activityRowHeight: CGFloat = 40
}

struct PanelHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, PanelLayout.inset)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

struct PanelNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .padding(.horizontal, PanelLayout.inset)
            .padding(.vertical, 4)
    }
}

struct PanelDivider: View {
    var body: some View {
        Divider().padding(.horizontal, PanelLayout.inset).padding(.vertical, 5)
    }
}

/// Full-width and plain like a menu item, with the same highlight under the pointer.
private struct HoverHighlight: ViewModifier {
    @Binding var hovering: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(hovering && isEnabled ? 1 : 0), in: .rect(cornerRadius: 5))
            .contentShape(.rect)
            .onHover { hovering = $0 }
            .padding(.horizontal, 6)
    }
}

/// An action row such as Pause Downloads, with its count or shortcut on the right.
struct PanelButton: View {
    let title: String
    var trailing: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, trailing: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.trailing = trailing
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(isEnabled ? .primary : .tertiary)
                Spacer()
                if let trailing { Text(trailing).foregroundStyle(.secondary) }
            }
            .modifier(HoverHighlight(hovering: $hovering))
        }
        .buttonStyle(.plain)
    }
}

/// Sign In Again… or Connect, as accent-colored text.
private struct RowAction: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action).buttonStyle(.plain).foregroundStyle(.tint)
    }
}

private struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}

/// A click shows the location in Finder and closes the panel; a location with a problem shows
/// its action instead.
private struct PanelLocationRow<Action: View>: View {
    let name: String
    let status: String
    let color: Color
    let showInFinder: () -> Void
    @ViewBuilder let action: () -> Action
    var hasAction: Bool
    @State private var hovering = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
                showInFinder()
            } label: {
                HStack(spacing: 8) {
                    StatusDot(color: color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).lineLimit(1)
                        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if hovering && !hasAction { Text(UIText.showInFinder).foregroundStyle(.secondary) }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(UIText.joined(name, status))
            .accessibilityHint(UIText.showInFinder)
            action()
        }
        .modifier(HoverHighlight(hovering: $hovering))
    }
}

struct LocationRow: View {
    var model: AppModel
    let record: LocationRecord
    let signInAgain: (UUID, UUID) -> Void

    var body: some View {
        let state = model.state(record)
        let share = model.share(record.shareID)
        PanelLocationRow(name: record.name, status: model.panelStatus(record), color: color(state),
                         showInFinder: { model.showInFinder(record.id) }, action: {
            if let share, state == .needsSignIn {
                RowAction(title: UIText.signInAgain) { signInAgain(share.serverID, record.id) }
            } else if let share, state == .notConnected {
                RowAction(title: UIText.connect) { model.connect(share) }
            }
        }, hasAction: share != nil && [.needsSignIn, .notConnected].contains(state))
        .disabled(record.removing)
    }

    private func color(_ state: AppModel.LocationState) -> Color {
        switch state {
        case .connected(nil): .green
        case .connected(.some): .blue
        case .unresponsive: .orange
        case .starting, .notConnected, .removing: .gray
        case .catalogUnavailable, .turnedOff, .needsSignIn, .folderMissing: .red
        }
    }
}

struct VolumeRow: View {
    var model: AppModel
    let volume: ServerVolumeRecord
    let signInAgain: (UUID, UUID) -> Void

    var body: some View {
        let mounted = model.mountedVolumes.contains(volume.shareID)
        let share = model.share(volume.shareID)
        let refused = share.map { model.needsSignIn($0.serverID) } ?? false
        PanelLocationRow(name: model.volumeName(volume), status: model.volumeStatus(volume),
                         color: mounted ? .green : refused ? .red : .gray,
                         showInFinder: { model.showInFinder(volume.id) }, action: {
            if let share, !mounted {
                if refused {
                    RowAction(title: UIText.signInAgain) { signInAgain(share.serverID, volume.id) }
                } else {
                    RowAction(title: UIText.connect) { model.connect(share) }
                }
            }
        }, hasAction: share != nil && !mounted)
        .disabled(model.connectionBusy)
    }
}

struct TransferRow: View {
    var model: AppModel
    let transfer: ActiveTransfer

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: transfer.direction == .upload ? "arrow.up" : "arrow.down")
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityLabel(transfer.direction == .upload ? UIText.upload : UIText.download)
            VStack(alignment: .leading, spacing: 2) {
                Text(transfer.name).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !transfer.waiting {
                    ProgressView(value: Double(transfer.completed), total: Double(max(1, transfer.total)))
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                }
            }
        }
        .padding(.horizontal, PanelLayout.inset)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        if transfer.waiting { return UIText.waitingFor(model.host(domain: transfer.domain) ?? "") }
        let location = model.record(domain: transfer.domain)?.name ?? ""
        return UIText.joined(location, UIText.transferred(transfer.completed, of: transfer.total))
    }
}

struct ActivityRow: View {
    var model: AppModel
    let event: ActivityEvent
    /// Changes each minute, so that the relative time is drawn again.
    let now: Date
    /// Whole minutes, because the row is drawn again only each minute.
    private static let time = Date.RelativeFormatStyle(allowedFields: [.year, .month, .week, .day, .hour, .minute],
                                                       presentation: .named, unitsStyle: .abbreviated)

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(isFailure ? .red : .secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.name).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            // macOS releases failed uploads only for a whole location.
            if event.kind == .uploadFailed, let domain = event.domain, model.record(domain: domain) != nil {
                RowAction(title: UIText.retry) { model.retryPending(domain: domain) }
            }
        }
        .padding(.horizontal, PanelLayout.inset)
        .frame(height: PanelLayout.activityRowHeight)
        .help(event.detail ?? "")
    }

    private var detail: String {
        let time = event.date.formatted(Self.time)
        let location = event.domain.flatMap { model.record(domain: $0)?.name }
        return ([UIText.activity(event.kind)] + [location].compactMap { $0 } + [time]).joined(separator: " · ")
    }

    private var isFailure: Bool {
        [.uploadFailed, .downloadFailed, .lowDiskSpace, .signInNeeded, .connectionLost].contains(event.kind)
    }

    private var symbol: String {
        switch event.kind {
        case .uploaded: "arrow.up.circle"
        case .downloaded: "arrow.down.circle"
        case .keptDownloaded: "checkmark.circle"
        case .uploadFailed, .downloadFailed: "exclamationmark.circle"
        case .conflictCopy: "doc.on.doc"
        case .lowDiskSpace: "internaldrive"
        case .signInNeeded: "person.crop.circle.badge.exclamationmark"
        case .connectionLost: "bolt.horizontal.circle"
        case .connectionRestored: "bolt.horizontal.circle.fill"
        }
    }
}
