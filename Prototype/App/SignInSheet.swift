import SwiftUI

/// What opened the sign-in sheet.
struct SignInRequest: Identifiable {
    enum Purpose {
        /// Add Server… in a location's Server menu.
        case add(locationID: UUID)
        /// Sign In Again… for a saved server: Server and Name are fixed.
        case again(ServerRecord)
    }

    let id = UUID()
    let purpose: Purpose

    var fixed: ServerAccount? {
        if case .again(let server) = purpose { server.login } else { nil }
    }
}

/// Signs in with the password and returns the share names. A refused name or password throws
/// `SourceFailure.notAuthenticated`. The bytes are UTF-8.
typealias ShareLister = @Sendable (ServerAccount, Data) async throws -> [String]

/// docs/ui-design.md §11: Server, Name, Password, Cancel and Sign In.
struct SignInSheet: View {
    let request: SignInRequest
    /// Nil when the sign-in is saved, else the text to show in the sheet.
    let signIn: (_ server: String, _ name: String, _ password: Data) async -> String?
    let cancel: () -> Void

    @State private var server = ""
    @State private var name = ""
    @State private var password = ""
    @State private var message: String?
    @State private var busy = false
    @StateObject private var discovery = SMBServerDiscovery()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.fixed.map { UIText.signInAgainTitle($0.host) } ?? UIText.signInTitle).font(.headline)
            if request.fixed == nil { nearbyServers }
            Form {
                TextField(UIText.server, text: $server, prompt: Text(UIText.addressPlaceholder))
                    .disabled(request.fixed != nil)
                    .onChange(of: server) { discovery.cancelResolution() }
                TextField(UIText.name, text: $name)
                    .disabled(request.fixed != nil)
                SecureField(UIText.password, text: $password)
                    .onSubmit(submit)
            }
            Text(message ?? UIText.signInDescription)
                .font(.callout)
                .foregroundStyle(message == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(UIText.cancel) {
                    discovery.stop()
                    cancel()
                }.keyboardShortcut(.cancelAction)
                Button(UIText.signIn, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || discovery.resolving != nil || password.isEmpty
                              || (request.fixed == nil && server.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 420)
        .disabled(busy)
        .onAppear {
            if let fixed = request.fixed {
                server = fixed.host
                name = fixed.account
            } else {
                discovery.start()
            }
        }
        .onDisappear { discovery.stop() }
    }

    private var nearbyServers: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(UIText.nearbyServers).font(.subheadline.bold())
                Spacer()
                Button(UIText.refresh, systemImage: "arrow.clockwise") { discovery.start() }
                    .labelStyle(.iconOnly)
                    .help(UIText.refresh)
            }
            if discovery.services.isEmpty {
                Text(UIText.noNearbyServers).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(discovery.services) { service in
                            Button {
                                message = nil
                                discovery.resolve(service) { server = $0 }
                            } label: {
                                HStack {
                                    Label(service.name, systemImage: "externaldrive.connected.to.line.below")
                                        .lineLimit(1)
                                    Spacer()
                                    if discovery.resolving == service {
                                        ProgressView().controlSize(.small)
                                    }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.borderless)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 100)
            }
            if let failure = discovery.failure {
                Text(UIText.discoveryFailure(failure))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.font(.callout)
    }

    private func submit() {
        guard !busy, discovery.resolving == nil, !password.isEmpty else { return }
        discovery.stop()
        // The field's String can't be cleared from memory; keep only one copy as bytes.
        var bytes = Data(password.utf8)
        password = ""
        busy = true
        message = nil
        Task {
            message = await signIn(server, name, bytes)
            bytes.resetBytes(in: 0..<bytes.count)
            busy = false
            if message != nil, request.fixed == nil { discovery.start() }
        }
    }
}
