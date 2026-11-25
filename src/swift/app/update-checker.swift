import AppKit
import UserNotifications

/// A published release, as served by the update feed (`Constants.updateFeedURL`, e.g. website/public/latest.json).
struct Release: Decodable, Equatable {
	let version: String
	/// Monotonic build number (CFBundleVersion); the only thing compared.
	let build: Int
	/// The DMG.
	let url: URL
	/// Hex SHA-256 of the DMG: an update is only installed when the download matches it.
	var sha256: String? = nil
	let minimumSystemVersion: String?
	let notes: String?

	/// Whether this release should be offered to an app at `currentBuild` on macOS `systemVersion`.
	func isUpdate(currentBuild: Int, systemVersion: OperatingSystemVersion) -> Bool {
		guard build > currentBuild else { return false }
		guard let minimumSystemVersion else { return true }
		let minimum = minimumSystemVersion.split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0]
		let system = [systemVersion.majorVersion, systemVersion.minorVersion, systemVersion.patchVersion]
		return !system.lexicographicallyPrecedes(minimum.prefix(3))
	}
}

/// Keeps Bol up to date. Checks the feed at launch, every few hours and on request. A newer release is
/// downloaded and checked in the background (see `UpdateInstaller`), then installed in place and relaunched
/// once Bol is idle (or right away from "Restart to Update"). When Bol can't update itself (a dev build, or a
/// folder it can't write to), it falls back to a notification and the menu item that open the DMG.
final class UpdateChecker: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
	enum Status: Equatable {
		case idle
		case checking
		case upToDate
		case downloading
		/// Downloaded and checked; installs when Bol is idle, or from "Restart to Update".
		case ready
		case installing
		/// Can't update itself; the release is offered as a download instead.
		case manual(String)
	}

	/// The app's own updater (the tests make their own, which only check and notify).
	static let shared = UpdateChecker(installsUpdates: true)

	/// The newer release, once one is found.
	@Published private(set) var available: Release?
	@Published private(set) var status = Status.idle
	var onChange: (() -> Void)?
	/// Whether Bol is quiet enough to restart: nothing listening, working or open (set by the app).
	var isIdle: () -> Bool = { false }
	/// Settings → General → Install updates automatically.
	var isAutomatic: () -> Bool = { true }
	/// Shows a short message in the voice bar (set by the app).
	var announce: (_ title: String, _ detail: String) -> Void = { _, _ in }

	/// nil when this build has no update feed: nothing is ever checked or downloaded.
	private let feedURL: URL?
	private let session: URLSession
	private let currentBuild: Int?
	private let defaults: UserDefaults
	private let installsUpdates: Bool
	/// Shows the notification; the default posts a macOS notification (tests pass their own).
	private let present: (Release) async -> Bool
	private var timer: Timer?
	private var installTimer: Timer?
	private var staged: URL?
	/// Consecutive minutes Bol has been idle with an update ready.
	private var idleMinutes = 0
	private static let notifiedBuildKey = "BolNotifiedUpdateBuild"
	private static let updatedFromKey = "BolUpdatedFromVersion"
	/// Dev-only override, to try updates against a local feed: `defaults write com.snktcodes.bol BolUpdateFeedURL <url>`.
	static let feedOverrideKey = "BolUpdateFeedURL"
	fileprivate static let notificationCategory = "update"

	/// Whether this build checks for updates at all (it has a feed).
	var isEnabled: Bool { feedURL != nil }

	static var currentVersion: String {
		Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
	}

	init(
		feedURL: URL? = nil, session: URLSession = .shared,
		currentBuild: Int? = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String).flatMap { Int($0) },
		defaults: UserDefaults = .standard, installsUpdates: Bool = false, present: ((Release) async -> Bool)? = nil
	) {
		self.feedURL =
			feedURL ?? defaults.string(forKey: Self.feedOverrideKey).flatMap { URL(string: $0) }
			?? Constants.updateFeedURL
		self.session = session
		self.currentBuild = currentBuild
		self.defaults = defaults
		self.installsUpdates = installsUpdates
		self.present = present ?? UpdateChecker.postNotification
		super.init()
	}

	func start() {
		// Unbundled runs (swift run, tests) have no build number to compare.
		guard isEnabled, currentBuild != nil, Bundle.main.bundleIdentifier != nil else { return }
		UNUserNotificationCenter.current().delegate = self
		announceFinishedUpdate()
		let timer = Timer(timeInterval: Constants.updateCheckSeconds, repeats: true) { [weak self] _ in
			Task { await self?.check() }
		}
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
		Task {
			try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)  // stay out of the way of launch
			await check()
		}
	}

	/// The menu's and Settings' "Check for Updates": says so when Bol is already current.
	@MainActor func checkNow() {
		Task { @MainActor in await check(isManual: true) }
	}

	/// Debug aid for `--render-settings`: shows an update as ready, without downloading anything.
	func showPreview(release: Release) {
		available = release
		status = .ready
	}

	func openDownload() {
		guard let available else { return }
		NSWorkspace.shared.open(available.url)
	}

	/// Reads the feed once: updates `available` (calling `onChange` when it changes), then gets a newer
	/// release ready to install, or notifies about it once when Bol can't update itself.
	@MainActor func check(isManual: Bool = false) async {
		guard let currentBuild, let feedURL else { return }
		switch status {
		case .checking, .downloading, .installing: return
		case .ready:
			if isManual { announce("Update ready", "Restart Bol to finish updating.") }
			return
		case .idle, .upToDate, .manual: break
		}
		let previous = status
		status = .checking
		var request = URLRequest(url: feedURL)
		request.cachePolicy = .reloadIgnoringLocalCacheData
		request.timeoutInterval = 20
		do {
			let (data, response) = try await session.data(for: request)
			guard (response as? HTTPURLResponse)?.statusCode == 200 else {
				status = previous
				if isManual {
					announce("Couldn't check for updates", "The update server didn't answer. Try again later.")
				}
				return
			}
			let release = try JSONDecoder().decode(Release.self, from: data)
			let update =
				release.isUpdate(
					currentBuild: currentBuild, systemVersion: ProcessInfo.processInfo.operatingSystemVersion)
				? release : nil
			guard let update else {
				status = .upToDate
				if available != nil {
					available = nil
					onChange?()
				}
				if isManual { announce("Bol is up to date", "Version \(Self.currentVersion)") }
				return
			}
			if update != available {
				available = update
				onChange?()
			}
			await prepare(release: update)
		} catch {
			status = previous
			Log.info(message: "update check failed: \(error.localizedDescription)")
			if isManual { announce("Couldn't check for updates", error.localizedDescription) }
		}
	}

	/// Downloads and checks the release so it can be installed; otherwise offers it as a download.
	@MainActor private func prepare(release: Release) async {
		guard installsUpdates else {
			status = .manual("Download it by hand.")
			await notify(release: release)
			return
		}
		let current: URL
		switch UpdateInstaller.installableLocation() {
		case .success(let url): current = url
		case .failure(let failure):
			status = .manual(failure.localizedDescription)
			await notify(release: release)
			onChange?()
			return
		}
		status = .downloading
		onChange?()
		do {
			let dmg = try await UpdateInstaller.download(release: release, session: session)
			staged = try await UpdateInstaller.stage(dmg: dmg, release: release, replacing: current)
			status = .ready
			Log.info(message: "update: \(release.version) (\(release.build)) ready to install")
			scheduleInstall()
		} catch {
			Log.info(message: "update: \(release.version) not installable: \(error.localizedDescription)")
			status = .manual(error.localizedDescription)
			await notify(release: release)
		}
		onChange?()
	}

	/// Installs once Bol has been idle for two minutes in a row (checked every minute), when automatic.
	private func scheduleInstall() {
		installTimer?.invalidate()
		idleMinutes = 0
		let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
			guard let self, self.status == .ready, self.isAutomatic() else { return }
			self.idleMinutes = self.isIdle() ? self.idleMinutes + 1 : 0
			if self.idleMinutes >= 2 { self.install() }
		}
		RunLoop.main.add(timer, forMode: .common)
		installTimer = timer
	}

	/// Swaps the new version in and relaunches. From the menu's "Restart to Update", or when idle.
	func install() {
		guard status == .ready, let staged, let available else { return }
		status = .installing
		onChange?()
		let current = Bundle.main.bundleURL
		do {
			try UpdateInstaller.install(staged: staged, replacing: current)
			defaults.set(Self.currentVersion, forKey: Self.updatedFromKey)
			Log.info(message: "update: installed \(available.version), relaunching")
			UpdateInstaller.relaunch(app: current)
			NSApp.terminate(nil)
		} catch {
			Log.info(message: "update: install failed: \(error.localizedDescription)")
			status = .manual("Couldn't replace the app: \(error.localizedDescription)")
			onChange?()
			announce("Couldn't install the update", "Download it by hand instead.")
		}
	}

	/// After a relaunch into a new version: say so once.
	private func announceFinishedUpdate() {
		guard let from = defaults.string(forKey: Self.updatedFromKey) else { return }
		defaults.removeObject(forKey: Self.updatedFromKey)
		guard from != Self.currentVersion else { return }
		Log.info(message: "update: now on \(Self.currentVersion) (from \(from))")
		DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
			self?.announce("Bol updated", "Now on version \(Self.currentVersion).")
		}
	}

	@MainActor private func notify(release: Release) async {
		guard defaults.integer(forKey: Self.notifiedBuildKey) < release.build else { return }
		guard await present(release) else { return }
		defaults.set(release.build, forKey: Self.notifiedBuildKey)
		Log.info(message: "update available: \(release.version) (\(release.build))")
	}

	/// Asks for notification permission only now that there's something to say.
	private static func postNotification(release: Release) async -> Bool {
		let center = UNUserNotificationCenter.current()
		guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
		let content = UNMutableNotificationContent()
		content.title = "Bol \(release.version) is available"
		content.body = release.notes.map { "\($0) Click to download." } ?? "Click to download the update."
		content.categoryIdentifier = notificationCategory
		let request = UNNotificationRequest(identifier: "update-\(release.build)", content: content, trigger: nil)
		do {
			try await center.add(request)
			return true
		} catch {
			Log.info(message: "update notification failed: \(error.localizedDescription)")
			return false
		}
	}

	func userNotificationCenter(
		_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
		withCompletionHandler completionHandler: @escaping () -> Void
	) {
		if response.notification.request.content.categoryIdentifier == Self.notificationCategory {
			DispatchQueue.main.async { self.openDownload() }
		}
		completionHandler()
	}

	/// Show the banner even though Bol (a menu bar app) counts as frontmost while its menu or windows are open.
	func userNotificationCenter(
		_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
		withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
	) {
		completionHandler([.banner, .sound])
	}
}
