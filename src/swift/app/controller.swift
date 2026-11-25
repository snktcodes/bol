import AVFoundation
import AppKit
import Carbon.HIToolbox

/// The voice loop: ⌘J -> speech-to-text -> Enter -> brain (Agent SDK) -> text-to-speech -> follow-up.
///
/// The microphone is only open while Bol is listening to you; the rest of the time it's released
/// for other apps. Main thread only.
final class Controller {
	enum ListenMode: Equatable {
		/// ⌘J pressed.
		case manual
		/// Right after a reply, no ⌘J needed.
		case followUp
		/// The dictation key: what you say is pasted into `app` (the app in front), not sent to Bol.
		case dictation(app: String?)

		/// What's said goes to Bol (not pasted into an app).
		var isForBol: Bool {
			if case .dictation = self { return false }
			return true
		}
	}

	enum State: Equatable {
		case starting
		case idle
		case listening(ListenMode)
		case thinking
		/// Reading a reply aloud; `then` is what to listen for afterwards.
		case speaking(then: ListenMode?)
	}

	/// What the brain is doing with the last request.
	private enum BrainTask {
		case idle
		case working
		/// Interrupted by the user: the result still on its way is dropped.
		case cancelled
	}

	/// One utterance being captured. Callbacks from an older one are ignored by identity.
	private final class Listening {
		let mode: ListenMode
		let session: SpeechToTextSession
		let startedAt = Date()
		var lastChangeAt = Date()
		var segments: [String] = []
		var interim = ""
		/// Batch transcribers give no live text, so speech is detected from the mic level.
		var hasHeardSpeech = false
		var isFinishing = false
		/// Shown on screen and ducking other apps. A dictation waits a moment first, since a quick
		/// fn shortcut (fn-Delete) is dropped and shouldn't flash the bar or dip the music.
		var isRevealed = true
		var tick: Timer?

		init(mode: ListenMode, session: SpeechToTextSession) {
			self.mode = mode
			self.session = session
		}

		var rawText: String {
			(segments + [interim]).joined(separator: " ")
				.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
				.trimmingCharacters(in: .whitespacesAndNewlines)
		}

		/// The utterance, or "" if it has no actual words.
		var commandText: String {
			let raw = rawText
			let words = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
			return words.isEmpty ? "" : raw
		}
	}

	/// One reply being spoken. Callbacks from an older one are ignored by identity.
	private final class Speech {}

	var config: Config
	let audio = AudioCapture()
	let brain: BrainBridge
	let speaker = Speaker()
	let hud = HUD()
	let computer = ComputerControl()
	let ducker = AudioDucker()
	let dictationKeys = DictationKeyMonitor()
	let dictations = DictationHistory()

	/// Fired on every state or activity change (menu bar icon + menu).
	var onStateChange: (() -> Void)?
	var onBrainState: ((BrainState) -> Void)?
	var onMCPStatus: ((MCPStatusReport) -> Void)?
	var onSkills: (([BrainBridge.Skill]) -> Void)?
	/// An MCP sign-in started (`isWaiting`) or ended, for Settings.
	var onMCPSignIn: ((_ name: String, _ isWaiting: Bool) -> Void)?

	private(set) var state = State.starting {
		didSet {
			if state != oldValue { Log.info(message: "state: \(oldValue) -> \(state)") }
			updateEscKey()
			updateEnterKeys()
			updateMic()
			updateDucking()
			onStateChange?()
			if state == .idle, !deferredBackground.isEmpty {
				DispatchQueue.main.async { [weak self] in self?.showDeferredBackground() }
			}
		}
	}

	/// Something Bol brings back once you're free: a reply or a task's result.
	private enum BackgroundEvent {
		case result(prompt: String, text: String, isError: Bool)
	}
	private(set) var lastReply = ""
	/// The last reply as Claude wrote it (with its paragraphs and lists), for the voice bar.
	private var lastReplyText = ""
	/// Files dropped on the voice bar, sent with the next request.
	private var pendingFiles: [URL] = []
	private(set) var lastPrompt = ""
	/// What the brain is doing right now (latest tool), for the menu.
	private(set) var activity = ""
	/// Tasks the thread started that are still running, oldest first. They never hold the mic.
	private(set) var tasks: [(job: String, name: String)] = []

	/// What the thread is doing with your latest request.
	private var brainTask = BrainTask.idle
	/// You asked Bol to stay with you on this request ("in the foreground"): its work shows in the voice
	/// bar. Otherwise Bol works out of sight and comes back when it's done or has a question.
	private var isThreadShown = false
	/// Numbers each request sent to the brain; an `idle` for an older one is stale.
	private var requestSeq = 0
	/// Background results and questions that arrived mid-conversation, shown once Bol is free.
	private var deferredBackground: [BackgroundEvent] = []
	private var listening: Listening?
	private var speech: Speech?
	private var hasStarted = false
	/// Settings is playing a voice sample: other apps go quiet for it as for a reply.
	private var isPlayingSample = false
	private var escKey: HotKey?
	/// Return and keypad Enter, captured only while Bol listens: they send what you said.
	private var enterKeys: [HotKey] = []

	// Audio fan-out, guarded by audioQueue: a short ring buffer (audio from before speech-to-text
	// connects) and the session currently receiving audio.
	private let audioQueue = DispatchQueue(label: "bol.audio")
	private var ring = Data()
	private let ringCapacity = Int(Constants.micRingBufferSeconds) * Constants.micBytesPerSecond
	private var audioTarget: SpeechToTextSession?

	init(config: Config) {
		self.config = config
		brain = BrainBridge(config: config)
		hud.model.inputLevel = { [weak self] in self?.audio.level ?? 0 }
		hud.model.outputLevel = { [weak self] in self?.speaker.level ?? 0 }
		hud.model.isSilent = config.isSilentMode
		applyDucking(config: config)
		// Esc is captured while the bar is up, so a second Esc can close a reply.
		hud.model.onVisibilityChange = { [weak self] _ in self?.updateEscKey() }
		hud.model.onClose = { [weak self] in self?.closeFromHUD() }
		hud.model.onDrop = { [weak self] urls in self?.attach(files: urls) }
		// The voice bar would cover what's under it, and invite clicks on itself.
		computer.onCapturing = { [weak self] isCapturing in self?.hud.setHiddenFromCapture(isHidden: isCapturing) }
		computer.onSendingKeys = { isSending in HotKey.setAllSuspended(isSuspended: isSending) }
	}

	// MARK: Startup

	func start() {
		guard !hasStarted else { return }
		hasStarted = true
		audio.onPCM16k = { [weak self] data in
			guard let self else { return }
			self.audioQueue.async {
				self.ring.append(data)
				if self.ring.count > self.ringCapacity { self.ring.removeFirst(self.ring.count - self.ringCapacity) }
				self.audioTarget?.send(pcm: data)
			}
		}
		brain.onEvent = { [weak self] event in self?.handleBrain(event: event) }
		dictationKeys.onOutput = { [weak self] output in self?.handleDictation(output: output) }
		dictations.load()
		applyDictation(settings: config.dictation)

		// The brain doesn't need the mic: start it now rather than after a permission prompt is answered.
		brain.start()
		goIdle()
		Log.info(message: "bol: ready")
		AVCaptureDevice.requestAccess(for: .audio) { isGranted in
			DispatchQueue.main.async {
				if isGranted {
					self.updateMic()
				} else {
					self.hud.error(
						title: "Microphone access denied",
						detail: "Enable Bol in System Settings → Privacy & Security → Microphone.")
				}
			}
		}
	}

	// MARK: Public actions (menu / hotkeys / settings)

	/// ⌘J: start talking. Interrupts speech. It never sends: Enter does (see `enterPressed`).
	func talkNow() {
		switch state {
		case .listening(.dictation):
			abortListening()  // talk to Bol instead
			beginListening(mode: .manual)
		case .listening:
			break  // already listening; Enter sends, Esc cancels
		case .speaking, .starting, .idle, .thinking:
			stopSpeaking()
			beginListening(mode: .manual)
		}
	}

	func stopEverything() {
		pendingFiles = []
		hud.model.attachments = []
		computer.cancel()
		stopSpeaking()
		if case .listening = state { abortListening() }
		if brainTask == .working {
			brainTask = .cancelled
			brain.interrupt()
		}
		hud.notice(title: "Stopped", icon: "stop.fill", hideAfter: 1.0)
		goIdle(lingerSeconds: 1.0)
	}

	/// One line for logs and scripted tests.
	var debugDescription: String {
		"state=\(state) task=\(brainTask) shown=\(isThreadShown) tasks=\(tasks.count) deferred=\(deferredBackground.count) listening=\(listening != nil) speech=\(speech != nil) mic=\(audio.isRunning)"
	}

	/// The request on screen can be moved out of sight.
	var canSendToBackground: Bool { brainTask == .working && isThreadShown }

	/// The thread is working on a request out of sight.
	var isWorkingInBackground: Bool { brainTask == .working && !isThreadShown }

	/// "Send it to the background": Bol keeps working on it, out of sight, and you're free right away.
	func sendToBackground() {
		guard canSendToBackground else {
			hud.notice(title: "Nothing to send to the background", icon: "tray", hideAfter: 1.8)
			goIdle(lingerSeconds: 1.8)
			return
		}
		isThreadShown = false
		hud.notice(
			title: "Working on it in the background", detail: lastPrompt, icon: "tray.and.arrow.down", hideAfter: 2.2)
		goIdle(lingerSeconds: 2.2)
		onStateChange?()
	}

	func stopTasks() {
		guard !tasks.isEmpty else { return }
		for (job, _) in tasks { brain.stop(task: job) }
		let count = tasks.count
		tasks.removeAll()
		deferredBackground.removeAll()
		onStateChange?()
		hud.notice(title: count == 1 ? "Task stopped" : "\(count) tasks stopped", icon: "stop.fill", hideAfter: 1.6)
	}

	/// A follow-up typed into a task in the Threads window.
	func message(task job: String, text: String) {
		brain.message(task: job, text: text)
	}

	/// Files dropped on the voice bar: they go out with what you say next, so Bol starts listening (or
	/// keeps listening) for what to do with them. Claude runs on this Mac, so it reads them by path.
	func attach(files urls: [URL]) {
		let new = urls.filter { !pendingFiles.contains($0) }
		guard !new.isEmpty else { return }
		pendingFiles += new
		hud.model.attachments = pendingFiles
		hud.model.isDragActive = false
		Log.info(message: "attached: \(new.map(\.path).joined(separator: ", "))")
		switch state {
		case .listening(.manual), .listening(.followUp):
			listening?.lastChangeAt = Date()  // more time to say what to do with it
		case .listening(.dictation):
			abortListening()
			beginListening(mode: .manual)
		case .speaking, .starting, .idle, .thinking:
			stopSpeaking()
			beginListening(mode: .manual)
		}
	}

	/// Sends what you said to the thread, with any dropped files. Unless you asked Bol to stay with you, it
	/// works out of sight and comes back when it's done or has a question.
	private func sendToThread(text: String, isShown: Bool) {
		NSSound(named: "Pop")?.play()
		let files = pendingFiles
		pendingFiles = []
		hud.model.attachments = files  // shown with the request while Bol works on it
		let isAddedToTask = brainTask == .working
		let shownText = text.isEmpty ? (files.count == 1 ? files[0].lastPathComponent : "\(files.count) files") : text
		lastPrompt = shownText
		activity = ""
		brainTask = .working
		isThreadShown = isShown
		requestSeq += 1
		brain.say(text: Self.message(text: text, files: files), seq: requestSeq)
		if isShown {
			hud.thinking(prompt: shownText, isAddedToTask: isAddedToTask)
			state = .thinking
		} else {
			hud.notice(title: "On it", detail: shownText, icon: "tray.and.arrow.down", hideAfter: 1.4)
			goIdle(lingerSeconds: 1.4)
		}
		onStateChange?()
	}

	/// What the brain receives: one "[Attached file: …]" line per dropped file, then what you said.
	static func message(text: String, files: [URL]) -> String {
		guard !files.isEmpty else { return text }
		let lines = files.map { "[Attached file: \($0.path)]" }.joined(separator: "\n")
		let request =
			text.isEmpty ? "(Dropped on Bol without a request: take a look and briefly say what it is.)" : text
		return lines + "\n\n" + request
	}

	/// "Talk to Bol" on a thread in the Threads window: that thread becomes the conversation, and Bol listens.
	func continueConversation(sessionId: String) {
		stopEverything()
		brain.continueConversation(sessionId: sessionId)
		brainTask = .idle
		isThreadShown = false  // the closed conversation sends no result to clear a cancelled task
		beginListening(mode: .manual)
		hud.listening(status: "Listening · continuing this thread")
	}

	func newConversation() {
		stopEverything()
		brain.reset()
		brainTask = .idle
		isThreadShown = false  // the closed conversation sends no result to clear a cancelled task
		hud.notice(
			title: "New conversation", detail: "Bol starts fresh from here", icon: "square.and.pencil", hideAfter: 1.6)
	}

	func reloadConfig(config newConfig: Config) {
		let wasSilent = config.isSilentMode
		config = newConfig
		hud.model.isSilent = newConfig.isSilentMode
		if brain.update(config: newConfig) { onBrainState?(.restarting) }
		if wasSilent != newConfig.isSilentMode { silentModeChanged() }
		applyDucking(config: newConfig)
		updateDucking()
		if hasStarted { applyDictation(settings: newConfig.dictation) }
	}

	/// Settings "Play Sample": speak without touching the conversation.
	/// Returns false if Bol is busy (listening or speaking a reply).
	func testVoice(text: String, onEvent: @escaping (Speaker.Event) -> Void, completion: @escaping () -> Void) -> Bool {
		guard !isBusyTalking else { return false }
		isPlayingSample = true
		updateDucking()
		speaker.speak(text: text, config: config, onEvent: onEvent) { [weak self] in
			self?.isPlayingSample = false
			self?.updateDucking()
			completion()
		}
		return true
	}

	func stopTestVoice() {
		if !isBusyTalking { speaker.stop() }
	}

	/// Listening or speaking: the mic or speaker is in use by the conversation.
	var isBusyTalking: Bool {
		switch state {
		case .listening, .speaking: return true
		case .starting, .idle, .thinking: return false
		}
	}

	/// Dev-only (defaults BolDevHooks): play a typed request as if it had been dictated, for demo recordings.
	func inject(text: String, isInstant: Bool = false) {
		if isInstant {
			// Scripted tests: no typing animation, so requests can land milliseconds apart.
			stopSpeaking()
			handleUtterance(text: text, mode: .manual)
			return
		}
		stopSpeaking()
		hud.listening()
		let words = text.split(separator: " ").map(String.init)
		for i in words.indices {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.7 + Double(i) * 0.16) { [weak self] in
				self?.hud.transcript(text: words[0...i].joined(separator: " "))
			}
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.7 + Double(words.count) * 0.16 + 0.6) { [weak self] in
			self?.handleUtterance(text: text, mode: .manual)
		}
	}

	// MARK: State helpers

	/// The × on the voice bar: stop if Bol is busy, otherwise just dismiss.
	private func closeFromHUD() {
		switch state {
		case .listening, .thinking, .speaking: stopEverything()
		case .starting, .idle: hud.hide()
		}
	}

	/// Silent mode turned on or off (from the menu or Settings).
	private func silentModeChanged() {
		let isSilent = config.isSilentMode
		if isSilent, case .speaking = state {
			stopSpeaking()
			let linger = readingSeconds(text: lastReply)
			hud.replied(reply: lastReplyText, prompt: lastPrompt, hideAfter: linger)
			goIdle(lingerSeconds: linger)
		}
		if state == .idle {
			hud.notice(
				title: isSilent ? "Silent mode on" : "Silent mode off",
				detail: isSilent ? "Replies appear here without being spoken" : "Bol will speak its replies again",
				icon: isSilent ? "speaker.slash.fill" : "speaker.wave.2.fill", hideAfter: 1.8)
		}
		onStateChange?()
	}

	/// Where Bol rests between conversations: thinking only while you watch a request it's working on.
	private var workingState: State { brainTask == .working && isThreadShown ? .thinking : .idle }

	private func goIdle(lingerSeconds: TimeInterval = 0.6) {
		state = workingState
		// Replies and notices manage their own auto-dismiss timers.
		if state == .idle, !hud.model.phase.isSelfDismissing { hud.hide(after: lingerSeconds) }
	}

	/// Seconds to keep a reply on screen so it can be read.
	private func readingSeconds(text: String) -> TimeInterval {
		let words = text.split(separator: " ").count
		return min(45, max(3, Double(words) * 0.3))
	}

	/// Esc is only captured while Bol is busy or its voice bar is up, so it works normally in other
	/// apps otherwise.
	private func updateEscKey() {
		let isWanted: Bool
		switch state {
		case .speaking, .thinking, .listening: isWanted = true
		case .starting, .idle: isWanted = hud.model.isVisible
		}
		if isWanted, escKey == nil {
			escKey = HotKey(keyCode: kVK_Escape, modifiers: 0) { [weak self] in self?.escapePressed() }
		} else if !isWanted {
			escKey = nil
		}
	}

	/// Return / Enter are only captured while Bol listens, so they work normally in other apps the
	/// rest of the time.
	private func updateEnterKeys() {
		let isWanted: Bool
		switch state {
		case .listening(.dictation): isWanted = false  // Enter belongs to the app you're dictating into
		case .listening: isWanted = true
		case .starting, .idle, .thinking, .speaking: isWanted = false
		}
		if isWanted, enterKeys.isEmpty {
			enterKeys = [kVK_Return, kVK_ANSI_KeypadEnter].compactMap { key in
				HotKey(keyCode: key, modifiers: 0) { [weak self] in self?.enterPressed() }
			}
		} else if !isWanted {
			enterKeys = []
		}
	}

	/// Enter while listening sends what was said; with nothing said, it just closes the bar.
	private func enterPressed() {
		guard case .listening = state, let current = listening, !current.isFinishing else { return }
		finishListening()
	}

	/// Esc while Bol talks silences it and leaves the reply on screen; Esc again closes it.
	/// While it listens or works, Esc stops everything.
	private func escapePressed() {
		switch state {
		case .speaking:
			stopSpeaking()
			hud.replied(reply: lastReplyText, prompt: lastPrompt, hideAfter: readingSeconds(text: lastReply) + 2)
			goIdle()
		case .listening(.dictation):
			abortListening()  // only the dictation: a task Bol is working on carries on
			endDictation()
		case .listening, .thinking:
			stopEverything()
		case .starting, .idle:
			hud.hide()
		}
	}

	// MARK: Microphone lifecycle

	private var isMicNeeded: Bool {
		switch state {
		case .listening: return true
		case .starting, .idle, .thinking, .speaking: return false
		}
	}

	private func applyDucking(config: Config) {
		ducker.behavior = config.otherAudio
		ducker.level = Float(config.otherAudioLevel)
	}

	/// Other apps go quiet while Bol listens or speaks.
	private func updateDucking() {
		let isTalking: Bool
		switch state {
		case .listening: isTalking = listening?.isRevealed ?? true
		case .speaking: isTalking = true
		case .starting, .idle, .thinking: isTalking = false
		}
		ducker.setDucked(isDucked: isTalking || isPlayingSample)
	}

	private func updateMic() {
		guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
		if isMicNeeded, !audio.isRunning {
			audioQueue.sync { ring.removeAll() }
			do {
				try audio.start()
			} catch {
				Log.info(message: "audio: start failed: \(error)")
				// Out of this state's didSet, so the change to idle runs its own updates.
				DispatchQueue.main.async { [weak self] in
					guard let self, case .listening = self.state else { return }
					self.abortListening()
					self.goIdle()
					self.hud.error(title: "Couldn't start microphone", detail: error.localizedDescription)
				}
			}
		} else if !isMicNeeded, audio.isRunning {
			audio.stop()
			Log.info(message: "audio: mic released")
		}
	}

	// MARK: Listening

	private func beginListening(mode: ListenMode) {
		endListeningSession()
		let provider = SpeechToTextProviders.active(config: config)
		let session = provider.makeSession(config: config)
		let current = Listening(mode: mode, session: session)
		if case .dictation = mode { current.isRevealed = false }
		listening = current
		hud.model.attachments = pendingFiles
		state = .listening(mode)  // opens the mic

		switch mode {
		case .followUp: hud.followUp(previousReply: lastReply, seconds: config.followUpSeconds)
		case .manual:
			hud.listening()
		case .dictation(let app):
			DispatchQueue.main.asyncAfter(deadline: .now() + Constants.dictationRevealSeconds) {
				[weak self, weak current] in
				guard let self, let current, current === self.listening, !current.isFinishing else { return }
				current.isRevealed = true
				self.hud.dictating(app: app, isLocked: false)
				if !current.rawText.isEmpty { self.hud.transcript(text: current.rawText) }
				self.updateDucking()
			}
		}

		session.onTranscript = { [weak self, weak current] transcript in
			guard let self, let current, current === self.listening else { return }
			if transcript.isFinal {
				current.segments.append(transcript.text)
				current.interim = ""
			} else {
				current.interim = transcript.text
			}
			current.lastChangeAt = Date()
			let shown = current.rawText
			if !shown.isEmpty, current.isRevealed { self.hud.transcript(text: shown) }
		}
		session.onError = { [weak self, weak current] problem in
			guard let self, let current, current === self.listening else { return }
			Log.info(message: "stt error: \(problem.title): \(problem.detail)")
			if provider.id == .claude, problem.isOutage { SpeechToTextOutage.record(problem: problem) }
			if provider.id == .claude {
				Task { @MainActor in ServiceHealth.shared.report(item: .speechToText, problem: problem) }
			}
			guard current.rawText.isEmpty else { return }
			self.abortListening()
			self.goIdle()
			let hasFallback =
				provider.id == .claude && problem.isOutage
				&& SpeechToTextProviders.active(config: self.config).id != .claude
			self.hud.error(
				title: problem.title,
				detail: hasFallback ? "Press ⌘J to try again: Bol will listen with OpenAI for now." : problem.detail)
		}

		Task { @MainActor [weak self] in
			let token: String?
			switch provider.credential {
			case .claudeSubscription: token = await ClaudeAuth.accessToken(isUserAction: true)
			case .none, .apiKey: token = nil
			}
			guard let self, current === self.listening else { return }
			if provider.credential == .claudeSubscription, token == nil {
				self.abortListening()
				self.goIdle()
				self.hud.error(
					title: "Not signed in to Claude Code",
					detail: "Sign in from Settings → Assistant, or run `claude auth login` in Terminal.")
				return
			}
			session.start(claudeToken: token)
			self.sendCaptured(since: current.startedAt, to: session)
		}

		current.tick = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
			self?.checkEndOfSpeech()
		}
	}

	/// On the audio queue: sends `session` what the mic captured while it connected, then streams to it.
	private func sendCaptured(since startedAt: Date, to session: SpeechToTextSession) {
		audioQueue.async {
			let elapsed = Int(Date().timeIntervalSince(startedAt) * Double(Constants.micBytesPerSecond)) & ~1
			let bytes = min(self.ring.count, elapsed)
			if bytes > 0 { session.send(pcm: self.ring.suffix(bytes)) }
			self.audioTarget = session
		}
	}

	private func checkEndOfSpeech() {
		guard let current = listening, !current.isFinishing else { return }
		if !current.session.isStreamingInterim, Double(audio.level) > Constants.batchSpeechLevel {
			current.lastChangeAt = Date()
			if !current.hasHeardSpeech {
				current.hasHeardSpeech = true
				hud.transcript(text: "…")
			}
		}
		let silenceSeconds = Date().timeIntervalSince(current.lastChangeAt)
		let hasCommand = !current.commandText.isEmpty || current.hasHeardSpeech
		let noSpeechTimeout: Double
		switch current.mode {
		case .followUp: noSpeechTimeout = config.followUpSeconds
		case .manual: noSpeechTimeout = Constants.manualNoSpeechTimeout
		case .dictation: noSpeechTimeout = Constants.maxUtteranceSeconds  // you decide when it ends
		}
		// Pauses never end a turn: once you've said something, only Enter (or the length cap) sends it.
		if !hasCommand, silenceSeconds > noSpeechTimeout, !pendingFiles.isEmpty, current.mode.isForBol {
			finishListening()  // nothing said, but files were dropped: they go on their own
		} else if !hasCommand, silenceSeconds > noSpeechTimeout {
			let mode = current.mode
			abortListening()
			if mode == .followUp {
				// Nobody followed up: settle back to showing the reply, then fade out.
				hud.replied(reply: lastReplyText, prompt: lastPrompt, hideAfter: 2.5)
			}
			goIdle()
		} else if Date().timeIntervalSince(current.startedAt) > Constants.maxUtteranceSeconds {
			finishListening()
		}
	}

	private func finishListening() {
		guard let current = listening, !current.isFinishing else { return }
		current.isFinishing = true
		current.tick?.invalidate()
		current.tick = nil
		audioQueue.sync { audioTarget = nil }
		// Done capturing: release the mic while the transcript is finalized.
		state = workingState
		if case .dictation = current.mode {
			hud.transcribing(text: current.rawText)
		} else if current.session.isStreamingInterim {
			hud.thinking(prompt: current.rawText)
		} else {
			hud.transcribing()
		}
		current.session.onFinished = { [weak self, weak current] in
			guard let self, let current, current === self.listening else { return }
			self.listening = nil
			self.handleUtterance(text: current.commandText, mode: current.mode)
		}
		current.session.flush()
	}

	/// Drops the utterance in progress.
	private func abortListening() {
		guard let current = listening else { return }
		endListeningSession()
		if case .dictation = current.mode { dictationKeys.reset() }  // a held or locked key starts over
		state = .idle
	}

	private func endListeningSession() {
		guard let current = listening else { return }
		listening = nil
		current.tick?.invalidate()
		current.session.cancel()
		audioQueue.sync { audioTarget = nil }
	}

	// MARK: Commands

	private func handleUtterance(text: String, mode: ListenMode) {
		Log.info(message: "heard [\(mode)]: \(text)")
		switch mode {
		case .dictation(let app):
			paste(dictation: text, app: app)
		case .manual, .followUp:
			guard !text.isEmpty else {
				if pendingFiles.isEmpty {
					goIdle()
				} else {
					sendToThread(text: "", isShown: false)  // files dropped, nothing said
				}
				return
			}
			if Intent.isBackgroundCommand(text: text) {
				sendToBackground()
				return
			}
			if Intent.isStopCommand(text: text) {
				stopEverything()
				stopTasks()
				return
			}
			// Bol works out of sight unless you ask it to stay with you.
			if let request = Intent.foregroundRequest(text: text) {
				sendToThread(text: request, isShown: true)
			} else {
				sendToThread(text: Intent.backgroundRequest(text: text) ?? text, isShown: false)
			}
		}
	}

	private func handleBrain(event: BrainBridge.Event) {
		switch event {
		case .ready:
			onBrainState?(.ready)
		case .tool(_, _, _?):
			break  // tasks stay out of the way
		case .screen(_, _?):
			showUsingComputer()
		case .result(let text, let isError, let job?, _):
			// It stays listed until the brain says it's done (a follow-up may be queued).
			guard let name = tasks.first(where: { $0.job == job })?.name else { return }  // stopped
			Log.info(message: "task reply\(isError ? " (error)" : "") [\(name)]: \(text)")
			deliver(background: .result(prompt: name, text: text, isError: isError))
			onStateChange?()
		case .skills(let skills):
			Log.info(message: "skills: \(skills.map(\.name).joined(separator: ", "))")
			onSkills?(skills)
		case .mcpSignIn(let name, _, let error?):
			onMCPSignIn?(name, false)
			if state == .idle { hud.error(title: "Couldn't sign in to \(name)", detail: error) }
		case .mcpSignIn(let name, let url, nil):
			onMCPSignIn?(name, url != nil)
			if state == .idle, url != nil {
				hud.notice(
					title: "Sign in to \(name)", detail: "Finish in your browser; Bol connects when you're done",
					icon: "person.crop.circle.badge.checkmark", hideAfter: 4)
			}
		case .mcpSignInDone(let name, let status):
			onMCPSignIn?(name, false)
			brain.requestMCPStatus()
			if state == .idle, status == "connected" {
				hud.notice(title: "\(name) is connected", icon: "checkmark", hideAfter: 2)
			}
		case .task(let job, let name, let status):
			switch status {
			case .running:
				if !tasks.contains(where: { $0.job == job }) { tasks.append((job, name)) }
			case .done, .failed, .stopped:
				// A finished task's result arrives (and is removed) just before this.
				tasks.removeAll { $0.job == job }
			}
			onStateChange?()
		case .mcpStatus(let report):
			let servers = report.servers.map { "\($0.name)=\($0.status)\($0.tools.map { "(\($0))" } ?? "")" }
			let problems = report.problems.map { "\($0.name): \($0.error)" }
			Log.info(
				message:
					"mcp: \(servers.joined(separator: ", "))\(problems.isEmpty ? "" : " | problems: \(problems.joined(separator: "; "))")"
			)
			onMCPStatus?(report)
		case .control(let id, let action):
			showUsingComputer()
			computer.perform(action: action) { [weak self] result in
				if result.isError { Log.info(message: "control \(action.name.rawValue) failed: \(result.text)") }
				self?.brain.controlResult(id: id, result: result)
			}
		case .idle(let seq):
			guard seq >= requestSeq, brainTask != .idle else { return }  // a newer request is still running
			brainTask = .idle
			if state == .thinking { goIdle() }
			onStateChange?()
		case .interrupted:
			// Only clears a stop still waiting for it; a newer request keeps running untouched.
			guard brainTask == .cancelled else { return }
			brainTask = .idle
			if state == .thinking { goIdle() }
		case .restarted:
			brainTask = .idle
			if state == .thinking { goIdle() }
			guard !tasks.isEmpty else { return }
			tasks.removeAll()
			deferredBackground.removeAll()
			onStateChange?()
			hud.error(title: "Tasks stopped", detail: "Bol's brain restarted, so they didn't finish.")
		case .tool(let name, let summary, nil):
			activity = HUD.describe(tool: name, summary: summary).label
			onStateChange?()
			if state == .thinking { hud.activity(tool: name, summary: summary) }
		case .screen(let reason, nil):
			activity = "Looking at your screen"
			onStateChange?()
			if state == .thinking { hud.looking(reason: reason) } else { showUsingComputer() }
		case .result(let text, let isError, nil, let isDelegated):
			// A reply doesn't end the work: queued requests may follow. The brain's `idle` does.
			switch brainTask {
			case .cancelled: return  // stopped by the user; drop what was already on its way
			case .working, .idle: break
			}
			if isError { brainTask = .idle }  // a failed session reports nothing further
			Log.info(message: "reply\(isError ? " (error)" : "")\(isDelegated ? " (handed to a task)" : ""): \(text)")
			if !isThreadShown, isDelegated, !isError {
				return  // "On it" was already shown; the task reports when it's done
			}
			if case .listening = state {
				// You're talking or dictating: it waits until you're done.
				deliver(background: .result(prompt: lastPrompt, text: text, isError: isError))
				return
			}
			if !isThreadShown {
				deliver(background: .result(prompt: lastPrompt, text: text, isError: isError))
				return
			}
			if config.isSilentMode {
				showSilently(text: text)
			} else {
				speak(text: text, then: config.isFollowUpEnabled ? .followUp : nil)
			}
		}
	}

	// MARK: Background jobs

	/// A background task is looking at or operating the screen: say so, so nobody fights it for the
	/// pointer. Refreshed with every action; a foreground task shows its own steps instead.
	private func showUsingComputer() {
		guard state == .idle, !hud.model.isVisible || hud.model.phase == .notice else { return }
		let detail = tasks.count == 1 ? tasks[0].name : ""
		hud.notice(title: "Using computer, stand by", detail: detail, icon: "cursorarrow.click.2", hideAfter: 10)
	}

	/// Shows a background result now, or once Bol isn't listening or speaking.
	private func deliver(background event: BackgroundEvent) {
		deferredBackground.append(event)
		if state == .idle { showDeferredBackground() }
	}

	private func showDeferredBackground() {
		guard state == .idle, listening == nil, !deferredBackground.isEmpty else { return }
		switch deferredBackground.removeFirst() {
		case .result(let prompt, let text, let isError):
			if isError {
				hud.error(title: "Didn't work out", detail: "\(prompt): \(text)")
			} else if !config.isSilentMode {
				// Spoken like any reply; the next one waits until Bol is free again.
				lastPrompt = prompt
				speak(text: text, then: config.isFollowUpEnabled ? .followUp : nil)
				return
			} else {
				NSSound(named: "Glass")?.play()
				let reply = SpeechText.cleaned(text: text)
				lastReply = reply
				lastReplyText = text
				hud.replied(
					reply: text, prompt: prompt,
					hideAfter: readingSeconds(text: reply) + 2)
			}
			// Several finished at once: show the next after this one has been read.
			if !deferredBackground.isEmpty {
				DispatchQueue.main.asyncAfter(deadline: .now() + readingSeconds(text: text) + 2.5) { [weak self] in
					self?.showDeferredBackground()
				}
			}
		}
	}

	// MARK: Dictation

	/// The dictation key's gestures (see `DictationGesture`).
	private func handleDictation(output: DictationGesture.Output) {
		switch output {
		case .start:
			startDictating()
		case .lock:
			guard case .listening(.dictation) = state, let current = listening else { return }
			if !current.isRevealed {
				current.isRevealed = true
				if case .dictation(let app) = current.mode { hud.dictating(app: app, isLocked: true) }
				updateDucking()
			}
			hud.lockDictation()
		case .finish:
			if case .listening(.dictation) = state { finishListening() }
		case .discard:
			guard case .listening(.dictation) = state, let current = listening else { return }
			endListeningSession()  // not abortListening: a double-tap may follow this tap
			state = .idle
			if current.isRevealed {
				endDictation()
			} else {
				goIdle(lingerSeconds: 0)  // never shown: whatever the bar shows stays
				showDeferredBackground()
			}
		}
	}

	private func startDictating() {
		switch state {
		case .starting, .listening:
			// Bol is already listening to you.
			dictationKeys.reset()
			return
		case .speaking:
			stopSpeaking()
		case .idle, .thinking:
			break
		}
		beginListening(mode: .dictation(app: NSWorkspace.shared.frontmostApplication?.localizedName))
	}

	private func paste(dictation text: String, app: String?) {
		guard !text.isEmpty else {
			endDictation()
			return
		}
		dictations.add(text: text, app: app)
		if Paster.paste(text: text) {
			endDictation()
		} else {
			goIdle()
			hud.error(
				title: "Copied, not pasted",
				detail: "Allow Bol under Privacy & Security → Accessibility to paste into apps. It's on your clipboard."
			)
		}
	}

	/// Pastes the last dictation again (its shortcut, ⌥⇧V by default, or the menu).
	func pasteLastDictation() {
		guard let last = dictations.last else {
			hud.notice(
				title: "Nothing dictated yet", detail: "Hold \(config.dictation.key.label) in any app and speak",
				icon: "text.cursor", hideAfter: 2)
			return
		}
		if !Paster.paste(text: last.text) {
			hud.error(
				title: "Copied, not pasted",
				detail: "Allow Bol under Privacy & Security → Accessibility to paste into apps. It's on your clipboard."
			)
		}
	}

	/// Back to whatever Bol was doing before the dictation.
	private func endDictation() {
		goIdle(lingerSeconds: 0)
		if state == .thinking {
			hud.thinking(prompt: lastPrompt)
		}
		showDeferredBackground()
	}

	private func applyDictation(settings: DictationSettings) {
		dictationKeys.update(settings: settings)
		hud.model.dictationKey = settings.key.glyph
		if !settings.isEnabled, case .listening(.dictation) = state {
			abortListening()
			endDictation()
		}
	}

	// MARK: Speaking

	private func speak(text: String, then requested: ListenMode?) {
		// No mic connected: listening for a follow-up would only replace the reply with an error.
		let next = requested == .followUp && !AudioCapture.hasInputDevice ? nil : requested
		stopSpeaking()
		let current = Speech()
		speech = current
		state = .speaking(then: next)
		lastReply = SpeechText.cleaned(text: text)
		lastReplyText = text
		hud.speaking(reply: lastReplyText, prompt: lastPrompt)
		speaker.speak(text: text, config: config) { [weak self, weak current] in
			guard let self, let current, current === self.speech else { return }
			self.stopSpeaking()
			if let next {
				self.beginListening(mode: next)
			} else {
				let linger = self.readingSeconds(text: self.lastReply)
				self.hud.replied(reply: self.lastReplyText, prompt: self.lastPrompt, hideAfter: linger)
				self.goIdle(lingerSeconds: linger)
			}
		}
	}

	private func stopSpeaking() {
		guard speech != nil else { return }
		speech = nil  // first, so the speaker's completion for it is ignored
		speaker.stop()
	}

	/// Silent mode: show the reply in the voice bar, no speech, no follow-up listening.
	private func showSilently(text: String) {
		lastReply = SpeechText.cleaned(text: text)
		lastReplyText = text
		hud.replied(reply: lastReplyText, prompt: lastPrompt, hideAfter: readingSeconds(text: lastReply) + 2)
		state = workingState
	}
}

/// What a short utterance means, when it's a reply rather than a request.
enum Intent {
	/// The whole utterance asks to move the running request to the background: "send it to the
	/// background", "background it", "keep going in the background".
	static func isBackgroundCommand(text: String) -> Bool {
		let words = normalized(text: text)
		let patterns = [
			"^(please )?((send|move|put|push|run|do|continue|finish|take) )?(it |this |that |the rest )?((to|in|into|on) )?(the )?background( it| this| that)?( please)?$",
			"^(keep going|keep working|carry on|continue|go on|work on it) in the background( please)?$",
		]
		return patterns.contains { words.range(of: $0, options: .regularExpression) != nil }
	}

	/// A request asked to run in the background from the start ("in the background, find…",
	/// "…and do it in the background"); returns the request without that part.
	static func backgroundRequest(text: String) -> String? {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		let patterns = [
			"^(?i)(in the background|in background|as a background task|background task)[,:.]?\\s+(?<request>.+)$",
			"^(?i)(?<request>.+?)[,.]?\\s+(and )?(do|run|handle) (it|this|that) (in the background|in background)[.!]?$",
			"^(?i)(?<request>.+?)[,.]?\\s+as a background task[.!]?$",
		]
		for pattern in patterns {
			guard let regex = try? NSRegularExpression(pattern: pattern),
				let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
				let range = Range(match.range(withName: "request"), in: trimmed)
			else { continue }
			let request = trimmed[range].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
			if !request.isEmpty { return request }
		}
		return nil
	}

	/// A request asked to stay in the foreground ("in the foreground, …", "…, keep it in the
	/// foreground", "…, stay with me"); returns the request without that part.
	static func foregroundRequest(text: String) -> String? {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		let place = "(in the foreground|in foreground|in front of me|here with me|with me)"
		let patterns = [
			"^(?i)(in the foreground|in foreground|foreground|stay with me|keep it in the foreground)[,:.]?\\s+(?<request>.+)$",
			"^(?i)(?<request>.+?)[,.]?\\s+(and )?(do|run|keep|handle|show) (it|this|that) \(place)[.!]?$",
			"^(?i)(?<request>.+?)[,.]?\\s+(and )?(stay with me|in the foreground|in foreground)[.!]?$",
		]
		for pattern in patterns {
			guard let regex = try? NSRegularExpression(pattern: pattern),
				let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
				let range = Range(match.range(withName: "request"), in: trimmed)
			else { continue }
			let request = trimmed[range].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
			if !request.isEmpty { return request }
		}
		return nil
	}

	private static func normalized(text: String) -> String {
		text.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
			.split(separator: " ").joined(separator: " ")
	}

	/// The whole utterance is a stop phrase ("stop", "never mind that"). A request that merely starts
	/// with one ("Stop the music and open Notes", "Never mind, what's 12 plus 30?") is a request.
	static func isStopCommand(text: String) -> Bool {
		normalized(text: text).range(
			of:
				"^(ok |okay |please |bol )*(stop|cancel|never ?mind|forget it|forget that|abort|shut up|be quiet|quiet)( it| that| this| please| now| talking| everything| bol)*$",
			options: .regularExpression) != nil
	}
}
