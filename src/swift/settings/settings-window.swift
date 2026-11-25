import AVFoundation
import AppKit
import ApplicationServices
import Combine
import ServiceManagement
import SwiftUI

// MARK: - Window content

struct SettingsView: View {
	static let width: CGFloat = 860
	@ObservedObject var model: SettingsModel
	@AppStorage("settingsPane") private var paneRaw = Pane.assistant.rawValue
	@State private var isShowingSaved = false
	@State private var hideSavedWork: DispatchWorkItem?

	private var pane: Pane { Pane(rawValue: paneRaw) ?? .assistant }

	/// Re-checks Claude Code while it's blocking, so Settings unlocks by itself after sign-in.
	private let engineRecheck = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

	var body: some View {
		Group {
			// Claude Code not ready blocks all of Settings: nothing else works without it.
			switch model.engine?.isReady {
			case true?: panes
			case false?: blocker
			case nil: checking
			}
		}
		// A fixed size: given a range, the window opens at the minimum, which is narrower than the
		// sidebar plus a pane's rows (label + control columns), and clips both edges.
		.frame(width: Self.width)
		.frame(height: 620)
		.background(Color(nsColor: .windowBackgroundColor))
		.onAppear { model.checkEngine() }
	}

	private var checking: some View {
		HStack(spacing: 10) {
			ProgressView().controlSize(.small)
			Text("Checking Claude Code…").font(UI.body).foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	@ViewBuilder private var blocker: some View {
		if let engine = model.engine {
			ScrollView {
				EngineSetupView(model: model, status: engine)
					.padding(.horizontal, 36)
					.padding(.top, 44)
					.padding(.bottom, 28)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			.onReceive(engineRecheck) { _ in model.checkEngine() }
		}
	}

	private var panes: some View {
		HStack(spacing: 0) {
			sidebar
			Rectangle().fill(UI.hairline).frame(width: 1)
				.ignoresSafeArea(edges: .top)  // run the full height, under the title bar
			VStack(spacing: 0) {
				header
				ScrollView {
					Group {
						switch pane {
						case .voice: VoicePane(model: model)
						case .assistant: AssistantPane(model: model)
						case .listening: ListeningPane(model: model)
						case .dictation: DictationPane(model: model, history: model.dictations)
						case .shortcuts: ShortcutsPane(model: model)
						case .memory: MemoryPane(model: model)
						case .general: GeneralPane(model: model)
						}
					}
					.padding(.horizontal, 28)
					.padding(.top, 6)
					.padding(.bottom, 28)
					.frame(maxWidth: .infinity, alignment: .leading)
					.id(pane)
					.transition(.opacity)
				}
			}
		}
		.onChange(of: model.savedAt) { _ in flashSaved() }
	}

	private var header: some View {
		HStack(alignment: .firstTextBaseline) {
			Text(pane.title).font(.system(size: 20, weight: .semibold))
			Spacer()
			if isShowingSaved {
				HStack(spacing: 5) {
					Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
					Text("Saved")
				}
				.font(UI.caption)
				.foregroundStyle(.secondary)
				.transition(.opacity.combined(with: .move(edge: .trailing)))
			}
		}
		.padding(.horizontal, 28)
		.padding(.top, 8)
		.padding(.bottom, 16)
	}

	private func flashSaved() {
		withAnimation(.easeOut(duration: 0.15)) { isShowingSaved = true }
		hideSavedWork?.cancel()
		let w = DispatchWorkItem { withAnimation(.easeIn(duration: 0.4)) { isShowingSaved = false } }
		hideSavedWork = w
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: w)
	}

	private var sidebar: some View {
		VStack(alignment: .leading, spacing: 2) {
			Spacer().frame(height: 4)
			HStack(spacing: 9) {
				Image(nsImage: NSApp.applicationIconImage)
					.resizable()
					.frame(width: 30, height: 30)
				VStack(alignment: .leading, spacing: 0) {
					Text("Bol").font(.system(size: 15, weight: .bold, design: .rounded))
					Text("Settings").font(UI.caption).foregroundStyle(.secondary)
				}
			}
			.padding(.horizontal, 8)
			.padding(.bottom, 18)
			ForEach(Pane.allCases) { p in
				SidebarItem(pane: p, isSelected: p == pane) {
					withAnimation(.easeOut(duration: 0.12)) { paneRaw = p.rawValue }
				}
			}
			Spacer()
			VStack(alignment: .leading, spacing: 8) {
				if let talk = model.config.shortcuts.talk {
					HStack(spacing: 7) {
						Text("Talk").foregroundStyle(.tertiary)
						KeyCaps(shortcut: talk, size: 10)
					}
				}
				VersionFooter(updates: UpdateChecker.shared)
			}
			.font(UI.caption)
			.padding(.horizontal, 12)
			.padding(.bottom, 14)
		}
		.padding(.horizontal, 10)
		.frame(width: 200)
		.background(Color.black.opacity(0.12))
	}
}

struct SidebarItem: View {
	let pane: Pane
	let isSelected: Bool
	let action: () -> Void
	@State private var isHovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 10) {
				Image(systemName: pane.icon)
					.font(.system(size: 14, weight: .regular))
					.frame(width: 20)
					.foregroundStyle(isSelected ? .primary : .secondary)
				Text(pane.title)
					.font(.system(size: 13, weight: isSelected ? .semibold : .regular))
					.foregroundStyle(isSelected ? .primary : .secondary)
				Spacer()
			}
			.padding(.horizontal, 10)
			.frame(height: 32)
			.background(
				RoundedRectangle(cornerRadius: 7, style: .continuous)
					.fill(Color.primary.opacity(isSelected ? 0.10 : isHovering ? 0.05 : 0))
			)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { isHovering = $0 }
		.animation(.easeOut(duration: 0.1), value: isHovering)
	}
}

// MARK: - Window

final class SettingsWindowController: NSObject, NSWindowDelegate {
	let model: SettingsModel
	private var window: NSWindow?

	init(model: SettingsModel) { self.model = model }

	func show() {
		if window == nil {
			let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
			w.title = "Bol Settings"
			w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
			w.titlebarAppearsTransparent = true
			w.titleVisibility = .hidden
			w.isMovableByWindowBackground = true
			w.isReleasedWhenClosed = false
			w.delegate = self
			w.initialFirstResponder = nil
			w.center()
			window = w
		}
		model.refreshPermissions()
		if let window { AppPresence.show(window: window) }
		// Don't drop the user into a text field (it would select the API key).
		DispatchQueue.main.async { self.window?.makeFirstResponder(nil) }
	}

	func windowWillClose(_ notification: Notification) {
		model.onStopSample?()
		AppPresence.windowClosed()
		// Let the window and its views go: their timers (permission checks, plan usage, the Claude Code
		// recheck) would otherwise keep firing behind a closed window. `show()` builds a new one.
		DispatchQueue.main.async { [weak self] in
			guard let self, self.window?.isVisible != true else { return }
			self.window?.delegate = nil
			self.window = nil
		}
	}
}

/// The bottom of the Settings sidebar: an "Update to x" pill once an update is ready, and Bol's version.
private struct VersionFooter: View {
	@ObservedObject var updates: UpdateChecker

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			if updates.status == .ready, let version = updates.available?.version {
				Button {
					updates.install()
				} label: {
					HStack(spacing: 5) {
						Image(systemName: "arrow.down.circle.fill")
						Text("Update to \(version)")
					}
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(.white)
					.padding(.horizontal, 9)
					.padding(.vertical, 4)
					.background(Color.accentColor, in: Capsule())
					.fixedSize()
				}
				.buttonStyle(.plain)
				.help("Restarts Bol to finish updating")
			}
			Text(
				updates.status == .downloading
					? "Bol \(UpdateChecker.currentVersion) · updating…" : "Bol \(UpdateChecker.currentVersion)"
			)
			.foregroundStyle(.tertiary)
			.monospacedDigit()
			.lineLimit(1)
		}
	}
}
