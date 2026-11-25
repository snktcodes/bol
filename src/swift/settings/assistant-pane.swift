import AVFoundation
import AppKit
import ApplicationServices
import Combine
import ServiceManagement
import SwiftUI

// MARK: - Assistant

struct AssistantPane: View {
	@ObservedObject var model: SettingsModel
	private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

	/// Settings only shows panes once Claude Code is ready (see SettingsView), so the engine is known here.
	var body: some View {
		if let engine = model.engine { content(engine: engine) }
	}

	private func engineCard(engine e: EngineStatus) -> some View {
		SettingsGroup(title: "Engine", trailing: AnyView(brainStatus)) {
			HStack(alignment: .top, spacing: 12) {
				Image(systemName: "terminal")
					.font(.system(size: 18, weight: .regular))
					.foregroundStyle(.primary)
					.frame(width: 36, height: 36)
					.background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
				VStack(alignment: .leading, spacing: 3) {
					Text("Powered by Claude Code · Agent SDK").font(.system(size: 14, weight: .semibold))
					Text(
						"Everything Bol thinks and does runs in a Claude Code session through the Claude Agent SDK, on your \(e.account?.plan ?? "Claude") subscription. No API key is used."
					)
					.font(UI.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
				}
				Spacer(minLength: 0)
			}
			.padding(14)
			SettingsRow(
				"Claude Code", icon: "terminal",
				help: ClaudeCode.executable?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
			) {
				Text("v\(e.claudeVersion ?? "?")").font(UI.body.monospacedDigit()).foregroundStyle(.secondary)
			}
			SettingsRow("Account", icon: "person.crop.circle") {
				StatusDot(text: "\(e.account?.plan ?? "Claude") · signed in", color: .green)
			}
		}
	}

	private func content(engine: EngineStatus) -> some View {
		VStack(alignment: .leading, spacing: 22) {
			engineCard(engine: engine)
			HealthCard(model: model)
			UsageCard(model: model)
			SettingsGroup(title: "Claude") {
				SettingsRow("Model", icon: "sparkle") {
					Select(
						options: Self.claudeModels,
						selection: Binding(
							get: { model.config.claudeModel.rawValue },
							set: { model.config.claudeModel = ClaudeModel(rawValue: $0) ?? .opus }))
				}
				SettingsRow(
					"Effort", icon: "gauge.with.dots.needle.50percent", help: "How hard Claude thinks before answering"
				) {
					Select(
						options: Self.efforts,
						selection: Binding(
							get: { model.config.claudeEffort.rawValue },
							set: { model.config.claudeEffort = ClaudeEffort(rawValue: $0) ?? .medium }))
				}
				SettingsRow(
					"Working folder", icon: "folder",
					help: "Where commands start. Bol's own folder keeps its threads out of your Claude Code history"
				) {
					HStack(spacing: 8) {
						Text(
							(model.config.workingDirectory ?? Constants.workspaceDirectory.path).replacingOccurrences(
								of: NSHomeDirectory(), with: "~")
						)
						.font(.system(size: 12, design: .monospaced))
						.foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
						Spacer(minLength: 0)
						Button("Choose…") { chooseFolder() }.buttonStyle(SubtleButtonStyle())
					}
					.frame(width: UI.controlWidth)
				}
			}

			InstructionsEditor(model: model)

			MCPServersSection(model: model)

			SkillsSection(model: model)

			SettingsGroup(title: "Access") {
				SettingsRow("Control Chrome", icon: "globe", help: "Use your real Chrome and logins") {
					Toggle("", isOn: $model.config.isChromeEnabled).labelsHidden().toggleStyle(.switch).controlSize(
						.small)
				}
				SettingsRow(
					"See and control your screen", icon: "eye",
					help: "Screenshots, clicks and typing, only when a request needs them"
				) {
					Select(
						options: [
							SelectOption(
								id: "auto", title: "Automatic",
								subtitle: "Bol looks when your request refers to the screen"),
							SelectOption(id: "off", title: "Off", subtitle: "Bol can't see your screen"),
						], selection: $model.config.screenAccess.rawValue)
				}
			}

			SettingsGroup(
				title: "Mac permissions",
				footer: "Bol needs these to control apps and see your screen. Changes are picked up automatically."
			) {
				ForEach(MacPermission.allCases) { permission in permissionRow(permission: permission) }
			}

			SettingsGroup(title: "Conversation") {
				SettingsRow("Follow-up listening", icon: "ear", help: "Listen briefly after each reply") {
					Toggle("", isOn: $model.config.isFollowUpEnabled).labelsHidden().toggleStyle(.switch).controlSize(
						.small)
				}
				if model.config.isFollowUpEnabled {
					SettingsRow("Follow-up window", icon: "timer") {
						ValueSlider(value: $model.config.followUpSeconds, range: 2...15, step: 1) { "\(Int($0))s" }
					}
				}
				SettingsRow("History", icon: "clock.arrow.circlepath", help: "Clear what Bol remembers from this chat")
				{
					NewConversationButton { model.onNewConversation?() }
				}
			}
		}
		.onAppear { model.refreshPermissions() }
		.onReceive(tick) { _ in model.refreshPermissions() }
	}

	static let claudeModels = ClaudeModel.allCases.map {
		SelectOption(id: $0.rawValue, title: $0.title, subtitle: $0.subtitle)
	}
	static let efforts = ClaudeEffort.allCases.map {
		SelectOption(id: $0.rawValue, title: $0.title, subtitle: $0.subtitle)
	}

	private var brainStatus: some View {
		Group {
			switch model.brainState {
			case .restarting: StatusDot(text: "Restarting…", color: .orange, isSpinning: true)
			case .ready: StatusDot(text: "Ready", color: .green)
			}
		}
		.animation(.easeOut(duration: 0.2), value: model.brainState)
	}

	private func permissionRow(permission: MacPermission) -> some View {
		let isGranted = model.permissions.isGranted(permission: permission)
		return SettingsRow(permission.title, icon: permission.icon, help: permission.purpose) {
			HStack(spacing: 10) {
				StatusDot(text: isGranted ? "Granted" : "Not granted", color: isGranted ? .green : .orange)
				if !isGranted {
					Button("Open Settings") { permission.request() }
						.buttonStyle(SubtleButtonStyle())
				}
			}
			.animation(.easeOut(duration: 0.2), value: isGranted)
		}
	}

	private func chooseFolder() {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.prompt = "Use Folder"
		panel.directoryURL = URL(fileURLWithPath: model.config.workingDirectory ?? Constants.workspaceDirectory.path)
		if panel.runModal() == .OK, let url = panel.url { model.config.workingDirectory = url.path }
	}
}

/// Two-step button: first click arms, second confirms. Shows a brief "Cleared" state.
struct NewConversationButton: View {
	let action: () -> Void
	private enum Phase { case idle, armed, cleared }
	@State private var phase = Phase.idle
	var body: some View {
		Button {
			switch phase {
			case .armed:
				action()
				phase = .cleared
				DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if phase == .cleared { phase = .idle } }
			case .idle, .cleared:
				phase = .armed
				DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if phase == .armed { phase = .idle } }
			}
		} label: {
			Group {
				switch phase {
				case .idle: Text("Start New Conversation")
				case .armed: Text("Click again to clear")
				case .cleared: Text("Cleared ✓")
				}
			}
			.frame(minWidth: 160)
		}
		.buttonStyle(SubtleButtonStyle())
		.foregroundStyle(phase == .armed ? .red : .primary)
		.animation(.easeOut(duration: 0.15), value: phase)
	}
}

/// Everything Bol relies on, checked live (see ServiceHealth), with what to do when something fails.
struct HealthCard: View {
	@ObservedObject var model: SettingsModel
	@ObservedObject private var health = ServiceHealth.shared
	@AppStorage("settingsPane") private var paneRaw = Pane.assistant.rawValue

	var body: some View {
		SettingsGroup(
			title: "Health", footer: footer, trailing: AnyView(trailing)
		) {
			ForEach(ServiceHealth.Item.allCases) { item in
				row(item: item, status: health.status(item: item))
			}
		}
		.onAppear { if health.checkedAt == nil { health.run(config: model.config) } }
	}

	private var footer: String? {
		guard case .problem = health.status(item: .speechToText) else { return nil }
		return
			"Listening uses the speech-to-text behind Claude Code's /voice, which isn't a public Anthropic API and can change without notice."
	}

	private var trailing: some View {
		HStack(spacing: 8) {
			if let t = health.checkedAt {
				TimelineView(.periodic(from: t, by: 30)) { ctx in
					let s = Int(ctx.date.timeIntervalSince(t))
					Text(s < 45 ? "Checked just now" : "Checked \(s / 60)m ago").font(UI.caption).foregroundStyle(
						.tertiary)
				}
			}
			IconButton(symbol: "arrow.clockwise", help: "Check again", isSpinning: health.isChecking) {
				health.run(config: model.config)
			}
		}
	}

	@ViewBuilder private func row(item: ServiceHealth.Item, status: ServiceHealth.Status) -> some View {
		switch status {
		case .unknown:
			SettingsRow(item.title, icon: item.icon) { StatusDot(text: "Not checked", color: .secondary) }
		case .checking:
			SettingsRow(item.title, icon: item.icon) {
				StatusDot(text: "Checking…", color: .secondary, isSpinning: true)
			}
		case .ok(let text):
			SettingsRow(item.title, icon: item.icon) { StatusDot(text: text, color: .green) }
		case .problem(let problem):
			SettingsRow(item.title, icon: item.icon, help: "\(problem.title). \(problem.detail)") {
				HStack(spacing: 8) {
					if let fix = fixButton(fix: problem.fix) { fix }
					StatusDot(
						text: item.isEssential ? "Not working" : "Unavailable", color: item.isEssential ? .red : .orange
					)
				}
			}
		}
	}

	private func fixButton(fix: ServiceProblem.Fix) -> AnyView? {
		let (title, action): (String, () -> Void)
		switch fix {
		case .useOpenAIForListening:
			(title, action) = ("Use OpenAI", { paneRaw = Pane.listening.rawValue })
		case .signInToClaude:
			(title, action) = ("Sign In", { Terminal.run(command: "\(ClaudeCode.shellPath) auth login") })
		case .installClaudeCode:
			(title, action) = ("Run Setup", { model.onRunSetup?() })
		case .tryAgain, .checkConnection:
			(title, action) = ("Try Again", { health.run(config: model.config) })
		case .none:
			return nil
		}
		return AnyView(Button(title, action: action).buttonStyle(SubtleButtonStyle()))
	}
}

/// Claude plan usage (same numbers as Claude Code's /usage).
struct UsageCard: View {
	@ObservedObject var model: SettingsModel
	private let refresh = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

	var body: some View {
		SettingsGroup(title: "Plan usage", trailing: AnyView(trailing)) {
			if model.usage.isEmpty {
				SettingsRow(model.usageError == nil ? "Loading usage…" : "Usage unavailable", icon: "chart.bar") {
					if model.isLoadingUsage {
						ProgressView().controlSize(.small)
					} else if let e = model.usageError {
						Text(e).font(UI.caption).foregroundStyle(.secondary)
					}
				}
			}
			ForEach(model.usage) { limit in
				UsageRow(limit: limit)
			}
		}
		.onAppear { model.loadUsage() }
		.onReceive(refresh) { _ in model.loadUsage() }
	}

	private var trailing: some View {
		HStack(spacing: 8) {
			if let t = model.usageUpdatedAt {
				TimelineView(.periodic(from: t, by: 30)) { ctx in
					Text(updatedText(updatedAt: t, now: ctx.date)).font(UI.caption).foregroundStyle(.tertiary)
				}
			}
			IconButton(symbol: "arrow.clockwise", help: "Refresh", isSpinning: model.isLoadingUsage) {
				model.loadUsage()
			}
			IconButton(symbol: "arrow.up.forward.square", help: "Open usage on claude.ai") {
				NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
			}
		}
	}

	private func updatedText(updatedAt t: Date, now: Date) -> String {
		let s = Int(now.timeIntervalSince(t))
		return s < 45 ? "Updated just now" : "Updated \(s / 60)m ago"
	}
}

struct UsageRow: View {
	let limit: PlanLimit
	@State private var shown: Double = 0

	private var tint: Color {
		switch limit.severity {
		case .critical: return .red
		case .warning: return .orange
		case .normal: return limit.percent >= 90 ? .red : limit.percent >= 75 ? .orange : .green
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(alignment: .firstTextBaseline) {
				Text(limit.title).font(UI.body)
				if limit.isActive {
					Text("Active").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
						.padding(.horizontal, 5).padding(.vertical, 1)
						.background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
				}
				Spacer()
				Text("\(Int(limit.percent.rounded()))% used").font(UI.body.monospacedDigit())
					.foregroundStyle(limit.percent >= 75 ? tint : .secondary)
			}
			GeometryReader { geo in
				ZStack(alignment: .leading) {
					Capsule().fill(Color.primary.opacity(0.08))
					Capsule().fill(tint.gradient)
						.frame(width: max(limit.percent > 0 ? 4 : 0, geo.size.width * min(1, shown / 100)))
				}
			}
			.frame(height: 6)
			Text(PlanUsage.resetText(date: limit.resetsAt)).font(UI.caption).foregroundStyle(.secondary)
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 12)
		.onAppear { withAnimation(.easeOut(duration: 0.6)) { shown = limit.percent } }
		.onChange(of: limit.percent) { v in withAnimation(.easeOut(duration: 0.4)) { shown = v } }
	}
}

/// The instructions Bol adds on top of Claude Code's own system prompt.
struct InstructionsEditor: View {
	@ObservedObject var model: SettingsModel
	@State private var draft = ""
	@State private var isLoaded = false
	@FocusState private var isFocused: Bool

	private var applied: String { model.prompts?.current ?? "" }
	private var isDirty: Bool { isLoaded && draft.trimmingCharacters(in: .whitespacesAndNewlines) != applied }
	private var isDefault: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines) == model.prompts?.defaultText }

	var body: some View {
		SettingsGroup(
			title: "Instructions",
			footer:
				"Sent with every session, on top of Claude Code's own system prompt. Bol always adds its safety rules too: deleted files go to the Trash, never away for good. Applying restarts the brain; the conversation continues.",
			trailing: AnyView(badge)
		) {
			VStack(alignment: .leading, spacing: 10) {
				TextEditor(text: $draft)
					.font(.system(size: 12, design: .monospaced))
					.scrollContentBackground(.hidden)
					.focused($isFocused)
					.frame(height: 190)
					.padding(8)
					.background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
					.overlay(
						RoundedRectangle(cornerRadius: 7, style: .continuous)
							.strokeBorder(
								isFocused ? Color.accentColor.opacity(0.8) : UI.hairline, lineWidth: isFocused ? 1.5 : 1
							))
				HStack(spacing: 8) {
					Text("\(draft.count) characters").font(UI.caption.monospacedDigit()).foregroundStyle(.tertiary)
					Spacer()
					Button("Reset to Default") { draft = model.prompts?.defaultText ?? "" }
						.buttonStyle(SubtleButtonStyle())
						.disabled(isDefault)
					Button("Discard") { draft = applied }
						.buttonStyle(SubtleButtonStyle())
						.disabled(!isDirty)
					Button("Apply") { model.applyPrompt(text: draft) }
						.buttonStyle(SubtleButtonStyle(isProminent: true))
						.keyboardShortcut("s", modifiers: .command)
						.disabled(!isDirty)
				}
			}
			.padding(12)
		}
		.onAppear {
			if let prompts = model.prompts { load(prompts: prompts) } else { model.loadPrompts() }
		}
		.onChange(of: model.prompts) { prompts in
			if let prompts { load(prompts: prompts) }
		}
	}

	/// Fills the editor once, when the prompts first arrive.
	private func load(prompts: Prompts) {
		guard !isLoaded else { return }
		draft = prompts.current
		isLoaded = true
	}

	private var badge: some View {
		Group {
			if isDirty {
				StatusDot(text: "Unsaved changes", color: .orange)
			} else if model.prompts?.customText != nil {
				StatusDot(text: "Customized", color: .accentColor)
			} else {
				StatusDot(text: "Default", color: .secondary.opacity(0.6))
			}
		}
		.animation(.easeOut(duration: 0.15), value: isDirty)
	}
}

/// Shown instead of the Assistant settings when Claude Code / the Agent SDK isn't usable.
struct EngineSetupView: View {
	@ObservedObject var model: SettingsModel
	let status: EngineStatus
	@State private var copied: String?

	var body: some View {
		VStack(alignment: .leading, spacing: 22) {
			VStack(alignment: .leading, spacing: 10) {
				Image(systemName: "terminal")
					.font(.system(size: 26, weight: .light))
					.foregroundStyle(.secondary)
					.frame(width: 52, height: 52)
					.background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
				Text("Claude Code isn't ready").font(.system(size: 17, weight: .semibold))
				Text(
					"Bol thinks and acts through Claude Code and your Claude subscription. Finish the steps below; Bol starts as soon as both are done."
				)
				.font(UI.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
			}

			SettingsGroup(title: "Setup") {
				ForEach(Array(status.steps.enumerated()), id: \.element.id) { i, step in
					stepRow(step: step, number: i + 1, isBlocked: status.steps[..<i].contains { !$0.isDone })
				}
			}

			HStack(spacing: 10) {
				Button {
					model.checkEngine()
				} label: {
					HStack(spacing: 7) {
						if model.isCheckingEngine {
							ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
							Text("Checking…")
						} else {
							Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
							Text("Check Again")
						}
					}
					.frame(minWidth: 120)
				}
				.buttonStyle(SubtleButtonStyle(isProminent: true))
				.disabled(model.isCheckingEngine)
				Text("\(status.steps.filter(\.isDone).count) of \(status.steps.count) done")
					.font(UI.caption).foregroundStyle(.secondary)
			}
		}
	}

	private func stepRow(step: EngineStatus.Step, number: Int, isBlocked: Bool) -> some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack(spacing: 10) {
				ZStack {
					Circle().fill(step.isDone ? Color.green.opacity(0.18) : Color.primary.opacity(0.07)).frame(
						width: 22, height: 22)
					if step.isDone {
						Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.green)
					} else {
						Text("\(number)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
					}
				}
				VStack(alignment: .leading, spacing: 1) {
					Text(step.title).font(UI.bodyMedium)
					Text(step.detail).font(UI.caption).foregroundStyle(step.isDone ? Color.secondary : Color.orange)
				}
				Spacer()
			}
			if !step.isDone {
				let cmd = step.fixCommand
				VStack(alignment: .leading, spacing: 6) {
					Text(step.fixHint).font(UI.caption).foregroundStyle(.secondary)
					HStack(spacing: 8) {
						Text(cmd)
							.font(.system(size: 12, design: .monospaced))
							.textSelection(.enabled)
							.lineLimit(1).truncationMode(.middle)
							.padding(.horizontal, 10).frame(height: 28)
							.frame(maxWidth: .infinity, alignment: .leading)
							.background(
								Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6, style: .continuous)
							)
							.overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(UI.hairline))
						Button(copied == step.id ? "Copied" : "Copy") {
							NSPasteboard.general.clearContents()
							NSPasteboard.general.setString(cmd, forType: .string)
							copied = step.id
							DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
								if copied == step.id { copied = nil }
							}
						}
						.buttonStyle(SubtleButtonStyle())
						Button("Run in Terminal") { Terminal.run(command: cmd) }
							.buttonStyle(SubtleButtonStyle())
					}
				}
				.padding(.leading, 32)
				.opacity(isBlocked ? 0.5 : 1)
			}
		}
		.padding(14)
	}
}
