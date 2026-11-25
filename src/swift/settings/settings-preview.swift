import AppKit
import SwiftUI

/// Debug aid: `Bol --render-settings <dir>` renders each Settings pane to a PNG and logs the width
/// it asks for, which must fit the window's content column.
enum SettingsPreview {
	/// The window's widest content column: 860 minus the sidebar, its hairline and the padding.
	static let columnWidth: CGFloat = SettingsView.width - 200 - 1 - 56

	@MainActor static func render(to directory: String) {
		try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
		for pane in Pane.allCases {
			let model = SettingsModel(config: Config())
			let content: AnyView
			switch pane {
			case .assistant: content = AnyView(AssistantPane(model: model))
			case .voice: content = AnyView(VoicePane(model: model))
			case .listening: content = AnyView(ListeningPane(model: model))
			case .dictation: content = AnyView(DictationPane(model: model, history: model.dictations))
			case .shortcuts: content = AnyView(ShortcutsPane(model: model))
			case .memory: content = AnyView(MemoryPane(model: model))
			case .general: content = AnyView(GeneralPane(model: model))
			}
			let natural = NSHostingView(rootView: content.fixedSize())
			let wanted = natural.fittingSize
			print("\(pane.rawValue): wants \(Int(wanted.width)) × \(Int(wanted.height)), column is \(Int(columnWidth))")
			let host = NSHostingView(
				rootView: content.frame(width: columnWidth).padding(28)
					.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
			host.appearance = NSAppearance(named: .darkAqua)
			host.frame = NSRect(origin: .zero, size: host.fittingSize)
			host.layoutSubtreeIfNeeded()
			RunLoop.current.run(until: Date().addingTimeInterval(0.3))
			guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
			host.cacheDisplay(in: host.bounds, to: rep)
			try? rep.representation(using: .png, properties: [:])?.write(
				to: URL(fileURLWithPath: directory).appendingPathComponent("\(pane.rawValue).png"))
		}
		renderWindow(to: directory)
	}

	/// The real window, built the way SettingsWindowController builds it, on each pane.
	@MainActor private static func renderWindow(to directory: String) {
		let model = SettingsModel(config: Config())
		model.checkEngine()
		let deadline = Date().addingTimeInterval(15)
		while model.engine == nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
		UpdateChecker.shared.showPreview(
			release: Release(
				version: "0.1.7", build: 8, url: URL(string: "https://downloads.example.com/Bol-0.1.7.dmg")!,
				minimumSystemVersion: nil, notes: nil))
		for pane in Pane.allCases {
			UserDefaults.standard.set(pane.rawValue, forKey: "settingsPane")
			let controller = NSHostingController(rootView: SettingsView(model: model).environment(\.colorScheme, .dark))
			let window = NSWindow(contentViewController: controller)
			window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
			window.titlebarAppearsTransparent = true
			window.appearance = NSAppearance(named: .darkAqua)
			RunLoop.current.run(until: Date().addingTimeInterval(0.5))
			let view = controller.view
			print("window on \(pane.rawValue): \(Int(window.frame.width)) × \(Int(window.frame.height))")
			guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
			view.cacheDisplay(in: view.bounds, to: rep)
			try? rep.representation(using: .png, properties: [:])?.write(
				to: URL(fileURLWithPath: directory).appendingPathComponent("window-\(pane.rawValue).png"))
		}
	}
}
