import SwiftUI

struct OnboardingView: View {
	@ObservedObject var model: OnboardingModel
	@ObservedObject var settings: SettingsModel

	var body: some View {
		HStack(spacing: 0) {
			sidebar
			Divider()
			VStack(alignment: .leading, spacing: 0) {
				ScrollView {
					VStack(alignment: .leading, spacing: 22) {
						header
						content
					}
					.padding(.horizontal, 32)
					.padding(.top, 36)
					.padding(.bottom, 24)
					.frame(maxWidth: .infinity, alignment: .leading)
				}
				Divider()
				footer
			}
		}
		// Shrinks to fit small screens: the step content scrolls, the sidebar and footer stay put.
		.frame(minWidth: 760, idealWidth: 880, maxWidth: 880, minHeight: 440, idealHeight: 600, maxHeight: 600)
		.animation(.easeOut(duration: 0.18), value: model.step)
	}

	// MARK: Chrome

	private var sidebar: some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack(spacing: 8) {
				Image(systemName: "waveform").font(.system(size: 15, weight: .semibold))
				Text("Bol setup").font(.system(size: 14, weight: .semibold))
			}
			.padding(.horizontal, 12)
			.padding(.top, 40)
			.padding(.bottom, 16)
			ForEach(OnboardingStep.allCases) { step in
				OnboardingStepItem(
					step: step, isCurrent: step == model.step,
					isComplete: step.rawValue < model.step.rawValue && model.isComplete(step: step),
					isReachable: model.isReachable(step: step)
				) { model.step = step }
			}
			Spacer()
		}
		.padding(.horizontal, 10)
		.frame(width: 200)
		.background(Color.primary.opacity(0.03))
	}

	private var header: some View {
		VStack(alignment: .leading, spacing: 8) {
			Image(systemName: model.step.icon)
				.font(.system(size: 20, weight: .regular))
				.frame(width: 44, height: 44)
				.background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
			Text(title).font(.system(size: 20, weight: .semibold))
			Text(subtitle).font(UI.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
		}
	}

	private var footer: some View {
		HStack(spacing: 10) {
			// Asked again after setup was done (the last step changed): there's nothing to go back to.
			if model.step != .welcome, !(model.step == .terms && settings.config.hasCompletedOnboarding) {
				Button("Back") { model.goBack() }.buttonStyle(SubtleButtonStyle())
			}
			Spacer()
			if let skip = skipTitle {
				Button(skip) { model.goForward() }.buttonStyle(.plain).font(UI.body).foregroundStyle(.secondary)
			}
			Button(primaryTitle) { model.goForward() }
				.buttonStyle(SubtleButtonStyle(isProminent: true))
				.keyboardShortcut(.defaultAction)
				.disabled(!model.isStepComplete && model.step != .permissions)
		}
		.padding(.horizontal, 24)
		.frame(height: 56)
	}

	private var primaryTitle: String {
		switch model.step {
		case .welcome: return "Get Started"
		case .permissions: return model.isStepComplete ? "Continue" : "Skip for Now"
		case .autonomy: return model.isComputerUseOn && model.isChromeControlOn ? "Continue" : "Skip for Now"
		case .terms: return "Start Using Bol"
		case .claudeCode, .account, .microphone, .voice, .dictation, .ready: return "Continue"
		}
	}

	/// Steps that can be passed without finishing their check.
	private var skipTitle: String? {
		switch model.step {
		case .microphone where model.microphone == .authorized && !model.isStepComplete: return "Skip test"
		case .welcome, .claudeCode, .account, .microphone, .voice, .dictation, .permissions, .autonomy, .ready, .terms:
			return nil
		}
	}

	private var title: String {
		switch model.step {
		case .welcome: return "Set up Bol"
		case .claudeCode: return "Claude Code"
		case .account: return "Your Claude account"
		case .microphone: return "Microphone and speech"
		case .voice: return "Bol's voice"
		case .dictation: return "Dictate into any app"
		case .permissions: return "Mac permissions"
		case .autonomy: return "Let Bol do more on its own"
		case .ready: return "You're all set"
		case .terms: return "Before you start"
		}
	}

	private var subtitle: String {
		switch model.step {
		case .welcome:
			return
				"Bol is a voice assistant for your Mac that thinks and acts with Claude Code. Setup checks everything it needs, which takes about two minutes."
		case .claudeCode:
			return
				"Bol runs on the Claude Code installed on this Mac: every request becomes a Claude Code session with full access to your apps and files."
		case .account:
			return
				"Bol listens with Claude's speech-to-text and thinks with your Claude plan. Both need a Claude subscription (Pro or Max); an API key alone can't do speech-to-text."
		case .microphone:
			return
				"Bol opens the microphone only while it listens to you, then releases it for other apps. Say a sentence to check that Bol can hear and transcribe you."
		case .voice:
			return
				"Choose how Bol speaks. The macOS voice is free and works offline; OpenAI and Noiz AI sound more natural and need an API key."
		case .dictation:
			return
				"Optional. Besides talking to Bol, it can type for you: hold a key in any app, speak, and let go, and what you said is pasted where you're typing."
		case .permissions:
			return
				"Bol does things for you by controlling apps and, when a request needs it, looking at your screen. You can grant these later in Settings."
		case .autonomy:
			return
				"Recommended. With these, Bol finishes more requests by itself instead of stopping to ask you: it can work any app on screen and browse in your own Chrome, signed in as you."
		case .ready:
			return
				"Press \(ShortcutState.shared.talkText) anywhere and start talking. Pause as much as you like; press Enter to send."
		case .terms:
			return
				"Bol acts on your Mac without asking first. Read what that means, then tick the box to start."
		}
	}

	@ViewBuilder private var content: some View {
		switch model.step {
		case .welcome: WelcomeStep()
		case .claudeCode: ClaudeCodeStep(model: model)
		case .account: AccountStep(model: model)
		case .microphone: MicrophoneStep(model: model)
		case .voice: VoiceStep(settings: settings)
		case .dictation: DictationStep(model: model, settings: settings)
		case .permissions: PermissionsStep(settings: settings)
		case .autonomy: AutonomyStep(model: model, settings: settings)
		case .ready: ReadyStep(model: model, settings: settings)
		case .terms: TermsStep(model: model, settings: settings)
		}
	}
}

private struct OnboardingStepItem: View {
	let step: OnboardingStep
	let isCurrent: Bool
	let isComplete: Bool
	let isReachable: Bool
	let action: () -> Void
	@State private var isHovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 10) {
				ZStack {
					Circle()
						.fill(isComplete ? Color.green.opacity(0.18) : Color.primary.opacity(isCurrent ? 0.12 : 0.06))
						.frame(width: 22, height: 22)
					if isComplete {
						Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.green)
					} else {
						Text("\(step.rawValue + 1)").font(.system(size: 11, weight: .semibold))
							.foregroundStyle(isCurrent ? .primary : .secondary)
					}
				}
				Text(step.title)
					.font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
					.foregroundStyle(isCurrent ? .primary : .secondary)
				Spacer(minLength: 0)
			}
			.padding(.horizontal, 10)
			.frame(height: 34)
			.background(
				RoundedRectangle(cornerRadius: 7, style: .continuous)
					.fill(Color.primary.opacity(isCurrent ? 0.08 : isHovering && isReachable ? 0.04 : 0))
			)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(!isReachable)
		.opacity(isReachable ? 1 : 0.5)
		.onHover { isHovering = $0 }
	}
}

/// A status line with an icon: the result of a check.
private struct CheckStatus: View {
	enum Kind { case working, success, warning, failure }
	let kind: Kind
	let text: String

	var body: some View {
		HStack(spacing: 8) {
			switch kind {
			case .working: ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 16, height: 16)
			case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
			case .warning: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
			case .failure: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
			}
			Text(text).font(UI.body).fixedSize(horizontal: false, vertical: true)
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

/// A command the user can read before Bol runs it in Terminal.
private struct CommandBlock: View {
	let command: String

	var body: some View {
		Text(command)
			.font(.system(size: 12, design: .monospaced))
			.textSelection(.enabled)
			.lineLimit(1).truncationMode(.middle)
			.padding(.horizontal, 10).frame(height: 30)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
			.overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(UI.hairline))
	}
}

// MARK: - Steps

private struct WelcomeStep: View {
	private let checks: [(icon: String, title: String, detail: String)] = [
		("terminal", "Claude Code", "Installed on this Mac"),
		("person.crop.circle", "Claude subscription", "Signed in and working"),
		("mic", "Microphone and speech", "Bol can hear and transcribe you"),
		("speaker.wave.2", "Voice", "How Bol talks back"),
		("lock.shield", "Permissions", "So Bol can control apps and see your screen"),
	]

	var body: some View {
		SettingsGroup(title: "Setup checks") {
			ForEach(checks, id: \.title) { check in
				SettingsRow(check.title, icon: check.icon) {
					Text(check.detail).font(UI.caption).foregroundStyle(.secondary)
				}
			}
		}
	}
}

private struct ClaudeCodeStep: View {
	@ObservedObject var model: OnboardingModel

	var body: some View {
		SettingsGroup {
			switch model.claudeCode {
			case .checking:
				CheckStatus(kind: .working, text: "Looking for Claude Code…")
			case .installing:
				CheckStatus(
					kind: .working,
					text: "Finish the installer in Terminal. Bol continues as soon as Claude Code is installed.")
			case .missing:
				CheckStatus(kind: .warning, text: "Claude Code isn't installed on this Mac.")
				VStack(alignment: .leading, spacing: 10) {
					Text("Bol can run the official installer for you in Terminal:").font(UI.caption).foregroundStyle(
						.secondary)
					CommandBlock(command: ClaudeCode.installCommand)
					HStack(spacing: 8) {
						Button("Install in Terminal") { model.installClaudeCode() }
							.buttonStyle(SubtleButtonStyle(isProminent: true))
						Button("Check Again") { model.checkClaudeCode() }.buttonStyle(SubtleButtonStyle())
					}
				}
				.padding(14)
			case .installed(let version):
				CheckStatus(kind: .success, text: "Claude Code \(version) is installed.")
				if let path = ClaudeCode.executable?.path {
					SettingsRow("Location", icon: "folder") {
						Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
							.font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
					}
				}
			}
		}
		.onAppear { if model.claudeCode == .checking { model.checkClaudeCode() } }
	}
}

private struct AccountStep: View {
	@ObservedObject var model: OnboardingModel

	var body: some View {
		SettingsGroup {
			switch model.account {
			case .checking:
				CheckStatus(kind: .working, text: "Checking your Claude login…")
			case .signingIn:
				CheckStatus(kind: .working, text: "Finish signing in in your browser. Bol continues automatically.")
				HStack(spacing: 8) {
					Button("Open Sign-In Again") { model.signIn() }.buttonStyle(SubtleButtonStyle())
					Button("Check Again") { model.checkAccount() }.buttonStyle(SubtleButtonStyle())
				}
				.padding(14)
				.frame(maxWidth: .infinity, alignment: .leading)
			case .signedOut:
				CheckStatus(kind: .warning, text: "Claude Code isn't signed in to a Claude account.")
				actions(primary: "Sign In with Claude")
			case .notWorking(let reason):
				CheckStatus(kind: .failure, text: reason)
				actions(primary: "Sign In Again")
			case .ready(let plan):
				CheckStatus(
					kind: .success, text: "Signed in\(plan.map { " with \($0)" } ?? ""). Your subscription is working.")
			}
		}
		.onAppear { if model.account == .checking { model.checkAccount() } }
	}

	private func actions(primary: String) -> some View {
		HStack(spacing: 8) {
			Button(primary) { model.signIn() }.buttonStyle(SubtleButtonStyle(isProminent: true))
			Button("Check Again") { model.checkAccount() }.buttonStyle(SubtleButtonStyle())
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

private struct MicrophoneStep: View {
	@ObservedObject var model: OnboardingModel

	var body: some View {
		SettingsGroup {
			switch model.microphone {
			case .authorized:
				speechTest
			case .notDetermined:
				CheckStatus(kind: .warning, text: "Bol needs your permission to use the microphone.")
				Button("Allow Microphone") { model.requestMicrophone() }
					.buttonStyle(SubtleButtonStyle(isProminent: true)).padding(14)
			case .denied, .restricted:
				CheckStatus(kind: .failure, text: "Microphone access is turned off for Bol.")
				Button("Open System Settings") { model.requestMicrophone() }
					.buttonStyle(SubtleButtonStyle(isProminent: true)).padding(14)
			@unknown default:
				CheckStatus(kind: .warning, text: "Bol needs your permission to use the microphone.")
			}
		}
	}

	@ViewBuilder private var speechTest: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack(spacing: 14) {
				LevelBars(level: model.inputLevel)
				VStack(alignment: .leading, spacing: 4) {
					Text(prompt).font(UI.bodyMedium)
					Text(detail).font(UI.caption).foregroundStyle(detailColor).fixedSize(
						horizontal: false, vertical: true)
				}
				Spacer(minLength: 0)
			}
			switch model.speechTest {
			case .idle, .failed:
				Button("Start Test") { model.startSpeechTest() }.buttonStyle(SubtleButtonStyle(isProminent: true))
			case .connecting, .listening:
				Button("Stop") { model.stopSpeechTest() }.buttonStyle(SubtleButtonStyle())
			case .passed:
				Button("Test Again") { model.startSpeechTest() }.buttonStyle(SubtleButtonStyle())
			}
		}
		.padding(14)
	}

	private var prompt: String {
		switch model.speechTest {
		case .idle: return "Say “\(OnboardingModel.testPhrase)”"
		case .connecting: return "Connecting to Claude speech-to-text…"
		case .listening(let heard): return heard.isEmpty ? "Listening… speak now" : "“\(heard)”"
		case .passed(let heard): return "“\(heard)”"
		case .failed: return "The test didn't work"
		}
	}

	private var detail: String {
		switch model.speechTest {
		case .idle: return "Click Start Test, then say the phrase. It passes as soon as Bol recognizes it."
		case .connecting, .listening: return "The microphone is on."
		case .passed: return "Bol heard you. Microphone, login and speech-to-text all work."
		case .failed(let reason): return reason
		}
	}

	private var detailColor: Color {
		switch model.speechTest {
		case .idle, .connecting, .listening: return .secondary
		case .passed: return .green
		case .failed: return .red
		}
	}
}

/// Live input level as five bars.
private struct LevelBars: View {
	let level: Float

	var body: some View {
		HStack(alignment: .center, spacing: 3) {
			ForEach(0..<5, id: \.self) { i in
				let weight = [0.5, 0.8, 1.0, 0.8, 0.5][i]
				Capsule()
					.fill(Color.accentColor.opacity(level > 0.02 ? 1 : 0.35))
					.frame(width: 4, height: 6 + 26 * CGFloat(min(1, Double(level) * 1.8) * weight))
			}
		}
		.frame(width: 44, height: 36)
		.background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
		.animation(.easeOut(duration: 0.08), value: level)
	}
}

private struct VoiceStep: View {
	@ObservedObject var settings: SettingsModel
	@State private var sampleText = "Hi, I'm Bol. What can I do for you today?"

	private var chosen: TextToSpeechProvider {
		TextToSpeechProviders.provider(id: settings.config.textToSpeech.provider)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 18) {
			HStack(spacing: 10) {
				ForEach(TextToSpeechProviders.all, id: \.id) { provider in
					ProviderCard(provider: provider, isSelected: provider.id == chosen.id) {
						settings.config.textToSpeech.provider = provider.id
					}
				}
			}
			chosen.settingsSection(model: settings)
			HStack(spacing: 12) {
				Button {
					settings.toggleSample(text: sampleText)
				} label: {
					Label(
						settings.sample.isBusy ? "Stop" : "Play Sample",
						systemImage: settings.sample.isBusy ? "stop.fill" : "play.fill"
					)
					.frame(minWidth: 110)
				}
				.buttonStyle(SubtleButtonStyle())
				.disabled(
					!TextToSpeechProviders.active(config: settings.config).credential.isSatisfied(by: settings.config))
				if case .playing = settings.sample { PlayingBars() }
				if let note = settings.sampleNote { Text(note).font(UI.caption).foregroundStyle(.orange) }
			}
		}
	}
}

private struct ProviderCard: View {
	let provider: TextToSpeechProvider
	let isSelected: Bool
	let action: () -> Void
	@State private var isHovering = false

	var body: some View {
		Button(action: action) {
			VStack(alignment: .leading, spacing: 6) {
				HStack {
					Image(systemName: provider.icon).font(.system(size: 15)).frame(height: 20)
					Spacer()
					Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
						.foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
						.frame(height: 20)
				}
				Text(provider.title).font(UI.bodyMedium)
				Text(provider.subtitle).font(UI.caption).foregroundStyle(.secondary).lineLimit(2)
					.fixedSize(horizontal: false, vertical: true)
			}
			.padding(12)
			.frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
			.background(
				RoundedRectangle(cornerRadius: 10, style: .continuous)
					.fill(Color.primary.opacity(isSelected ? 0.08 : isHovering ? 0.05 : 0.03))
			)
			.overlay(
				RoundedRectangle(cornerRadius: 10, style: .continuous)
					.strokeBorder(
						isSelected ? Color.accentColor.opacity(0.8) : UI.hairline, lineWidth: isSelected ? 1.5 : 1)
			)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { isHovering = $0 }
	}
}

private struct DictationStep: View {
	@ObservedObject var model: OnboardingModel
	@ObservedObject var settings: SettingsModel

	private var isEnabled: Bool { settings.config.dictation.isEnabled }

	var body: some View {
		VStack(alignment: .leading, spacing: 18) {
			if !model.otherDictationApps.isEmpty { otherAppsNote }
			HStack(spacing: 10) {
				ChoiceCard(
					icon: "text.cursor", title: "Use Bol for dictation",
					subtitle: "Hold \(settings.config.dictation.key.title) in any app, speak, let go: it's pasted.",
					badge: model.isDictationRecommended ? "Recommended" : nil, isSelected: isEnabled
				) { settings.config.dictation.isEnabled = true }
				ChoiceCard(
					icon: "nosign", title: "Keep it off",
					subtitle: "Bol only listens when you press \(ShortcutState.shared.talkText).",
					badge: model.isDictationRecommended ? nil : "Recommended", isSelected: !isEnabled
				) { settings.config.dictation.isEnabled = false }
			}
			SettingsGroup(footer: "Change it any time in Settings → Dictation.") {
				if isEnabled {
					SettingsRow("Hold to dictate", icon: "keyboard") {
						Select(
							options: DictationPane.keyOptions,
							selection: Binding(
								get: { settings.config.dictation.key.rawValue },
								set: { settings.config.dictation.key = DictationKey(rawValue: $0) ?? .fn }))
					}
				} else {
					SettingsRow("Talk to Bol", icon: "mic", help: "Works the same either way") {
						Text(ShortcutState.shared.talkText).font(UI.body).foregroundStyle(.secondary)
					}
				}
			}
		}
		.animation(.easeOut(duration: 0.15), value: isEnabled)
	}

	private var otherAppsNote: some View {
		let names = DictationApps.list(apps: model.otherDictationApps)
		let verb = model.otherDictationApps.count == 1 ? "is" : "are"
		return HStack(alignment: .top, spacing: 10) {
			Image(systemName: "info.circle").font(.system(size: 14)).foregroundStyle(.secondary)
			VStack(alignment: .leading, spacing: 3) {
				Text("\(names) \(verb) installed").font(UI.bodyMedium)
				Text(
					"Dictation apps listen for a held key too, often the same fn key, so with both on one press could paste twice. Keep Bol's dictation off and keep using \(names) for typing; Bol still listens whenever you press \(ShortcutState.shared.talkText)."
				)
				.font(UI.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
			}
			Spacer(minLength: 0)
		}
		.padding(12)
		.background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(UI.hairline))
	}
}

/// A selectable option card, like the voice providers'.
private struct ChoiceCard: View {
	let icon: String
	let title: String
	let subtitle: String
	var badge: String? = nil
	let isSelected: Bool
	let action: () -> Void
	@State private var isHovering = false

	var body: some View {
		Button(action: action) {
			VStack(alignment: .leading, spacing: 6) {
				HStack(spacing: 8) {
					Image(systemName: icon).font(.system(size: 15)).frame(height: 20)
					if let badge {
						Text(badge).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
							.padding(.horizontal, 6).padding(.vertical, 2)
							.background(Color.primary.opacity(0.07), in: Capsule())
					}
					Spacer()
					Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
						.foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
						.frame(height: 20)
				}
				Text(title).font(UI.bodyMedium)
				Text(subtitle).font(UI.caption).foregroundStyle(.secondary).lineLimit(2)
					.fixedSize(horizontal: false, vertical: true)
			}
			.padding(12)
			.frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
			.background(
				RoundedRectangle(cornerRadius: 10, style: .continuous)
					.fill(Color.primary.opacity(isSelected ? 0.08 : isHovering ? 0.05 : 0.03))
			)
			.overlay(
				RoundedRectangle(cornerRadius: 10, style: .continuous)
					.strokeBorder(
						isSelected ? Color.accentColor.opacity(0.8) : UI.hairline, lineWidth: isSelected ? 1.5 : 1)
			)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { isHovering = $0 }
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}
}

private struct PermissionsStep: View {
	@ObservedObject var settings: SettingsModel

	var body: some View {
		SettingsGroup(
			footer: "The first time Bol controls an app (Chrome, Finder, Music…), macOS asks once. Click Allow."
		) {
			ForEach(MacPermission.allCases) { permission in
				let isGranted = settings.permissions.isGranted(permission: permission)
				SettingsRow(permission.title, icon: permission.icon, help: permission.purpose) {
					HStack(spacing: 10) {
						if isGranted {
							StatusDot(text: "Granted", color: .green)
						} else {
							Text(permission.importance.title).font(UI.caption).foregroundStyle(.tertiary)
							Button("Grant…") { permission.request() }.buttonStyle(SubtleButtonStyle())
						}
					}
					.animation(.easeOut(duration: 0.2), value: isGranted)
				}
			}
		}
	}
}

private struct AutonomyStep: View {
	@ObservedObject var model: OnboardingModel
	@ObservedObject var settings: SettingsModel

	var body: some View {
		SettingsGroup(
			title: "Recommended",
			footer: "Change either one later in Settings → Assistant → Access."
		) {
			SettingsRow(
				"Computer use", icon: "cursorarrow.click.2",
				help: "Bol sees your screen and clicks, types and scrolls in any app"
			) {
				status(isOn: model.isComputerUseOn) { model.turnOnComputerUse() }
			}
			SettingsRow(
				"Chrome control", icon: "globe",
				help: model.hasChromeExtension
					? "Bol browses in your Chrome with the Claude in Chrome extension"
					: "Install the Claude in Chrome extension, then come back"
			) {
				status(isOn: model.isChromeControlOn, title: model.hasChromeExtension ? "Turn On" : "Get Extension…") {
					model.turnOnChromeControl()
				}
			}
		}
	}

	private func status(isOn: Bool, title: String = "Turn On", action: @escaping () -> Void) -> some View {
		HStack(spacing: 10) {
			if isOn {
				StatusDot(text: "On", color: .green)
			} else {
				Text("Recommended").font(UI.caption).foregroundStyle(.tertiary)
				Button(title, action: action).buttonStyle(SubtleButtonStyle())
			}
		}
		.animation(.easeOut(duration: 0.2), value: isOn)
	}
}

/// The last step: what Bol does and who's responsible, acknowledged with one tick.
private struct TermsStep: View {
	@ObservedObject var model: OnboardingModel
	@ObservedObject var settings: SettingsModel

	private var isAgreed: Binding<Bool> {
		Binding(
			get: { model.isAgreeingToTerms || settings.config.hasAcceptedCurrentTerms },
			set: { model.isAgreeingToTerms = $0 })
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			SettingsGroup {
				point(
					"Acts without asking", icon: "bolt",
					text:
						"Permission checks are off: Bol runs commands, changes or deletes files, controls apps and sends messages without confirming."
				)
				point(
					"You're responsible", icon: "person",
					text:
						"For what you ask it to do and the results. AI makes mistakes: keep backups and check important work."
				)
				point(
					"Your accounts, their terms", icon: "link",
					text:
						"Bol uses your Claude subscription (including endpoints Anthropic doesn't publish) and any keys you add. Following those services' terms is up to you."
				)
				point(
					"No warranty", icon: "shield",
					text: "Free, open-source software, provided as is. Its authors aren't liable for damages."
				)
				point("Nothing collected", icon: "lock", text: "Everything stays in ~/.bol on this Mac.")
			}
			Toggle(isOn: isAgreed) {
				Text("I understand that Bol acts on my Mac without asking first.")
					.font(UI.body)
					.fixedSize(horizontal: false, vertical: true)
			}
			.toggleStyle(.checkbox)
			.disabled(settings.config.hasAcceptedCurrentTerms)
		}
	}

	/// A full-width row: icon, title, and the explanation under it.
	private func point(_ title: String, icon: String, text: String) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 10) {
			Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 16)
			VStack(alignment: .leading, spacing: 2) {
				Text(title).font(UI.bodyMedium)
				Text(text).font(UI.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
			}
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 9)
	}
}

private struct ReadyStep: View {
	@ObservedObject var model: OnboardingModel
	@ObservedObject var settings: SettingsModel

	var body: some View {
		VStack(alignment: .leading, spacing: 18) {
			if let talk = settings.config.shortcuts.talk {
				HStack(spacing: 12) {
					KeyCaps(shortcut: talk, size: 13)
					Text("Talk to Bol from any app").font(UI.bodyMedium)
					Spacer()
					Text("Change it in Settings → Shortcuts").font(UI.caption).foregroundStyle(.tertiary)
				}
			}
			SettingsGroup {
				SettingsRow("Launch at login", icon: "power", help: "Start Bol when you log in") {
					Toggle(
						"",
						isOn: Binding(
							get: { settings.isLaunchingAtLogin }, set: { settings.setLaunchAtLogin(isOn: $0) })
					)
					.labelsHidden().toggleStyle(.switch).controlSize(.small)
				}
			}
			SettingsGroup(title: "Summary") {
				SettingsRow("Claude Code", icon: "terminal") {
					summary(text: claudeCodeText, isOK: model.isComplete(step: .claudeCode))
				}
				SettingsRow("Account", icon: "person.crop.circle") {
					summary(text: accountText, isOK: model.isComplete(step: .account))
				}
				SettingsRow("Speech", icon: "mic") {
					summary(
						text: model.isComplete(step: .microphone) ? "Heard you" : "Not tested",
						isOK: model.isComplete(step: .microphone))
				}
				SettingsRow("Voice", icon: "speaker.wave.2") {
					summary(text: TextToSpeechProviders.active(config: settings.config).title, isOK: true)
				}
				SettingsRow("Dictation", icon: "text.cursor") {
					let dictation = settings.config.dictation
					summary(
						text: dictation.isEnabled ? "Hold \(dictation.key.title)" : "Off",
						isOK: dictation.isEnabled || !model.isDictationRecommended)
				}
				SettingsRow("Autonomy", icon: "bolt") {
					let parts = [
						model.isComputerUseOn ? "Computer use" : nil, model.isChromeControlOn ? "Chrome" : nil,
					].compactMap { $0 }
					summary(
						text: parts.isEmpty ? "Off" : parts.joined(separator: " + "),
						isOK: model.isComputerUseOn && model.isChromeControlOn)
				}
				SettingsRow("Permissions", icon: "lock.shield") {
					let count = settings.permissions.granted.count
					summary(
						text: "\(count) of \(MacPermission.allCases.count) granted",
						isOK: count == MacPermission.allCases.count)
				}
			}
		}
	}

	private var claudeCodeText: String {
		if case .installed(let version) = model.claudeCode { return "Version \(version)" }
		return "Not found"
	}

	private var accountText: String {
		if case .ready(let plan) = model.account { return plan ?? "Signed in" }
		return "Not verified"
	}

	private func summary(text: String, isOK: Bool) -> some View {
		StatusDot(text: text, color: isOK ? .green : .orange)
	}
}
