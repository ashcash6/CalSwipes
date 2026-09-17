import CryptoKit
import Foundation

struct CachedMenu: Codable {
    let menu: MenuEnvelope
    let etag: String?
}

struct MenuLoad {
    let menu: MenuEnvelope
    let isOffline: Bool
    let cacheSaved: Bool
}

actor MenuRepository {
    private let api: APIClient
    private let directory: URL

    init(api: APIClient, directory: URL? = nil) {
        self.api = api
        let root = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let namespace = SHA256.hash(data: Data(api.origin.utf8)).map { String(format: "%02x", $0) }.joined()
        self.directory = root.appendingPathComponent("Menus-\(namespace)", isDirectory: true)
    }

    private func read(_ key: MenuKey) -> CachedMenu? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(key.cacheName + ".json")),
              let saved = try? JSONCoding.decoder().decode(CachedMenu.self, from: data),
              saved.menu.matches(key) else { return nil }
        return saved
    }

    private func write(_ saved: CachedMenu, key: MenuKey) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONCoding.encoder().encode(saved)
        try data.write(to: directory.appendingPathComponent(key.cacheName + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func load(_ key: MenuKey, at instant: Date = Date()) async throws -> MenuLoad {
        let cached = read(key)
        do {
            let result = try await api.send(
                path: "menus/\(key.hall.rawValue)/\(key.date)/\(key.meal.rawValue).json",
                etag: cached?.etag
            )
            try Task.checkCancellation()
            if result.response.statusCode == 304 {
                guard let cached, cached.menu.isFresh(at: instant) else { throw APIError.expiredMenu }
                return MenuLoad(menu: cached.menu, isOffline: false, cacheSaved: true)
            }
            let menu = try JSONCoding.decoder().decode(MenuEnvelope.self, from: result.data)
            guard menu.matches(key), ["published", "not_published"].contains(menu.status) else { throw APIError.invalidResponse }
            guard menu.isFresh(at: instant) else { throw APIError.expiredMenu }
            let saved = CachedMenu(menu: menu, etag: result.response.value(forHTTPHeaderField: "ETag"))
            var stored = true
            do { try write(saved, key: key) } catch { stored = false }
            return MenuLoad(menu: menu, isOffline: false, cacheSaved: stored)
        } catch let error as URLError {
            // A server's explicit stale/absent response must never be overridden with a cached success.
            guard error.code != .cancelled else { throw error }
            if let cached, cached.menu.isFresh(at: instant) {
                return MenuLoad(menu: cached.menu, isOffline: true, cacheSaved: true)
            }
            if cached != nil { throw APIError.expiredMenu }
            throw error
        }
    }
}
