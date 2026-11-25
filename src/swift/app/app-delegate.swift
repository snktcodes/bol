import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
	/// Everything that exists once the app has launched.
	private struct Session {
		let statusItem: NSStatusItem
		let controller: Controller
		let settings: SettingsWindowController
		let threads: ThreadsWindowController
		let onboarding: OnboardingWindowController
		let icon: MenuBarIcon
	}

	private var session: Session?
	/// Registered once the assistant starts (after setup), re-registered when Settings changes them.
	private lazy var shortcuts = GlobalShortcuts { [weak self] action in self?.shortcutPressed(action: action) }
	/// Why the assistant hasn't started yet (or that it has).
	private var readiness = Readiness.checking

	private enum Readiness {
		/// Checking Claude Code at launch.
		case checking
		/// First-run setup isn't finished.
		case setupUnfinished
		/// Setup was done once, but Claude Code is now missing or signed out.
		case claudeCodeNotReady
		case started
	}
	private var isMenuOpen = false
	private let updates = UpdateChecker.shared

	func applicationDidFinishLaunching(_ notification: Notification) {
		let config = Config.load()
		let controller = Controller(config: config)
		NSApp.mainMenu = MainMenu.make(settingsAction: #selector(openSettings), target: self)

		let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		let icon = MenuBarIcon(button: statusItem.button) { [weak controller] in controller?.audio.level ?? 0 }
		let menu = NSMenu()
		menu.delegate = self
		menu.autoenablesItems = false
		statusItem.menu = menu

		let model = SettingsModel(config: config, isPersisting: true)
		model.dictations = controller.dictations
		model.onChange = { [weak self, weak controller] config in
			controller?.reloadConfig(config: config)
			self?.applyShortcuts(config: config)
		}
		model.onPlaySample = { [weak controller] text, onEvent, completion in
			controller?.testVoice(text: text, onEvent: onEvent, completion: completion) ?? false
		}
		model.onStopSample = { [weak controller] in controller?.stopTestVoice() }
		model.onRestartBrain = { [weak controller] in controller?.brain.restart() }
		// When Claude Code becomes usable from the Assistant tab, (re)start the brain right away.
		model.onEngineReady = { [weak controller] in controller?.brain.restart() }
		model.onNewConversation = { [weak controller] in controller?.newConversation() }
		model.onRunSetup = { [weak self] in self?.showOnboarding(step: .welcome) }
		controller.onBrainState = { [weak model] state in model?.brainState = state }
		controller.onMCPStatus = { [weak model] report in model?.mcpReport = report }
		model.onRequestMCPStatus = { [weak controller] in controller?.brain.requestMCPStatus() }
		model.onSignIn = { [weak controller] name in controller?.brain.signIn(server: name) }
		controller.onSkills = { [weak model] skills in model?.skills = skills }
		controller.onMCPSignIn = { [weak model] name, isWaiting in
			if isWaiting { model?.signingIn.insert(name) } else { model?.signingIn.remove(name) }
		}

		let onboarding = OnboardingWindowController(model: OnboardingModel(settings: model))
		onboarding.model.onFinish = { [weak self] in self?.onboardingFinished() }

		let settings = SettingsWindowController(model: model)
		let threads = ThreadsWindowController(
			actions: ThreadsActions(
				talk: { [weak controller] in controller?.talkNow() },
				continueThread: { [weak controller] id in controller?.continueConversation(sessionId: id) },
				messageTask: { [weak controller] id, text in controller?.message(task: id, text: text) },
				forgetThread: { [weak controller] id in controller?.brain.forget(thread: id) },
				openSettings: { [weak settings] in settings?.show() }))
		let session = Session(
			statusItem: statusItem, controller: controller, settings: settings, threads: threads,
			onboarding: onboarding, icon: icon)
		ThreadStore.keepThreads()
		self.session = session
		applyShortcuts(config: config)

		controller.onStateChange = { [weak self] in self?.controllerChanged() }
		updates.onChange = { [weak self] in self?.controllerChanged() }
		updates.isAutomatic = { [weak model] in model?.config.isAutoUpdateEnabled ?? true }
		updates.isIdle = { [weak self, weak controller] in
			guard let self, let controller, !self.isMenuOpen else { return false }
			// Nothing listening, thinking, speaking or running in the background, and no Bol window open.
			let hasOpenWindow = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
			return controller.state == .idle && controller.tasks.isEmpty && !controller.isWorkingInBackground
				&& !hasOpenWindow
		}
		updates.announce = { [weak controller] title, detail in
			controller?.hud.notice(title: title, detail: detail, icon: "arrow.down.circle", hideAfter: 4)
		}
		updates.start()
		if UserDefaults.standard.bool(forKey: Constants.devHooksDefaultsKey) { installDevHooks(controller: controller) }
		if config.hasCompletedOnboarding, config.hasAcceptedCurrentTerms {
			startAssistantIfReady()
		} else {
			// Set up before, but these Terms (new, or changed since) aren't agreed to yet: just that step.
			readiness = .setupUnfinished
			showOnboarding(step: config.hasCompletedOnboarding ? .terms : .welcome)
		}
		if CommandLine.arguments.contains("--settings") { session.settings.show() }
		if CommandLine.arguments.contains("--threads") { session.threads.show() }
	}

	/// Mic, brain and the global shortcuts. Runs once setup has verified what they need.
	private func startAssistant() {
		guard let session else { return }
		readiness = .started
		session.controller.start()
		applyShortcuts(config: session.settings.model.config)
		MainActor.assumeIsolated { startHealthChecks(session: session) }
	}

	/// Checks Claude Code, the sign-in, listening and plan usage now and while anything is down. A newly failing
	/// essential check is said once in the voice bar; the menu keeps showing it until it's fixed.
	@MainActor private func startHealthChecks(session: Session) {
		let health = ServiceHealth.shared
		health.currentConfig = { [weak session = session.settings.model] in session?.config ?? Config.load() }
		health.onNewProblem = { [weak self] item, problem in
			guard let self, let session = self.session else { return }
			Log.info(message: "health: \(item.rawValue): \(problem.title)")
			if session.controller.state == .idle {
				session.controller.hud.error(title: problem.title, detail: problem.detail)
			}
			self.controllerChanged()
		}
		health.run(config: session.settings.model.config)
	}

	/// Shown everywhere right away; registered only once the assistant has started.
	private func applyShortcuts(config: Config) {
		shortcuts.apply(config: config, isActive: readiness == .started)
		let talk = config.shortcuts.talk.map { " · \($0.plainText) to talk" } ?? ""
		session?.statusItem.button?.toolTip = "Bol" + talk
	}

	private func shortcutPressed(action: ShortcutAction) {
		guard let session else { return }
		switch action {
		case .talk: session.controller.talkNow()
		case .pasteLastDictation: session.controller.pasteLastDictation()
		case .openBol: Task { @MainActor in session.threads.show() }
		case .newConversation: session.controller.newConversation()
		}
	}

	/// Claude Code missing or signed out blocks the assistant: setup reopens at the failing step.
	private func startAssistantIfReady() {
		Task { @MainActor [weak self] in
			let status = await EngineStatus.check()
			if status.isReady {
				self?.startAssistant()
			} else {
				Log.info(message: "launch: Claude Code not ready (installed: \(status.isInstalled)), reopening setup")
				self?.readiness = .claudeCodeNotReady
				self?.showOnboarding(step: status.isInstalled ? .account : .claudeCode)
				await self?.startWhenClaudeCodeReady()
			}
		}
	}

	/// Fixed from Settings or Terminal instead of setup: start as soon as Claude Code is ready. Each check
	/// launches `claude` and `security`, so it checks every 3 s for two minutes (while the user is likely
	/// fixing it), then every 30 s.
	@MainActor private func startWhenClaudeCodeReady() async {
		let startedAt = Date()
		while readiness == .claudeCodeNotReady {
			let seconds: UInt64 = -startedAt.timeIntervalSinceNow < 120 ? 3 : 30
			try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
			guard readiness == .claudeCodeNotReady else { return }  // setup finished meanwhile
			if await EngineStatus.check().isReady {
				Log.info(message: "launch: Claude Code ready, starting")
				session?.onboarding.close()
				startAssistant()
			}
		}
	}

	private func showOnboarding(step: OnboardingStep) {
		guard let session else { return }
		session.onboarding.model.step = step
		if step == .account { session.onboarding.model.checkClaudeCode() }  // mark the step before it done
		session.onboarding.show()
	}

	private func onboardingFinished() {
		guard let session else { return }
		session.onboarding.close()
		startAssistant()
		session.controller.hud.notice(
			title: "Bol is ready", detail: "Press \(ShortcutState.shared.talkText) anywhere to talk", icon: "waveform",
			hideAfter: 3)
	}

	/// Clicking the Dock icon (shown while a window is open) brings back the right window.
	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
		guard let session, !hasVisibleWindows else { return true }
		if session.settings.model.config.hasCompletedOnboarding {
			session.threads.show()
		} else {
			session.onboarding.show()
		}
		return true
	}

	func applicationWillTerminate(_ notification: Notification) {
		session?.controller.brain.stop()
	}

	private func controllerChanged() {
		guard let session else { return }
		session.icon.update(state: session.controller.state)
		if let menu = session.statusItem.menu, menu.highlightedItem != nil || isMenuOpen { rebuild(menu: menu) }
	}

	/// Dev-only (defaults BolDevHooks): demo recordings and visual checks of the voice bar.
	private func installDevHooks(controller: Controller) {
		let center = DistributedNotificationCenter.default()
		center.addObserver(forName: Constants.sayNotification, object: nil, queue: .main) { [weak controller] note in
			guard let text = note.userInfo?["text"] as? String else { return }
			controller?.inject(text: text, isInstant: note.userInfo?["instant"] as? Bool ?? false)
		}
		// Scripted tests drive the menu actions and read the state from the log, no clicking needed.
		center.addObserver(forName: Constants.actionNotification, object: nil, queue: .main) { [weak controller] note in
			guard let controller else { return }
			switch note.userInfo?["action"] as? String {
			case "stop": controller.stopEverything()
			case "newConversation": controller.newConversation()
			case "sendToBackground": controller.sendToBackground()
			case "stopBackground": controller.stopTasks()
			case "state": Log.info(message: "dev state: \(controller.debugDescription)")
			case "requestAccessibility": MacPermission.accessibility.request()
			case "requestScreenRecording": MacPermission.screenRecording.request()
			case "requestSystemAudio": MacPermission.systemAudio.request()
			case "permissions":
				let granted = MacPermission.allCases.filter(\.isGranted).map(\.rawValue).joined(separator: ", ")
				Log.info(message: "dev permissions granted: \(granted)")
			default: Log.info(message: "dev: unknown action \(note.userInfo ?? [:])")
			}
		}
		// Show the voice bar in a phase for a few seconds: {phase, text, seconds[, context, activity, status]}.
		center.addObserver(forName: Constants.previewHUDNotification, object: nil, queue: .main) {
			[weak controller] note in
			guard let controller else { return }
			switch controller.state {
			case .idle, .starting: break
			case .listening, .thinking, .speaking: return  // never clobber a real session
			}
			let info = note.userInfo ?? [:]
			let seconds = (info["seconds"] as? NSNumber)?.doubleValue ?? Double(info["seconds"] as? String ?? "") ?? 4
			controller.hud.preview(
				phase: (info["phase"] as? String).flatMap(HUDPhase.init(rawValue:)) ?? .listening,
				text: info["text"] as? String ?? "",
				context: info["context"] as? String ?? "",
				step: info["activity"] as? String ?? "",
				status: (info["status"] as? String).flatMap { $0.isEmpty ? nil : $0 },
				seconds: max(0.5, min(seconds, 60)))
		}
	}

	// MARK: Menu

	func menuWillOpen(_ menu: NSMenu) {
		isMenuOpen = true
		rebuild(menu: menu)
	}

	func menuDidClose(_ menu: NSMenu) { isMenuOpen = false }

	private func rebuild(menu: NSMenu) {
		guard let session else { return }
		menu.removeAllItems()
		let controller = session.controller
		let config = session.settings.model.config

		// Status header
		let (title, detail, color): (String, String, Color)
		switch controller.state {
		case .starting:
			switch readiness {
			case .checking, .started: (title, detail, color) = ("Starting…", "Connecting to Claude Code", .secondary)
			case .setupUnfinished:
				(title, detail, color) = ("Setup not finished", "Finish setup to start talking to Bol", .orange)
			case .claudeCodeNotReady:
				(title, detail, color) = ("Claude Code isn't ready", "Sign in again to start talking to Bol", .orange)
			}
		case .idle where controller.isWorkingInBackground || !controller.tasks.isEmpty:
			let count = controller.tasks.count
			(title, detail, color) = (
				"Ready · working in the background",
				count == 0 ? "Bol will come back when it's done" : "\(count) task\(count == 1 ? "" : "s") running",
				.green
			)
		case .idle:
			(title, detail, color) =
				config.isSilentMode
				? ("Ready · Silent", "Replies appear on screen, not spoken", .green)
				: ("Ready", "Press \(ShortcutState.shared.talkText) anywhere to talk", .green)
		case .listening(.dictation):
			(title, detail, color) = ("Dictating…", "Pasted where you're typing when it ends", .blue)
		case .listening: (title, detail, color) = ("Listening…", "Press Enter to send, Esc to cancel", .blue)
		case .thinking:
			(title, detail, color) = (
				"Working…", controller.activity.isEmpty ? "Thinking" : controller.activity, .purple
			)
		case .speaking: (title, detail, color) = ("Speaking…", "Press Esc to stop", .teal)
		}
		switch readiness {
		case .setupUnfinished, .claudeCodeNotReady:
			menu.addItem(item(title: "Finish Setting Up Bol…", action: #selector(openOnboarding), symbol: "checklist"))
			menu.addItem(.separator())
		case .checking, .started:
			break
		}
		if let (_, problem) = MainActor.assumeIsolated({ ServiceHealth.shared.essentialProblem }) {
			let attention = item(
				title: problem.title + "…", action: #selector(openHealth), symbol: "exclamationmark.triangle")
			attention.toolTip = problem.detail
			menu.addItem(attention)
			menu.addItem(.separator())
		}
		if let release = updates.available {
			let update: NSMenuItem
			switch updates.status {
			case .ready:
				update = item(
					title: "Restart to Update to \(release.version)", action: #selector(installUpdate),
					symbol: "arrow.down.circle")
			case .downloading, .checking:
				update = item(title: "Downloading Bol \(release.version)…", action: nil, symbol: "arrow.down.circle")
				update.isEnabled = false
			case .installing:
				update = item(title: "Updating Bol…", action: nil, symbol: "arrow.down.circle")
				update.isEnabled = false
			case .manual, .idle, .upToDate:
				update = item(
					title: "Download Bol \(release.version)…", action: #selector(downloadUpdate),
					symbol: "arrow.down.circle")
			}
			update.toolTip = release.notes
			menu.addItem(update)
			menu.addItem(.separator())
		}
		let header = NSMenuItem()
		let host = NSHostingView(rootView: MenuHeader(title: title, detail: detail, color: color))
		host.frame = NSRect(x: 0, y: 0, width: 280, height: detail.isEmpty ? 34 : 44)
		header.view = host
		menu.addItem(header)
		menu.addItem(.separator())

		// Primary action adapts to the state
		let (primaryTitle, primarySymbol): (String, String)
		switch controller.state {
		case .listening(.dictation): (primaryTitle, primarySymbol) = ("Talk to Bol Instead", "mic")
		case .listening: (primaryTitle, primarySymbol) = ("Send Now", "arrow.up.circle")
		case .speaking: (primaryTitle, primarySymbol) = ("Interrupt and Talk", "mic")
		case .thinking: (primaryTitle, primarySymbol) = ("Add to Current Task", "plus.bubble")
		case .starting, .idle: (primaryTitle, primarySymbol) = ("Talk to Bol", "mic")
		}
		let primary = item(
			title: primaryTitle, action: #selector(talkNow), shortcut: config.shortcuts.talk, symbol: primarySymbol)
		primary.isEnabled = controller.state != .starting
		menu.addItem(primary)

		let stop = item(title: "Stop", action: #selector(stop), symbol: "stop.circle")
		switch controller.state {
		case .listening, .thinking, .speaking: stop.isEnabled = true
		case .starting, .idle: stop.isEnabled = false
		}
		menu.addItem(stop)
		if controller.canSendToBackground {
			let background = item(
				title: "Send to Background", action: #selector(sendToBackground), symbol: "tray.and.arrow.down")
			background.toolTip = "Keep working on this while you do something else. Or say “send it to the background”."
			menu.addItem(background)
		}

		// Work going on out of sight: the thread, and the tasks it started
		if controller.isWorkingInBackground || !controller.tasks.isEmpty {
			menu.addItem(.separator())
			if #available(macOS 14.0, *) { menu.addItem(NSMenuItem.sectionHeader(title: "Working on")) }
			if controller.isWorkingInBackground {
				let thread = item(
					title: truncated(text: controller.activity.isEmpty ? controller.lastPrompt : controller.activity),
					action: #selector(openThreads), symbol: "bubble.left")
				thread.toolTip = controller.lastPrompt
				menu.addItem(thread)
			}
			for (_, name) in controller.tasks {
				let task = item(title: truncated(text: name), action: #selector(openThreads), symbol: "hourglass")
				task.toolTip = "Task: \(name). Open Bol to see it or message it."
				menu.addItem(task)
			}
			if !controller.tasks.isEmpty {
				let count = controller.tasks.count
				menu.addItem(
					item(
						title: count == 1 ? "Stop Task" : "Stop \(count) Tasks", action: #selector(stopTasks),
						symbol: "stop.circle"))
			}
		}

		let newConversation = item(
			title: "New Conversation", action: #selector(newConversation), shortcut: config.shortcuts.newConversation,
			symbol: "square.and.pencil")
		newConversation.isEnabled = controller.state != .starting  // the brain only runs once Bol has started
		menu.addItem(newConversation)
		let silent = item(
			title: "Silent Mode", action: #selector(toggleSilent),
			symbol: config.isSilentMode ? "speaker.slash" : "speaker.wave.2")
		silent.state = config.isSilentMode ? .on : .off
		silent.toolTip = "Show replies without speaking them"
		menu.addItem(silent)

		// Quick switches
		menu.addItem(.separator())
		let voice = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
		voice.image = symbolImage(name: "speaker.wave.2")
		let voiceMenu = NSMenu()
		for provider in TextToSpeechProviders.all {
			let hasCredential = provider.credential.isSatisfied(by: config)
			let entry = item(
				title: provider.title + (hasCredential ? "" : " (no key)"), action: #selector(pickVoice(_:)))
			entry.representedObject = provider.id.rawValue
			entry.state = config.textToSpeech.provider == provider.id ? .on : .off
			entry.isEnabled = hasCredential
			voiceMenu.addItem(entry)
		}
		voice.submenu = voiceMenu
		menu.addItem(voice)

		let model = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
		model.image = symbolImage(name: "sparkle")
		let modelMenu = NSMenu()
		for option in ClaudeModel.allCases {
			let entry = item(title: option.title, action: #selector(pickModel(_:)))
			entry.representedObject = option.rawValue
			entry.state = config.claudeModel == option ? .on : .off
			modelMenu.addItem(entry)
		}
		model.submenu = modelMenu
		menu.addItem(model)

		menu.addItem(.separator())
		if config.dictation.isEnabled {
			let pasteLast = item(
				title: "Paste Last Dictation", action: #selector(pasteLastDictation),
				shortcut: config.shortcuts.pasteLastDictation, symbol: "doc.on.clipboard")
			pasteLast.isEnabled = controller.dictations.last != nil
			pasteLast.toolTip = controller.dictations.last?.text
			menu.addItem(pasteLast)
		}
		// ⌘T while the menu is open, unless a shortcut that works anywhere was set for it.
		let openBol = item(
			title: "Open Bol…", action: #selector(openThreads), key: "t", symbol: "bubble.left.and.text.bubble.right")
		if let shortcut = config.shortcuts.openBol { apply(shortcut: shortcut, item: openBol) }
		menu.addItem(openBol)
		if updates.isEnabled {
			menu.addItem(
				item(
					title: "Check for Updates…", action: #selector(checkForUpdates),
					symbol: "arrow.triangle.2.circlepath")
			)
		}
		menu.addItem(item(title: "Settings…", action: #selector(openSettings), key: ",", symbol: "gearshape"))
		menu.addItem(item(title: "Quit Bol", action: #selector(quit), key: "q", symbol: "power"))
	}

	private func truncated(text: String, limit: Int = 46) -> String {
		let line = text.replacingOccurrences(of: "\n", with: " ")
		return line.count > limit ? String(line.prefix(limit)) + "…" : line
	}

	private func symbolImage(name: String) -> NSImage? {
		let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
		image?.isTemplate = true
		return image
	}

	private func item(
		title: String, action: Selector?, key: String = "", shortcut: Shortcut? = nil, symbol: String? = nil
	) -> NSMenuItem {
		let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
		item.target = self
		if let shortcut { apply(shortcut: shortcut, item: item) }
		if let symbol { item.image = symbolImage(name: symbol) }
		return item
	}

	/// Shows a configured shortcut next to its menu item (keys a menu can't show are left off).
	private func apply(shortcut: Shortcut, item: NSMenuItem) {
		guard let key = shortcut.menuKeyEquivalent else { return }
		item.keyEquivalent = key
		item.keyEquivalentModifierMask = shortcut.menuModifierMask
	}

	@objc private func talkNow() { session?.controller.talkNow() }
	@objc private func stop() { session?.controller.stopEverything() }
	@objc private func newConversation() { session?.controller.newConversation() }
	@objc private func sendToBackground() { session?.controller.sendToBackground() }
	@objc private func stopTasks() { session?.controller.stopTasks() }
	@objc private func pasteLastDictation() { session?.controller.pasteLastDictation() }

	// Switches go through the settings model, so the window, config and controller stay in sync.
	@objc private func toggleSilent() {
		session?.settings.model.config.isSilentMode.toggle()
	}

	@objc private func pickVoice(_ sender: NSMenuItem) {
		guard let raw = sender.representedObject as? String, let id = TextToSpeechProviderID(rawValue: raw) else {
			return
		}
		session?.settings.model.config.textToSpeech.provider = id
	}

	@objc private func pickModel(_ sender: NSMenuItem) {
		guard let id = sender.representedObject as? String, let model = ClaudeModel(rawValue: id) else { return }
		session?.settings.model.config.claudeModel = model
	}

	@objc private func openSettings() { session?.settings.show() }

	@MainActor @objc private func openThreads() { session?.threads.show() }

	@objc private func openOnboarding() {
		let config = session?.settings.model.config
		showOnboarding(
			step: config?.hasCompletedOnboarding == true && config?.hasAcceptedCurrentTerms == false ? .terms : .welcome
		)
	}

	@objc private func downloadUpdate() { updates.openDownload() }

	@objc private func installUpdate() { updates.install() }

	@MainActor @objc private func checkForUpdates() { updates.checkNow() }

	@MainActor @objc private func openHealth() {
		UserDefaults.standard.set(Pane.assistant.rawValue, forKey: "settingsPane")
		session?.settings.show()
		ServiceHealth.shared.run(config: session?.settings.model.config ?? Config.load())
	}

	@objc private func quit() { NSApp.terminate(nil) }
}
