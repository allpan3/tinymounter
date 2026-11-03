import Foundation

extension M22FinderProbe {
    static func configs(_ primary: Config) throws -> [Config] {
        let url = try directory(primary.run).appending(path: "peer-config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [primary] }
        let peer = try load(Config.self, from: url)
        try require(peer.run == primary.run && peer.grant == primary.grant
            && peer.location != primary.location && peer.domain != primary.domain, "peer-scope")
        return [primary, peer]
    }

    static func taskLocations(folder: String) throws -> Set<UUID> {
        let pointer = try SharedContainer.url().appending(path: "M22Finder-active.json")
        guard FileManager.default.fileExists(atPath: pointer.path) else { return [] }
        let primary = try load(Config.self, from: pointer)
        guard primary.folder == folder else { return [] }
        return try Set(configs(primary).map(\.location))
    }
}

#if !M22_FINDER_PROVIDER
extension LocationController {
    private func m22FinderAddPeer(_ config: M22FinderProbe.Config) async throws {
        guard let settings = store.settings, let primary = settings.locations.first(where: {
            $0.id == config.location && $0.domainID == config.domain && $0.folder == config.folder
        }), primary.grantID == config.grant, !primary.removing else {
            throw M22FinderProbe.Failure.check("peer-owner")
        }
        let (_, grant, bookmark) = try m22FinderGrant(settings)
        try M22FinderProbe.require(grant.id == config.grant, "peer-grant")
        try m22FinderExclusive(settings, folder: config.folder, allowed: config.location)
        let directory = try M22FinderProbe.directory(config.run)
        let id = UUID()
        try M22FinderProbe.save(["location": id.uuidString],
            to: directory.appending(path: "peer-setup-started.json"))
        let record = try await add(id: id, name: "M22 Overlap " + config.run.uuidString,
            folder: RelativePath(config.folder)!, grantID: config.grant, writeBookmark: bookmark)
        let peer = M22FinderProbe.Config(run: config.run, location: id, grant: config.grant,
            domain: record.domainID)
        try M22FinderProbe.save(peer, to: directory.appending(path: "peer-config.json"))
    }
}
#endif
