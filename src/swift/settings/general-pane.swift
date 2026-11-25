import AVFoundation
import AppKit
import ApplicationServices
import Combine
import ServiceManagement
import SwiftUI

// MARK: - General

struct GeneralPane: View {
	@ObservedObject var model: SettingsModel
	@ObservedObject private var updates = UpdateChecker.shared
	private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

	var body: some View {
		VStack(alignment: .leading, spacing: 22) {
			SettingsGroup(title: "Startup", footer: model.launchError) {
				SettingsRow("Launch at login", icon: "power") {
					Toggle(
						"", isOn: Binding(get: { model.isLaunchingAtLogin }, set: { model.setLaunchAtLogin(isOn: $0) })
					)
					.labelsHidden().toggleStyle(.switch).controlSize(.small)
				}
			}
			updatesGroup
			otherAudio
			SettingsGroup(title: "Files") {
				fileRow(label: "Settings", icon: "gearshape", url: Constants.configFile)
				fileRow(label: "Memory", icon: "tray.full", url: Constants.memoryDirectory)
				fileRow(label: "Log", icon: "doc.plaintext", url: Constants.logFile)
			}
			SettingsGroup(
				title: "Setup", footer: "Checks Claude Code, your Claude login, the microphone and the voice again."
			) {
				SettingsRow("First-run setup", icon: "checklist", help: "Signed out, or changed Macs? Run it again.") {
					Button("Run Setup Again") { model.onRunSetup?() }.buttonStyle(SubtleButtonStyle())
				}
			}
		}
		.onAppear { model.refreshPermissions() }
		.onReceive(tick) { _ in model.refreshPermissions() }
	}

	// MARK: Other apps

	private static let otherAudioOptions = OtherAudioBehavior.allCases.map {
		SelectOption(id: $0.rawValue, title: $0.title, subtitle: $0.subtitle)
	}

	/// Version, automatic updates, and checking or installing by hand.
	private var updatesGroup: some View {
		SettingsGroup(title: "Updates") {
			SettingsRow(
				"Version", icon: "info.circle",
				help: updates.isEnabled ? nil : "This build doesn't check for updates: pull and rebuild to update"
			) {
				Text("Bol \(UpdateChecker.currentVersion)").font(UI.body.monospacedDigit()).foregroundStyle(.secondary)
			}
			if updates.isEnabled { updateRows }
		}
	}

	/// Automatic updates, and checking or installing by hand: only when this build has an update feed.
	@ViewBuilder private var updateRows: some View {
		SettingsRow(
			"Install automatically", icon: "arrow.down.circle",
			help: "Downloads new versions and restarts Bol when it's idle"
		) {
			Toggle("", isOn: $model.config.isAutoUpdateEnabled).labelsHidden().toggleStyle(.switch)
				.controlSize(.small)
		}
		SettingsRow("Check for updates", icon: "arrow.triangle.2.circlepath", help: updateStatus) {
			if updates.status == .ready {
				Button("Restart to Update") { updates.install() }.buttonStyle(SubtleButtonStyle(isProminent: true))
			} else {
				Button("Check Now") { updates.checkNow() }.buttonStyle(SubtleButtonStyle())
					.disabled([.checking, .downloading, .installing].contains(updates.status))
			}
		}
	}

	private var updateStatus: String {
		let version = updates.available?.version ?? ""
		switch updates.status {
		case .idle: return "Checked at launch and every 6 hours"
		case .checking: return "Checking…"
		case .upToDate: return "Up to date"
		case .downloading: return "Downloading \(version)…"
		case .ready: return "\(version) is ready to install"
		case .installing: return "Installing…"
		case .manual(let why): return version.isEmpty ? why : "\(version) is available. \(why)"
		}
	}

	/// Other apps' sound for the whole conversation: while you speak and while Bol speaks.
	private var otherAudio: some View {
		let behavior = model.config.otherAudio
		let isTapped = behavior == .lower || behavior == .mute
		let isGranted = model.permissions.isGranted(permission: .systemAudio)
		return SettingsGroup(title: "Other apps") {
			SettingsRow(
				"During conversations", icon: "speaker.wave.1", help: "Music and videos, while you or Bol are speaking"
			) {
				Select(
					options: Self.otherAudioOptions,
					selection: Binding(
						get: { model.config.otherAudio.rawValue },
						set: { model.config.otherAudio = OtherAudioBehavior(rawValue: $0) ?? .lower }))
			}
			if behavior == .lower {
				SettingsRow("Lower to", icon: "slider.horizontal.3", help: "Percent of their current volume") {
					ValueSlider(value: $model.config.otherAudioLevel, range: 0.05...0.8, step: 0.05) {
						"\(Int(($0 * 100).rounded()))%"
					}
				}
			}
			if isTapped, !isGranted {
				SettingsRow(
					MacPermission.systemAudio.title, icon: MacPermission.systemAudio.icon,
					help: "macOS asks for this before any app can adjust other apps' sound"
				) {
					HStack(spacing: 10) {
						StatusDot(text: "Not granted", color: .orange)
						Button("Allow") { MacPermission.systemAudio.request() }.buttonStyle(SubtleButtonStyle())
					}
				}
			}
		}
		.animation(.easeOut(duration: 0.2), value: behavior)
		.animation(.easeOut(duration: 0.2), value: isGranted)
	}

	private func fileRow(label: String, icon: String, url: URL) -> some View {
		SettingsRow(label, icon: icon) {
			HStack(spacing: 8) {
				Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(
					.system(size: 12, design: .monospaced)
				).foregroundStyle(.secondary).textSelection(.enabled)
				IconButton(symbol: "arrow.up.forward.square", help: "Open") { NSWorkspace.shared.open(url) }
			}
		}
	}
}
