import Foundation
import XCTest
@testable import BerkeleyPlate

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data, [String:String]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
            let (code, data, headers) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class MenuRepositoryTests: XCTestCase {
    func testOfflineCacheAndExplicitStaleRejection() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "menu", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let fixture = try JSONCoding.decoder().decode(MenuEnvelope.self, from: data)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let transport = URLSession(configuration: configuration)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            transport.invalidateAndCancel()
            try? FileManager.default.removeItem(at: root)
            StubProtocol.handler = nil
        }
        let api = APIClient(baseURL: URL(string: "https://api.example.com")!, session: transport)
        let repository = MenuRepository(api: api, directory: root)
        let key = MenuKey(hall: .foothill, date: "2026-09-14", meal: .breakfast)
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/menus/foothill/2026-09-14/breakfast.json")
            return (200, data, ["ETag":"\"revision\""])
        }
        let online = try await repository.load(key, at: fixture.fetchedAt)
        XCTAssertFalse(online.isOffline)
        XCTAssertTrue(online.cacheSaved)
        StubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"revision\"")
            return (304, Data(), [:])
        }
        let revalidated = try await repository.load(key, at: fixture.fetchedAt)
        XCTAssertFalse(revalidated.isOffline)
        StubProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let offline = try await repository.load(key, at: fixture.fetchedAt)
        XCTAssertTrue(offline.isOffline)
        do {
            _ = try await repository.load(key, at: fixture.expiresAt)
            XCTFail("Expired cache must not be used")
        } catch APIError.expiredMenu { }
        StubProtocol.handler = { _ in (503, Data("{\"error\":{\"message\":\"Menu stale\"}}".utf8), [:]) }
        do {
            _ = try await repository.load(key, at: fixture.fetchedAt)
            XCTFail("Explicit source staleness must not use cached success")
        } catch APIError.server(let code, _) { XCTAssertEqual(code, 503) }
    }
}
