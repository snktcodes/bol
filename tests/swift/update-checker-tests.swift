import Foundation
import Testing

@testable import Bol

@Suite(.serialized) struct UpdateCheckerTests {
	private let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)

	private func release(build: Int, minimum: String? = nil) -> Release {
		Release(
			version: "0.2.0", build: build, url: URL(string: "https://downloads.example.com/Bol-0.2.0.dmg")!,
			minimumSystemVersion: minimum, notes: nil)
	}

	@Test func offersOnlyHigherBuilds() {
		#expect(release(build: 2).isUpdate(currentBuild: 1, systemVersion: sonoma))
		#expect(!release(build: 1).isUpdate(currentBuild: 1, systemVersion: sonoma))
		#expect(!release(build: 1).isUpdate(currentBuild: 2, systemVersion: sonoma))
	}

	@Test func skipsReleasesThisMacCannotRun() {
		#expect(release(build: 2, minimum: "13.0").isUpdate(currentBuild: 1, systemVersion: sonoma))
		#expect(release(build: 2, minimum: "14.5").isUpdate(currentBuild: 1, systemVersion: sonoma))
		#expect(!release(build: 2, minimum: "14.6").isUpdate(currentBuild: 1, systemVersion: sonoma))
		#expect(!release(build: 2, minimum: "15").isUpdate(currentBuild: 1, systemVersion: sonoma))
	}

	@Test func decodesTheFeed() throws {
		let json = """
			{"version":"0.1.0","build":1,"url":"https://downloads.example.com/Bol-0.1.0.dmg","sha256":"",
			"minimumSystemVersion":"13.0","releasedAt":"2026-11-25T00:00:00Z","notes":"First public release."}
			"""
		let release = try JSONDecoder().decode(Release.self, from: Data(json.utf8))
		#expect(release.build == 1 && release.minimumSystemVersion == "13.0")
	}

	@Test @MainActor func withoutAFeedNothingIsChecked() async {
		#expect(Constants.updateFeedURL == nil)
		let defaults = UserDefaults(suiteName: "bol-update-tests-\(UUID().uuidString)")!
		// The stub would offer build 2 if the checker asked anyone.
		FeedStub.respond(status: 200, body: Self.feedV2)
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [FeedStub.self]
		let checker = UpdateChecker(
			session: URLSession(configuration: configuration), currentBuild: 1, defaults: defaults)
		#expect(!checker.isEnabled)
		await checker.check(isManual: true)
		#expect(checker.available == nil && checker.status == .idle)
	}

	// MARK: The whole check, against a stubbed feed

	private func checker(feed: String, status: Int = 200, currentBuild: Int = 1, presented: Recorder)
		-> (UpdateChecker, UserDefaults)
	{
		FeedStub.respond(status: status, body: feed)
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [FeedStub.self]
		let defaults = UserDefaults(suiteName: "bol-update-tests-\(UUID().uuidString)")!
		let checker = UpdateChecker(
			feedURL: URL(string: "https://feed.test/latest.json")!, session: URLSession(configuration: configuration),
			currentBuild: currentBuild, defaults: defaults,
			present: { release in
				await presented.add(build: release.build)
				return true
			})
		return (checker, defaults)
	}

	private static let feedV2 = """
		{"version":"0.2.0","build":2,"url":"https://downloads.example.com/Bol-0.2.0.dmg","minimumSystemVersion":"13.0","notes":"Faster."}
		"""

	@Test @MainActor func findsANewerReleaseAndNotifiesOnce() async {
		let presented = Recorder()
		let (checker, _) = checker(feed: Self.feedV2, presented: presented)
		var changes = 0
		checker.onChange = { changes += 1 }
		await checker.check()
		#expect(checker.available?.version == "0.2.0")
		#expect(changes == 1)
		await checker.check()  // the next poll: same release, no second notification
		#expect(changes == 1)
		#expect(await presented.builds == [2])
	}

	@Test @MainActor func staysQuietWhenUpToDate() async {
		let presented = Recorder()
		let (checker, _) = checker(feed: Self.feedV2, currentBuild: 2, presented: presented)
		await checker.check()
		#expect(checker.available == nil)
		#expect(await presented.builds.isEmpty)
	}

	@Test @MainActor func ignoresBrokenFeeds() async {
		let presented = Recorder()
		let (missing, _) = checker(feed: "not found", status: 404, presented: presented)
		await missing.check()
		#expect(missing.available == nil)
		let (garbled, _) = checker(feed: "{\"version\":", presented: presented)
		await garbled.check()
		#expect(garbled.available == nil)
		#expect(await presented.builds.isEmpty)
	}

	@Test @MainActor func remembersWhatItAlreadyAnnounced() async {
		let presented = Recorder()
		let (first, defaults) = checker(feed: Self.feedV2, presented: presented)
		await first.check()
		// A relaunch (new checker, same defaults) offers the update in the menu but doesn't notify again.
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [FeedStub.self]
		let relaunched = UpdateChecker(
			feedURL: URL(string: "https://feed.test/latest.json")!, session: URLSession(configuration: configuration),
			currentBuild: 1, defaults: defaults,
			present: { release in
				await presented.add(build: release.build)
				return true
			})
		await relaunched.check()
		#expect(relaunched.available?.build == 2)
		#expect(await presented.builds == [2])
	}
}

/// Collects what the checker would have notified about.
private actor Recorder {
	private(set) var builds: [Int] = []
	func add(build: Int) { builds.append(build) }
}

/// Serves one canned response for every request.
private final class FeedStub: URLProtocol {
	private static let lock = NSLock()
	nonisolated(unsafe) private static var response: (status: Int, body: Data) = (200, Data())

	static func respond(status: Int, body: String) {
		lock.withLock { response = (status, Data(body.utf8)) }
	}

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

	override func startLoading() {
		let (status, body) = Self.lock.withLock { Self.response }
		let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
		client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: body)
		client?.urlProtocolDidFinishLoading(self)
	}

	override func stopLoading() {}
}
