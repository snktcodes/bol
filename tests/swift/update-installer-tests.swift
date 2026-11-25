import CryptoKit
import Foundation
import Testing

@testable import Bol

@Suite(.serialized) struct UpdateInstallerTests {
	private static let payload = Data("not really a disk image".utf8)
	private static let payloadHash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

	private func session() -> URLSession {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [DMGStub.self]
		return URLSession(configuration: configuration)
	}

	private func release(sha256: String?) -> Release {
		Release(
			version: "9.9.9", build: 999, url: URL(string: "https://dl.test/Bol-9.9.9.dmg")!, sha256: sha256,
			minimumSystemVersion: nil, notes: nil)
	}

	@Test func acceptsADownloadThatMatchesTheChecksum() async throws {
		let dmg = try await UpdateInstaller.download(release: release(sha256: Self.payloadHash), session: session())
		defer { try? FileManager.default.removeItem(at: dmg) }
		#expect(try Data(contentsOf: dmg) == Self.payload)
	}

	@Test func rejectsADownloadThatDoesnt() async {
		let wrong = String(repeating: "0", count: 64)
		await #expect(throws: UpdateInstaller.Failure.checksumMismatch) {
			_ = try await UpdateInstaller.download(release: release(sha256: wrong), session: session())
		}
	}

	@Test func refusesAFeedWithoutAChecksum() async {
		await #expect(throws: UpdateInstaller.Failure.self) {
			_ = try await UpdateInstaller.download(release: release(sha256: nil), session: session())
		}
	}

	@Test func rejectsAnAppThatIsntBol() async throws {
		let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bol-verify-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: folder) }
		let impostor = try makeApp(in: folder, name: "Impostor", bundleID: "com.example.other", build: "999")
		let current = try makeApp(in: folder, name: "Current", bundleID: "com.snktcodes.bol", build: "1")
		await #expect(throws: UpdateInstaller.Failure.badPackage("a different app's bundle id")) {
			try await UpdateInstaller.verify(app: impostor, release: release(sha256: nil), against: current)
		}
		let wrongBuild = try makeApp(in: folder, name: "Old", bundleID: "com.snktcodes.bol", build: "5")
		await #expect(throws: UpdateInstaller.Failure.badPackage("its build doesn't match the release")) {
			try await UpdateInstaller.verify(app: wrongBuild, release: release(sha256: nil), against: current)
		}
	}

	@Test func unsignedBuildsDontUpdateThemselves() {
		// The test runner, like a local or dev build, isn't a signed Bol release in a writable folder.
		guard case .failure = UpdateInstaller.installableLocation() else {
			Issue.record("expected the test runner not to be installable")
			return
		}
	}

	@Test func hashesFilesInChunks() throws {
		let file = FileManager.default.temporaryDirectory.appendingPathComponent("bol-hash-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: file) }
		try Self.payload.write(to: file)
		#expect(try UpdateInstaller.sha256(file: file) == Self.payloadHash)
	}

	private func makeApp(in folder: URL, name: String, bundleID: String, build: String) throws -> URL {
		let app = folder.appendingPathComponent("\(name).app")
		let contents = app.appendingPathComponent("Contents")
		try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
		let info: [String: Any] = [
			"CFBundleIdentifier": bundleID, "CFBundleVersion": build, "CFBundleExecutable": name,
			"CFBundlePackageType": "APPL",
		]
		try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
			.write(to: contents.appendingPathComponent("Info.plist"))
		return app
	}
}

/// Serves a fixed body for every request.
private final class DMGStub: URLProtocol {
	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
		client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: Data("not really a disk image".utf8))
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}
}
