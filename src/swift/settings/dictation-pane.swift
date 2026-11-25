import AppKit
import Combine
import SwiftUI

// MARK: - Dictation

/// Dictation: hold a key in any app, speak, let go, and the text is pasted where you type.
struct DictationPane: View {
	@ObservedObject var model: SettingsModel
	@ObservedObject var history: DictationHistory
	private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
	@State private var isGlobeKeyDoingNothing = GlobeKeyAction.isDoingNothing
	@State private var runningApps = DictationApps.running()

	static let keyOptions = DictationKey.allCases.map {
		SelectOption(
			id: $0.rawValue, title: $0.title,
			subtitle: $0 == .fn ? "The Globe key on Apple keyboards" : "Held on its own")
	}

	private var settings: Binding<DictationSettings> { $model.config.dictation }

	var body: some View {
		VStack(alignment: .leading, spacing: 22) {
			SettingsGroup(
				title: "Dictate anywhere",
				footer:
					"Hold the key in any app, speak, and let go: what you said is pasted where you're typing. A quick tap does nothing; double-tap to keep dictating hands-free, then tap once to paste. Esc cancels."
			) {
				SettingsRow("Dictation", icon: "text.cursor") {
					Toggle("", isOn: settings.isEnabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
				}
				if model.config.dictation.isEnabled {
					SettingsRow("Hold to dictate", icon: "keyboard") {
						Select(
							options: Self.keyOptions,
							selection: Binding(
								get: { model.config.dictation.key.rawValue },
								set: { model.config.dictation.key = DictationKey(rawValue: $0) ?? .fn }))
					}
					SettingsRow("Double-tap to lock", icon: "lock", help: "Keep dictating without holding the key") {
						Toggle("", isOn: settings.isDoubleTapLockEnabled).labelsHidden().toggleStyle(.switch)
							.controlSize(.small)
					}
					SettingsRow("Paste last dictation", icon: "doc.on.clipboard", help: "Pastes it again, anywhere") {
						ShortcutRecorder(settings: $model.config.shortcuts, action: .pasteLastDictation)
					}
					SettingsRow(
						"Speech to text", icon: "text.bubble", help: "The provider set under Listening"
					) {
						Text(SpeechToTextProviders.active(config: model.config).title).font(UI.body)
							.foregroundStyle(.secondary)
					}
				}
			}
			if model.config.dictation.isEnabled { setup }
			RecentDictations(history: history)
		}
		.onAppear(perform: refresh)
		.onReceive(tick) { _ in refresh() }
	}

	private func refresh() {
		model.refreshPermissions()
		isGlobeKeyDoingNothing = GlobeKeyAction.isDoingNothing
		runningApps = DictationApps.running()
	}

	/// What still stands between the key and a paste, if anything.
	@ViewBuilder private var setup: some View {
		let isAccessibilityGranted = model.permissions.isGranted(permission: .accessibility)
		let isGlobeKeyBusy = model.config.dictation.key == .fn && !isGlobeKeyDoingNothing
		if !isAccessibilityGranted || isGlobeKeyBusy || !runningApps.isEmpty {
			SettingsGroup(title: "Before you start") {
				if !isAccessibilityGranted {
					SettingsRow(
						MacPermission.accessibility.title, icon: MacPermission.accessibility.icon,
						help: "Needed to notice the key in other apps and to paste"
					) {
						HStack(spacing: 10) {
							StatusDot(text: "Not granted", color: .orange)
							Button("Allow") { MacPermission.accessibility.request() }.buttonStyle(SubtleButtonStyle())
						}
					}
				}
				if isGlobeKeyBusy {
					SettingsRow(
						"Globe key", icon: "globe",
						help: "macOS acts on fn too: set “Press fn key to” to “Do Nothing”"
					) {
						Button("Open Keyboard Settings") { NSWorkspace.shared.open(GlobeKeyAction.settingsURL) }
							.buttonStyle(SubtleButtonStyle())
					}
				}
				if !runningApps.isEmpty {
					SettingsRow(
						"\(DictationApps.list(apps: runningApps)) \(runningApps.count == 1 ? "is" : "are") running",
						icon: "exclamationmark.triangle",
						help: "If one uses the same key, both will paste. Use another key, or turn dictation off here."
					) {
						Text("Use another key in one of them").font(UI.caption).foregroundStyle(.secondary)
					}
				}
			}
		}
	}
}

/// The week's dictations, newest first: copy one, or clear them all.
private struct RecentDictations: View {
	@ObservedObject var history: DictationHistory
	private static let shownCount = 8

	var body: some View {
		SettingsGroup(
			title: "Recent",
			footer: "Kept for \(DictationHistory.keepDays) days, only on this Mac.",
			trailing: history.records.isEmpty
				? nil
				: AnyView(
					Button("Clear") { history.clear() }.buttonStyle(.plain).font(UI.caption).foregroundStyle(.secondary)
				)
		) {
			if history.records.isEmpty {
				Text("Nothing dictated yet")
					.font(UI.body).foregroundStyle(.tertiary)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.horizontal, 14).padding(.vertical, 12)
			}
			ForEach(history.records.prefix(Self.shownCount)) { record in
				DictationRow(record: record)
			}
		}
	}
}

private struct DictationRow: View {
	let record: DictationRecord
	@State private var isHovering = false
	@State private var hasCopied = false

	var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 12) {
			VStack(alignment: .leading, spacing: 3) {
				Text(record.text).font(UI.body).lineLimit(2).truncationMode(.tail)
					.frame(maxWidth: .infinity, alignment: .leading)
				Text(
					[record.app, Format.relative(date: record.at, now: Date())].compactMap { $0 }.joined(
						separator: " · ")
				)
				.font(UI.caption).foregroundStyle(.tertiary)
			}
			Button {
				Paster.copy(text: record.text)
				hasCopied = true
				DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { hasCopied = false }
			} label: {
				Image(systemName: hasCopied ? "checkmark" : "doc.on.doc").font(.system(size: 11, weight: .medium))
					.frame(width: 22, height: 22).contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.foregroundStyle(.secondary)
			.opacity(isHovering || hasCopied ? 1 : 0)
			.help("Copy")
		}
		.padding(.horizontal, 14).padding(.vertical, 9)
		.contentShape(Rectangle())
		.onHover { isHovering = $0 }
	}
}
