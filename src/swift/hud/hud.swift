import AppKit
import SwiftUI

// MARK: - Model

/// What the voice bar is showing.
enum HUDPhase: String, Equatable {
	case listening  // ⌘J pressed; waiting for / hearing speech
	case followUp  // listening right after a reply, no ⌘J needed
	case dictating  // the dictation key is held (or locked); the text is pasted when it ends
	case transcribing  // batch speech-to-text upload
	case thinking  // the agent is working
	case looking  // the agent is taking a screenshot
	case speaking  // reading the reply aloud
	case replied  // reply on screen, done speaking (or silent mode)
	case notice  // short info toast ("Stopped", "Silent mode on"…)
	case error
	case dropZone  // files are being dragged while the bar was hidden: it shows itself as a drop target

	/// Replies, notices and errors hide on their own timer.
	var isSelfDismissing: Bool {
		switch self {
		case .replied, .notice, .error: return true
		case .listening, .followUp, .dictating, .transcribing, .thinking, .looking, .speaking, .dropZone:
			return false
		}
	}
}

final class HUDModel: ObservableObject {
	@Published var phase: HUDPhase = .listening
	/// Short status label ("Listening", "Thinking"…).
	@Published var status = ""
	/// Main text: transcript, prompt, reply, action or detail.
	@Published var text = ""
	/// Secondary context: what you asked (above a reply) or the previous reply (follow-up).
	@Published var context = ""
	/// Current agent step, with an SF Symbol.
	@Published var activity = ""
	@Published var activityIcon = "sparkle"
	@Published var steps = 0
	@Published var startedAt = Date()
	/// Countdown (follow-up window, toast auto-dismiss).
	@Published var deadline: Date?
	@Published var deadlineTotal: TimeInterval = 1
	@Published var noticeIcon = "checkmark"
	@Published var isVisible = false {
		didSet { if isVisible != oldValue { onVisibilityChange?(isVisible) } }
	}
	/// Fired when the bar appears or goes away (the controller captures Esc while it's up).
	var onVisibilityChange: ((Bool) -> Void)?
	@Published var isHovering = false
	@Published var isSilent = false
	/// Dictation keeps listening after the key is let go (double-tapped).
	@Published var isDictationLocked = false
	/// The dictation key, for hints ("fn").
	@Published var dictationKey = DictationKey.fn.glyph
	/// Files dropped on the bar, sent with the next request.
	@Published var attachments: [URL] = []
	/// Files are being dragged somewhere on screen (the bar can take them).
	@Published var isDragActive = false
	/// The drag is over the bar.
	@Published var isDropTargeted = false

	/// Pulled every animation frame (not published, to avoid SwiftUI churn).
	var inputLevel: () -> Float = { 0 }
	var outputLevel: () -> Float = { 0 }
	var onClose: () -> Void = {}
	/// Files dropped on the bar.
	var onDrop: ([URL]) -> Void = { _ in }
}

// MARK: - Brand

private enum Brand {
	static let violet = Color(red: 0.55, green: 0.36, blue: 0.96)
	static let pink = Color(red: 0.93, green: 0.29, blue: 0.60)
	static let orange = Color(red: 0.98, green: 0.57, blue: 0.24)
	static let gradient = Gradient(colors: [violet, pink, orange])
	static let ring = Gradient(colors: [violet, pink, orange, pink, violet])
}

private var isReducingMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

// MARK: - Root view

struct HUDView: View {
	@ObservedObject var model: HUDModel
	/// Space between the bar and the bottom of the canvas. The live panel passes `HUD.shadowRoom` so the
	/// bar's soft shadow fades out inside the panel; the PNG preview renders keep the original 16.
	var bottomInset: CGFloat = 16

	var body: some View {
		// The panel is a transparent canvas; the bar is anchored to its bottom edge.
		VStack(spacing: 0) {
			Spacer(minLength: 0)
			Bar(model: model)
				.scaleEffect(model.isVisible ? 1 : 0.94, anchor: .bottom)
				.opacity(model.isVisible ? 1 : 0)
				.offset(y: model.isVisible ? 0 : 14)
				.animation(
					isReducingMotion ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.8),
					value: model.isVisible)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
		.padding(.bottom, bottomInset)
		.environment(\.colorScheme, .dark)
	}
}

struct BarFrameKey: PreferenceKey {
	static var defaultValue: CGRect = .zero
	static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct Bar: View {
	@ObservedObject var model: HUDModel
	static let maxWidth: CGFloat = 640

	var body: some View {
		// Hug the content, wrapping text only once the bar reaches its max width.
		CapWidth(max: Self.maxWidth) {
			HStack(alignment: .top, spacing: 13) {
				Visual(model: model)
					.frame(width: 38, height: 38)
				BarContent(model: model)
					.padding(.top, 1)
			}
			.padding(.leading, 12)
			.padding(.trailing, 18)
			.padding(.vertical, 12)
		}
		.background(BarBackground(model: model))
		.overlay(alignment: .topTrailing) {
			// Same top offset as the status row (12 padding + 1 + 6 spacing) so hints sit on its line.
			TrailingAccessory(model: model)
				.frame(height: 16)
				.padding(.top, 19)
				.padding(.trailing, 16)
		}
		.overlay(alignment: .bottom) { DismissProgress(model: model) }
		.overlay { DropOverlay(model: model) }
		.onDrop(of: [.fileURL], isTargeted: $model.isDropTargeted) { providers in
			FileDrop.load(providers: providers) { urls in
				if !urls.isEmpty { model.onDrop(urls) }
			}
			return true
		}
		.background(GeometryReader { g in Color.clear.preference(key: BarFrameKey.self, value: g.frame(in: .global)) })
		.animation(isReducingMotion ? nil : .spring(response: 0.36, dampingFraction: 0.86), value: model.phase)
		.animation(.easeOut(duration: 0.16), value: model.text)
		.animation(.easeOut(duration: 0.2), value: model.activity)
		.animation(.easeOut(duration: 0.2), value: model.context)
	}
}

/// Proposes at most `max` width to its content and adopts the content's own size
/// (unlike `.frame(maxWidth:)`, which expands to fill up to the max).
private struct CapWidth: Layout {
	let max: CGFloat
	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let w = proposal.width.map { Swift.min($0, max) } ?? max
		return subviews.first?.sizeThatFits(ProposedViewSize(width: w, height: proposal.height)) ?? .zero
	}
	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		subviews.first?.place(
			at: bounds.origin, anchor: .topLeading,
			proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
	}
}

// MARK: - Background + animated border

private struct BarBackground: View {
	@ObservedObject var model: HUDModel
	private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

	var body: some View {
		ZStack {
			shape.fill(.ultraThinMaterial)
			shape.fill(Color.black.opacity(0.42))
			// Soft brand light leaking in from the visualizer side.
			shape.fill(
				RadialGradient(
					colors: [glowColor.opacity(0.22), .clear],
					center: .init(x: 0.06, y: 0.5), startRadius: 0, endRadius: 220))
			GlowBorder(model: model, shape: shape)
		}
		.compositingGroup()
		.shadow(color: .black.opacity(0.45), radius: 22, y: 10)
		.shadow(color: .black.opacity(0.25), radius: 3, y: 1)
	}

	private var glowColor: Color {
		switch model.phase {
		case .error: return .red
		case .notice: return .white.opacity(0.4)
		case .listening, .followUp, .dictating, .transcribing, .thinking, .looking, .speaking, .replied, .dropZone:
			return Brand.pink
		}
	}
}

/// Thin gradient border that slowly rotates and brightens with the voice.
private struct GlowBorder: View {
	@ObservedObject var model: HUDModel
	let shape: RoundedRectangle

	var body: some View {
		switch model.phase {
		case .error:
			shape.strokeBorder(Color.red.opacity(0.5), lineWidth: 1.2)
		case .notice, .replied:
			shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
		case .listening, .followUp, .dictating, .transcribing, .thinking, .looking, .speaking, .dropZone:
			TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !model.isVisible || isReducingMotion)) { ctx in
				let t = ctx.date.timeIntervalSinceReferenceDate
				let (speed, base, gain) = params
				let level = Double(levelNow)
				let angle = Angle.degrees(isReducingMotion ? 0 : (t * speed).truncatingRemainder(dividingBy: 360))
				let gradient = AngularGradient(gradient: Brand.ring, center: .center, angle: angle)
				ZStack {
					shape.strokeBorder(gradient, lineWidth: 1.3)
						.opacity(base + gain * level)
					shape.strokeBorder(gradient, lineWidth: 5)
						.blur(radius: 7)
						.opacity((base + gain * level) * 0.45)
				}
			}
		}
	}

	/// (rotation speed in °/s, base opacity, extra opacity at full volume)
	private var params: (Double, Double, Double) {
		switch model.phase {
		case .listening, .followUp, .dictating: return (70, 0.35, 0.6)
		case .speaking: return (90, 0.30, 0.6)
		case .thinking, .transcribing: return (40, 0.30, 0)
		case .looking: return (120, 0.55, 0)
		case .replied, .notice, .error: return (40, 0.25, 0)
		case .dropZone: return (60, 0.45, 0)
		}
	}

	private var levelNow: Float {
		switch model.phase {
		case .listening, .followUp, .dictating: return model.inputLevel()
		case .speaking: return model.outputLevel()
		case .transcribing, .thinking, .looking, .replied, .notice, .error, .dropZone: return 0
		}
	}
}

// MARK: - Left visual

private struct Visual: View {
	@ObservedObject var model: HUDModel

	var body: some View {
		ZStack {
			Circle().fill(Color.white.opacity(0.06))
			Circle().strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
			content
				.transition(.scale(scale: 0.6).combined(with: .opacity))
				.id(kind)
		}
	}

	private var kind: String {
		switch model.phase {
		case .listening, .followUp, .dictating: return "in"
		case .speaking: return "out"
		case .thinking, .transcribing: return "think"
		case .replied: return "rest"
		case .looking: return "eye"
		case .notice: return "notice-\(model.noticeIcon)"
		case .error: return "error"
		case .dropZone: return "drop"
		}
	}

	@ViewBuilder private var content: some View {
		switch model.phase {
		case .listening, .followUp, .dictating:
			VoiceBars(mode: .input, level: model.inputLevel, isPaused: !model.isVisible)
		case .speaking:
			VoiceBars(mode: .output, level: model.outputLevel, isPaused: !model.isVisible)
		case .thinking, .transcribing:
			VoiceBars(mode: .thinking, level: { 0 }, isPaused: !model.isVisible)
		case .replied:
			VoiceBars(mode: .rest, level: { 0 }, isPaused: true)
		case .looking:
			symbol(name: "eye", color: Brand.pink, isPulsing: true)
		case .notice:
			symbol(name: model.noticeIcon, color: .white.opacity(0.85), isPulsing: false)
		case .error:
			symbol(name: "exclamationmark.triangle.fill", color: .red, isPulsing: false)
		case .dropZone:
			symbol(name: "tray.and.arrow.down.fill", color: Brand.pink, isPulsing: true)
		}
	}

	@ViewBuilder private func symbol(name: String, color: Color, isPulsing: Bool) -> some View {
		let img = Image(systemName: name).font(.system(size: 15, weight: .semibold)).foregroundStyle(color)
		if isPulsing, !isReducingMotion, #available(macOS 14.0, *) {
			img.symbolEffect(.pulse, options: .repeating)
		} else {
			img
		}
	}
}

/// Five rounded bars in the brand gradient, animated per frame with VU-style smoothing.
private struct VoiceBars: View {
	enum Mode { case input, output, thinking, rest }
	let mode: Mode
	let level: () -> Float
	let isPaused: Bool
	@State private var anim = BarAnimator()

	var body: some View {
		TimelineView(.animation(minimumInterval: 1.0 / 60, paused: isPaused || (isReducingMotion && mode == .thinking)))
		{ ctx in
			Canvas { gc, size in
				let heights = anim.step(t: ctx.date.timeIntervalSinceReferenceDate, mode: mode, level: CGFloat(level()))
				let w: CGFloat = 3.2
				let gap: CGFloat = 2.6
				let total = CGFloat(heights.count) * w + CGFloat(heights.count - 1) * gap
				var x = (size.width - total) / 2
				let shading = GraphicsContext.Shading.linearGradient(
					Brand.gradient, startPoint: CGPoint(x: x, y: size.height), endPoint: CGPoint(x: x + total, y: 0))
				for h in heights {
					let bh = max(w, h * size.height * 0.62)
					let r = CGRect(x: x, y: (size.height - bh) / 2, width: w, height: bh)
					gc.fill(Path(roundedRect: r, cornerRadius: w / 2), with: shading)
					x += w + gap
				}
			}
		}
	}
}

private final class BarAnimator {
	private static let shape: [CGFloat] = [0.55, 0.82, 1.0, 0.82, 0.55]
	private var h: [CGFloat] = [0.3, 0.42, 0.5, 0.42, 0.3]

	func step(t: Double, mode: VoiceBars.Mode, level: CGFloat) -> [CGFloat] {
		for i in 0..<h.count {
			let target: CGFloat
			let rise: CGFloat
			let fall: CGFloat
			switch mode {
			case .input, .output:
				let gain: CGFloat = mode == .input ? 1.6 : 2.0
				let l = min(1, level * gain)
				let wobble = CGFloat((sin(t * (6.1 + Double(i) * 1.9) + Double(i) * 2.3) + 1) / 2)
				let breath = CGFloat((sin(t * 2.4 + Double(i) * 0.7) + 1) / 2)
				target = 0.2 + Self.shape[i] * l * (0.5 + 0.5 * wobble) + (1 - l) * 0.1 * breath
				rise = 0.5
				fall = 0.16
			case .thinking:
				let wave = CGFloat((sin(t * 4.0 - Double(i) * 0.85) + 1) / 2)
				target = 0.24 + 0.46 * wave
				rise = 0.25
				fall = 0.25
			case .rest:
				target = 0.2 + Self.shape[i] * 0.22
				rise = 0.2
				fall = 0.2
			}
			h[i] += (target - h[i]) * (target > h[i] ? rise : fall)
		}
		return h
	}
}

// MARK: - Content

private struct BarContent: View {
	@ObservedObject var model: HUDModel

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			// Keeps a sensible minimum width without forcing the bar to full width.
			Color.clear.frame(width: 250, height: 0)
			StatusRow(model: model)
			main
			if !model.attachments.isEmpty, isShowingAttachments {
				AttachmentChips(urls: model.attachments)
					.transition(.opacity.combined(with: .move(edge: .bottom)))
			}
		}
	}

	private var isShowingAttachments: Bool {
		[.listening, .followUp, .transcribing, .thinking, .looking].contains(model.phase)
	}

	@ViewBuilder private var main: some View {
		switch model.phase {
		case .listening:
			if model.text.isEmpty {
				Text(
					model.attachments.isEmpty ? "Go ahead, I'm listening" : "Say what to do with it, or press ↩ to send"
				)
				.font(.system(size: 15)).foregroundStyle(.white.opacity(0.38))
			} else {
				transcript
			}
		case .dictating:
			if model.text.isEmpty {
				Text(
					model.isDictationLocked
						? "Hands-free: take your time" : "Speak, then let go"
				)
				.font(.system(size: 15)).foregroundStyle(.white.opacity(0.38))
			} else {
				transcript
			}
		case .followUp:
			if model.text.isEmpty {
				if !model.context.isEmpty {
					Text(model.context)
						.font(.system(size: 14)).foregroundStyle(.white.opacity(0.55))
						.lineLimit(3).fixedSize(horizontal: false, vertical: true)
				}
				Text("Keep talking to follow up").font(.system(size: 12)).foregroundStyle(.white.opacity(0.35))
			} else {
				transcript
			}
		case .transcribing, .thinking, .looking:
			if !model.text.isEmpty {
				Text("“\(model.text)”")
					.font(.system(size: 15)).foregroundStyle(.white.opacity(0.88))
					.lineLimit(3).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
			}
			if !model.activity.isEmpty {
				ActivityRow(model: model)
					.transition(.opacity.combined(with: .move(edge: .bottom)))
			}
		case .speaking, .replied:
			if !model.context.isEmpty {
				Text("“\(model.context)”")
					.font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
					.lineLimit(1).truncationMode(.tail)
			}
			ReplyBody(text: model.text, maxHeight: ReplyBody.maxHeight)
		case .notice:
			if !model.text.isEmpty {
				Text(model.text)
					.font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.7))
					.lineLimit(3).fixedSize(horizontal: false, vertical: true)
			}
		case .error:
			if !model.text.isEmpty {
				ReplyBody(text: model.text, maxHeight: 160, fontSize: 13.5, opacity: 0.75)
			}
		case .dropZone:
			Text(model.isDropTargeted ? "Let go to hand it to Bol" : "Drop files here to give them to Bol")
				.font(.system(size: 15)).foregroundStyle(.white.opacity(model.isDropTargeted ? 0.95 : 0.6))
		}
	}

	/// Live transcript: newest words stay isVisible (older text scrolls off the top).
	private var transcript: some View {
		Text(model.text)
			.font(.system(size: 15.5)).foregroundStyle(.white)
			.lineLimit(3).truncationMode(.head)
			.fixedSize(horizontal: false, vertical: true)
	}
}

private struct StatusRow: View {
	@ObservedObject var model: HUDModel

	var body: some View {
		HStack(spacing: 7) {
			label
			if model.isSilent, [.thinking, .replied, .looking].contains(model.phase) {
				Tag(text: "Silent", icon: "speaker.slash.fill")
			}
			if model.phase == .dictating, !model.context.isEmpty {
				Tag(text: model.context, icon: "text.cursor")
			}
			if isShowingElapsed {
				Elapsed(since: model.startedAt)
			}
			if let deadline = model.deadline, isShowingRing {
				CountdownRing(deadline: deadline, total: model.deadlineTotal, color: ringColor)
			}
			// Reserve room for the trailing hints so they never overlap the label.
			TrailingAccessory(model: model).hidden().padding(.leading, 14)
		}
		.frame(height: 16)
	}

	@ViewBuilder private var label: some View {
		switch model.phase {
		case .thinking, .transcribing, .looking:
			ShimmerText(text: model.status, color: .white.opacity(0.62))
		case .error:
			Text(model.status).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.red.opacity(0.95))
		case .notice:
			Text(model.status).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
		case .listening, .followUp, .dictating, .speaking, .replied, .dropZone:
			Text(model.status).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.62))
		}
	}

	private var isShowingElapsed: Bool { [.thinking, .looking, .transcribing].contains(model.phase) }
	private var isShowingRing: Bool { model.phase == .followUp && model.text.isEmpty }
	private var ringColor: Color { .white.opacity(0.75) }
}

private struct ActivityRow: View {
	@ObservedObject var model: HUDModel
	var body: some View {
		HStack(spacing: 7) {
			Image(systemName: model.activityIcon)
				.font(.system(size: 11, weight: .medium))
				.foregroundStyle(.white.opacity(0.55))
				.frame(width: 14)
			Text(model.activity)
				.font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6))
				.lineLimit(1).truncationMode(.tail)
			if model.steps > 1 {
				Text("· \(model.steps) steps").font(.system(size: 12)).foregroundStyle(.white.opacity(0.35))
			}
		}
		.id(model.activity)
	}
}

/// A reply: paragraphs and list items on their own lines, inline Markdown rendered, and the whole thing
/// scrolls once it's taller than `maxHeight` (nothing is cut off).
private struct ReplyBody: View {
	static let maxHeight: CGFloat = 340
	let text: String
	let maxHeight: CGFloat
	var fontSize: CGFloat = 15.5
	var opacity: Double = 0.95
	@State private var contentHeight: CGFloat = 0

	var body: some View {
		let paragraphs = ReplyFormat.paragraphs(display: ReplyFormat.display(text: text))
		let isScrolling = contentHeight > maxHeight + 0.5
		// The hidden copy sizes the bar (hugging short replies); the scroll view shows the text.
		CappedHeight(maxHeight: maxHeight) {
			content(paragraphs: paragraphs)
				.hidden()
				.background(
					GeometryReader { g in Color.clear.preference(key: ReplyHeightKey.self, value: g.size.height) })
			if isScrolling {
				ScrollView(.vertical, showsIndicators: true) {
					content(paragraphs: paragraphs).padding(.bottom, 14)
				}
				.mask(
					VStack(spacing: 0) {
						Color.black
						LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
					})
			} else {
				content(paragraphs: paragraphs)
			}
		}
		.clipped()
		.onPreferenceChange(ReplyHeightKey.self) { contentHeight = $0 }
	}

	private func content(paragraphs: [String]) -> some View {
		VStack(alignment: .leading, spacing: 9) {
			ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
				VStack(alignment: .leading, spacing: 4) {
					ForEach(Array(ReplyFormat.blocks(paragraph: paragraph).enumerated()), id: \.offset) { _, block in
						switch block {
						case .text(let text):
							line(text: text)
						case .item(let marker, let text, let level):
							// Hanging indent: wrapped lines of an item line up after its bullet.
							HStack(alignment: .firstTextBaseline, spacing: 6) {
								Text(marker)
									.font(.system(size: fontSize, weight: .semibold).monospacedDigit())
									.foregroundStyle(.white.opacity(opacity * 0.55))
									.frame(minWidth: 12, alignment: .leading)
								line(text: text)
							}
							.padding(.leading, CGFloat(level) * 16)
						}
					}
				}
			}
		}
		.textSelection(.enabled)
	}
}

extension ReplyBody {
	fileprivate func line(text: String) -> some View {
		Text(ReplyFormat.attributed(paragraph: text))
			.font(.system(size: fontSize)).foregroundStyle(.white.opacity(opacity))
			.lineSpacing(3)
			.fixedSize(horizontal: false, vertical: true)
	}
}

/// Sizes itself to its first subview (measured at the proposed width) up to `maxHeight`, and gives the
/// second (a scroll view) exactly that size.
private struct CappedHeight: Layout {
	let maxHeight: CGFloat
	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		guard let measure = subviews.first else { return .zero }
		let size = measure.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
		return CGSize(width: size.width, height: min(size.height, maxHeight))
	}
	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		subviews.first?.place(
			at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
		subviews.dropFirst().first?.place(
			at: bounds.origin, anchor: .topLeading,
			proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
	}
}

private struct ReplyHeightKey: PreferenceKey {
	static var defaultValue: CGFloat = 0
	static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Files dropped on the bar, waiting to go out with the next request.
private struct AttachmentChips: View {
	let urls: [URL]
	var body: some View {
		HStack(spacing: 6) {
			ForEach(Array(urls.prefix(3).enumerated()), id: \.offset) { _, url in
				HStack(spacing: 4) {
					Image(systemName: url.hasDirectoryPath ? "folder.fill" : "paperclip")
						.font(.system(size: 9.5, weight: .semibold))
					Text(url.lastPathComponent).font(.system(size: 11.5, weight: .medium))
						.lineLimit(1).truncationMode(.middle)
				}
				.foregroundStyle(.white.opacity(0.75))
				.padding(.horizontal, 7).padding(.vertical, 3)
				.background(Capsule().fill(Color.white.opacity(0.09)))
				.overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
				.frame(maxWidth: 220, alignment: .leading)
				.fixedSize(horizontal: false, vertical: true)
			}
			if urls.count > 3 {
				Text("+\(urls.count - 3) more").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
			}
		}
	}
}

/// While files are dragged, the bar outlines itself as a drop target and lights up when they're over it.
private struct DropOverlay: View {
	@ObservedObject var model: HUDModel
	private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

	var body: some View {
		if model.isDragActive || model.isDropTargeted {
			ZStack {
				if model.phase != .dropZone {
					// Over a reply or a request: say what a drop does.
					shape.fill(Color.black.opacity(model.isDropTargeted ? 0.62 : 0.45))
					Label(
						model.isDropTargeted ? "Let go to hand it to Bol" : "Drop here to give it to Bol",
						systemImage: "tray.and.arrow.down.fill"
					)
					.font(.system(size: 14, weight: .semibold))
					.foregroundStyle(.white.opacity(0.92))
				}
				shape.fill(Brand.pink.opacity(model.isDropTargeted ? 0.12 : 0))
				shape.strokeBorder(
					AngularGradient(gradient: Brand.ring, center: .center),
					style: StrokeStyle(
						lineWidth: model.isDropTargeted ? 2 : 1.3, dash: model.isDropTargeted ? [] : [6, 5]))
			}
			.allowsHitTesting(false)
			.transition(.opacity)
			.animation(.easeOut(duration: 0.15), value: model.isDropTargeted)
		}
	}
}

/// Reads file URLs out of a drop.
enum FileDrop {
	static func load(providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
		var urls: [URL] = []
		let group = DispatchGroup()
		let lock = NSLock()
		for provider in providers where provider.hasItemConformingToTypeIdentifier("public.file-url") {
			group.enter()
			_ = provider.loadObject(ofClass: URL.self) { url, _ in
				if let url, url.isFileURL {
					lock.lock()
					urls.append(url)
					lock.unlock()
				}
				group.leave()
			}
		}
		group.notify(queue: .main) { completion(urls) }
	}
}

/// Right side of the status row: keyboard hints, or copy / close while hovered.
private struct TrailingAccessory: View {
	@ObservedObject var model: HUDModel
	@ObservedObject private var shortcuts = ShortcutState.shared
	@State private var hasCopied = false

	var body: some View {
		ZStack(alignment: .trailing) {
			hints.opacity(model.isHovering && isHoverable ? 0 : 1)
			if isHoverable {
				controls.opacity(model.isHovering ? 1 : 0)
			}
		}
		.fixedSize()
		.animation(.easeOut(duration: 0.15), value: model.isHovering)
	}

	private var isHoverable: Bool { ![.listening, .dictating, .dropZone].contains(model.phase) }

	@ViewBuilder private var hints: some View {
		HStack(spacing: 5) {
			switch model.phase {
			case .listening:
				KeyHint(keys: [.returnKey], label: "send")
				KeyHint(keys: [.escape], label: "cancel")
			case .followUp:
				KeyHint(keys: [.returnKey], label: "send")
				KeyHint(keys: [.escape], label: "done")
			case .dictating:
				if model.isDictationLocked { KeyHint(keys: [model.dictationKey], label: "paste") }
				KeyHint(keys: [.escape], label: "cancel")
			case .thinking, .looking, .transcribing:
				KeyHint(keys: [.escape], label: "stop")
			case .speaking:
				KeyHint(keys: [.escape], label: "stop")
			case .replied:
				if let talk = shortcuts.settings.talk { KeyHint(keys: talk.glyphs, label: "reply") }
				KeyHint(keys: [.escape], label: "close")
			case .notice, .error, .dropZone:
				EmptyView()
			}
		}
	}

	private var controls: some View {
		HStack(spacing: 4) {
			if !model.text.isEmpty, [.speaking, .replied, .thinking, .followUp, .error].contains(model.phase) {
				CircleButton(symbol: hasCopied ? "checkmark" : "doc.on.doc", help: "Copy") {
					NSPasteboard.general.clearContents()
					let isReply = [.speaking, .replied, .error].contains(model.phase)
					NSPasteboard.general.setString(
						isReply ? ReplyFormat.plain(text: model.text) : model.text, forType: .string)
					hasCopied = true
					DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { hasCopied = false }
				}
			}
			CircleButton(symbol: "xmark", help: isBusy ? "Stop" : "Dismiss") { model.onClose() }
		}
	}

	private var isBusy: Bool {
		[.thinking, .looking, .transcribing, .speaking, .followUp].contains(model.phase)
	}
}

private struct CircleButton: View {
	let symbol: String
	let help: String
	let action: () -> Void
	@State private var isPointerOver = false
	var body: some View {
		Button(action: action) {
			Image(systemName: symbol)
				.font(.system(size: 9.5, weight: .bold))
				.foregroundStyle(.white.opacity(isPointerOver ? 0.95 : 0.7))
				.frame(width: 20, height: 20)
				.background(Circle().fill(Color.white.opacity(isPointerOver ? 0.2 : 0.1)))
				.contentShape(Circle())
		}
		.buttonStyle(.plain)
		.onHover { isPointerOver = $0 }
		.help(help)
	}
}

private struct KeyHint: View {
	let keys: [KeyGlyph]
	let label: String
	var body: some View {
		HStack(spacing: 5) {
			KeyCaps(glyphs: keys, style: .onDark, size: 9.5)
			Text(label).font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
		}
		.lineLimit(1)
		.fixedSize()
	}
}

private struct Tag: View {
	let text: String
	let icon: String
	var body: some View {
		HStack(spacing: 3) {
			Image(systemName: icon).font(.system(size: 8, weight: .bold))
			Text(text).font(.system(size: 10, weight: .semibold))
		}
		.foregroundStyle(.white.opacity(0.55))
		.padding(.horizontal, 5).padding(.vertical, 1.5)
		.background(Capsule().fill(Color.white.opacity(0.08)))
	}
}

private struct Elapsed: View {
	let since: Date
	var body: some View {
		TimelineView(.periodic(from: since, by: 1)) { ctx in
			let s = max(0, Int(ctx.date.timeIntervalSince(since)))
			if s >= 2 {
				Text(s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60))
					.font(.system(size: 11).monospacedDigit())
					.foregroundStyle(.white.opacity(0.32))
					.transition(.opacity)
			}
		}
	}
}

private struct CountdownRing: View {
	let deadline: Date
	let total: TimeInterval
	let color: Color
	var body: some View {
		TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
			let remaining = max(0, min(1, deadline.timeIntervalSince(ctx.date) / max(0.1, total)))
			ZStack {
				Circle().stroke(Color.white.opacity(0.12), lineWidth: 1.8)
				Circle().trim(from: 0, to: remaining)
					.stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
					.rotationEffect(.degrees(-90))
			}
			.frame(width: 11, height: 11)
		}
	}
}

/// A light band sweeping across the label while Bol works.
private struct ShimmerText: View {
	let text: String
	let color: Color
	var body: some View {
		let base = Text(text).font(.system(size: 12.5, weight: .semibold))
		base.foregroundStyle(color)
			.overlay {
				if !isReducingMotion {
					TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
						let p = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
						GeometryReader { g in
							LinearGradient(
								colors: [.clear, .white.opacity(0.95), .clear], startPoint: .leading,
								endPoint: .trailing
							)
							.frame(width: g.size.width * 0.5)
							.offset(x: -g.size.width * 0.5 + g.size.width * 1.5 * p)
						}
						.mask(base)
					}
				}
			}
	}
}

/// Thin line along the bottom that drains while a toast waits to auto-dismiss.
private struct DismissProgress: View {
	@ObservedObject var model: HUDModel
	var body: some View {
		if let deadline = model.deadline, [.notice, .error, .replied].contains(model.phase), !model.isHovering {
			TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
				let remaining = max(0, min(1, deadline.timeIntervalSince(ctx.date) / max(0.1, model.deadlineTotal)))
				GeometryReader { g in
					Capsule()
						.fill(Color.white.opacity(0.18))
						.frame(width: (g.size.width - 44) * remaining, height: 2)
						.frame(maxWidth: .infinity, alignment: .leading)
						.padding(.horizontal, 22)
				}
				.frame(height: 2)
			}
			.padding(.bottom, 1)
		}
	}
}

// MARK: - Panel controller

/// Floating, non-activating voice bar at the bottom of the screen you're on.
/// The panel is a large transparent canvas; only the bar itself takes mouse events.
final class HUD {
	let model = HUDModel()
	private let panel: NSPanel
	private var hideWork: DispatchWorkItem?
	private var orderOutWork: DispatchWorkItem?
	private var tracker: Timer?
	private var barRect: CGRect = .zero  // SwiftUI global coords (top-left origin)
	/// Watches for files being dragged anywhere, so the bar can offer itself as a drop target.
	private var dragMonitor: Any?
	/// The drag pasteboard's change count when the last drag ended; a new value means a new drag.
	private var dragChangeCount = NSPasteboard(name: .drag).changeCount
	private var isWatchingDrag = false
	/// Transparent room around the bar inside the panel. The bar's shadow (radius 22, y 10, plus the 14 pt
	/// drop of the show/hide animation) must fade out before the panel's edge, or the edge slices it into a
	/// grey band with a hard line (it was 16 pt below the bar).
	static let shadowRoom: CGFloat = 80
	/// Gap between the bar's bottom edge and the bottom of the usable screen area (Dock / screen edge).
	private static let barBottomGap: CGFloat = 22
	/// Room for the tallest bar (a reply at its scrolling height, with attachments) plus the shadow above it.
	private static let canvas = NSSize(width: Bar.maxWidth + 2 * shadowRoom, height: 520 + shadowRoom)

	init() {
		panel = NSPanel(
			contentRect: NSRect(origin: .zero, size: Self.canvas),
			styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
		panel.isFloatingPanel = true
		panel.level = .statusBar
		panel.backgroundColor = .clear
		panel.isOpaque = false
		panel.hasShadow = false  // the bar draws its own shadow
		panel.ignoresMouseEvents = true
		panel.hidesOnDeactivate = false
		panel.becomesKeyOnlyIfNeeded = true
		panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
		panel.sharingType = .readOnly  // isVisible in screenshots and screen recordings
		let host = NSHostingView(
			rootView: HUDView(model: model, bottomInset: Self.shadowRoom)
				.onPreferenceChange(BarFrameKey.self) { [weak self] r in self?.barRect = r })
		host.frame = NSRect(origin: .zero, size: Self.canvas)
		host.autoresizingMask = [.width, .height]
		panel.contentView = host
		startDragMonitor()
	}

	deinit {
		if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
	}

	// MARK: Phases

	func listening(status: String = "Listening") {
		set(phase: .listening, status: status, text: "", context: "")
		model.deadline = nil
	}

	func followUp(previousReply: String, seconds: TimeInterval) {
		set(phase: .followUp, status: "Listening for a follow-up", text: "", context: previousReply)
		countdown(seconds: seconds)
	}

	/// Live transcript while listening.
	func transcript(text: String) {
		if ![.listening, .followUp, .dictating].contains(model.phase) {
			set(phase: .listening, status: "Listening", text: "", context: "")
		}
		model.text = text
		if !text.isEmpty { model.deadline = nil }
	}

	/// Dictating into `app` (the app in front), live transcript to follow.
	func dictating(app: String?, isLocked: Bool) {
		model.isDictationLocked = isLocked
		set(phase: .dictating, status: "Dictating", text: "", context: app ?? "")
		model.deadline = nil
	}

	/// Double-tapped: dictation carries on without holding the key.
	func lockDictation() {
		guard model.phase == .dictating else { return }
		model.isDictationLocked = true
	}

	/// Speech-to-text is finishing; `text` is what was heard so far (streaming providers).
	func transcribing(text: String = "") {
		set(phase: .transcribing, status: "Transcribing", text: text, context: "")
		resetWork()
	}

	func thinking(prompt: String, isAddedToTask: Bool = false) {
		set(
			phase: .thinking, status: isAddedToTask ? "Added to the current task" : "Thinking", text: prompt,
			context: "")
		resetWork()
	}

	/// The agent started a step (tool call).
	func activity(tool: String, summary: String) {
		let (icon, label) = Self.describe(tool: tool, summary: summary)
		if model.phase == .looking {
			model.phase = .thinking
			model.status = "Working"
		}
		if model.phase == .thinking { model.status = "Working" }
		model.activityIcon = icon
		model.activity = label
		model.steps += 1
	}

	func looking(reason: String) {
		model.phase = .looking
		model.status = "Looking at your screen"
		model.activityIcon = "eye"
		model.activity = reason.isEmpty ? "Taking a screenshot" : reason
		model.steps += 1
		present()
	}

	func speaking(reply: String, prompt: String) {
		set(phase: .speaking, status: "Bol", text: reply, context: prompt)
		model.deadline = nil
	}

	/// Reply stays on screen (after speaking, or in silent mode).
	func replied(reply: String, prompt: String, hideAfter: TimeInterval) {
		set(phase: .replied, status: "Bol", text: reply, context: prompt)
		hide(after: hideAfter)
	}

	func notice(title: String, detail: String = "", icon: String = "checkmark", hideAfter: TimeInterval = 1.6) {
		model.noticeIcon = icon
		set(phase: .notice, status: title, text: detail, context: "")
		hide(after: hideAfter)
	}

	func error(title: String, detail: String = "", hideAfter: TimeInterval = 8) {
		set(phase: .error, status: title, text: detail, context: "")
		hide(after: hideAfter)
	}

	/// Dev-only (defaults BolDevHooks, `com.snktcodes.bol.previewHUD`): show the bar in `phase` with `text`
	/// for `seconds`, then hide it. For visual checks only: no brain call, no speech, no mic.
	func preview(
		phase: HUDPhase, text: String, context: String = "", step: String = "", status: String? = nil,
		seconds: TimeInterval
	) {
		switch phase {
		case .listening:
			listening()
			if !text.isEmpty { transcript(text: text) }
		case .followUp: followUp(previousReply: text, seconds: seconds)
		case .dictating:
			dictating(app: context.isEmpty ? nil : context, isLocked: false)
			if !text.isEmpty { transcript(text: text) }
		case .transcribing: transcribing()
		case .thinking:
			thinking(prompt: text)
			if !step.isEmpty { activity(tool: "", summary: step) }
		case .looking:
			thinking(prompt: text)
			looking(reason: step)
		case .speaking: speaking(reply: text, prompt: context)
		case .replied: replied(reply: text, prompt: context, hideAfter: seconds)
		case .notice: notice(title: status ?? "Notice", detail: text, hideAfter: seconds)
		case .error: error(title: status ?? "Something went wrong", detail: text, hideAfter: seconds)
		case .dropZone: set(phase: .dropZone, status: "Bol", text: "", context: "")
		}
		if let status { model.status = status }
		hide(after: seconds)
	}

	// MARK: Show / hide

	private func set(phase: HUDPhase, status: String, text: String, context: String) {
		model.phase = phase
		model.status = status
		model.text = text
		model.context = context
		present()
	}

	private func resetWork() {
		model.activity = ""
		model.steps = 0
		model.startedAt = Date()
		model.deadline = nil
	}

	private func countdown(seconds: TimeInterval) {
		model.deadlineTotal = seconds
		model.deadline = Date().addingTimeInterval(seconds)
	}

	private func present() {
		hideWork?.cancel()
		hideWork = nil
		orderOutWork?.cancel()
		orderOutWork = nil
		switch model.phase {
		case .followUp, .notice, .error, .replied: break  // these keep their countdown
		case .listening, .dictating, .transcribing, .thinking, .looking, .speaking, .dropZone: model.deadline = nil
		}
		if !panel.isVisible {
			position()
			panel.orderFrontRegardless()
			DispatchQueue.main.async { self.model.isVisible = true }
		} else {
			model.isVisible = true
		}
		startTracking()
	}

	/// Keeps the voice bar out of screenshots Bol takes to operate the Mac (it stays visible to you).
	func setHiddenFromCapture(isHidden: Bool) {
		panel.sharingType = isHidden ? .none : .readOnly
	}

	func hide(after delay: TimeInterval = 0) {
		hideWork?.cancel()
		if delay > 0 {
			model.deadlineTotal = delay
			model.deadline = Date().addingTimeInterval(delay)
		}
		let w = DispatchWorkItem { [weak self] in self?.dismiss() }
		hideWork = w
		DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
	}

	private func dismiss() {
		// Don't yank the bar away while the pointer is on it (e.g. reading or copying).
		if model.isHovering, model.phase.isSelfDismissing {
			hide(after: 1.5)
			return
		}
		model.isVisible = false
		let w = DispatchWorkItem { [weak self] in
			guard let self, !self.model.isVisible else { return }
			self.panel.orderOut(nil)
			self.stopTracking()
			self.model.isHovering = false
		}
		orderOutWork = w
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
	}

	/// Bottom-center of the screen with the pointer (where your attention is). The bar sits `barBottomGap`
	/// above the Dock; the panel reaches `shadowRoom` below that (over the Dock / past the screen edge), but
	/// that part is transparent and click-through.
	private func position() {
		let mouse = NSEvent.mouseLocation
		let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
		guard let f = screen?.visibleFrame else { return }
		panel.setFrame(
			NSRect(
				x: f.midX - Self.canvas.width / 2, y: f.minY + Self.barBottomGap - Self.shadowRoom,
				width: Self.canvas.width, height: Self.canvas.height), display: false)
	}

	// MARK: Dragging files onto the bar

	/// Files dragged anywhere on screen bring the bar up as a drop target (if it isn't showing already);
	/// it goes away again if they're dropped elsewhere. Mouse events need no extra permission to watch.
	private func startDragMonitor() {
		dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) {
			[weak self] event in
			DispatchQueue.main.async { self?.handleDrag(event: event) }
		}
	}

	private func handleDrag(event: NSEvent) {
		let board = NSPasteboard(name: .drag)
		switch event.type {
		case .leftMouseDragged:
			guard !isWatchingDrag, board.changeCount != dragChangeCount else { return }
			dragChangeCount = board.changeCount
			let hasFiles =
				board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
			guard hasFiles else { return }
			isWatchingDrag = true
			model.isDragActive = true
			if !model.isVisible || !panel.isVisible || (model.phase.isSelfDismissing && model.phase != .replied) {
				set(phase: .dropZone, status: "Bol", text: "", context: "")
			} else {
				present()  // keeps a reply from timing out mid-drag, and tracks the pointer
			}
		case .leftMouseUp:
			dragChangeCount = board.changeCount
			guard isWatchingDrag else { return }
			isWatchingDrag = false
			// Give a drop on the bar a moment to land before deciding it went elsewhere.
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.endDrag() }
		default:
			break
		}
	}

	/// The drag ended. A drop on the bar has already moved it on; otherwise it goes back to how it was.
	func endDrag() {
		model.isDragActive = false
		model.isDropTargeted = false
		if model.phase == .dropZone {
			dismiss()
		} else if model.phase.isSelfDismissing {
			hide(after: 4)
		}
	}

	// MARK: Pointer tracking (clicks outside the bar pass through to apps below)

	private func startTracking() {
		guard tracker == nil else { return }
		let tracker = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.trackPointer() }
		RunLoop.main.add(tracker, forMode: .common)
		self.tracker = tracker
	}

	private func stopTracking() {
		tracker?.invalidate()
		tracker = nil
		panel.ignoresMouseEvents = true
	}

	private func trackPointer() {
		guard panel.isVisible, barRect != .zero else { return }
		let p = NSEvent.mouseLocation
		let f = panel.frame
		// SwiftUI global rect (top-left origin) → screen coordinates (bottom-left origin).
		let r = NSRect(x: f.minX + barRect.minX, y: f.maxY - barRect.maxY, width: barRect.width, height: barRect.height)
		let inside = r.insetBy(dx: -2, dy: -2).contains(p)
		if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
		if model.isHovering != inside { model.isHovering = inside }
	}

	// MARK: Tool descriptions

	static func describe(tool: String, summary: String) -> (icon: String, label: String) {
		let s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
		func pretty(name: String) -> String {
			name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
		}
		if tool.hasPrefix("mcp__claude-in-chrome__") || tool.hasPrefix("mcp__claude_in_chrome__") {
			let action = String(tool.split(separator: "_").last ?? "")
			return ("globe", s.isEmpty ? "Chrome · \(pretty(name: action))" : s)
		}
		if tool == "mcp__bol__look_at_screen" { return ("eye", s.isEmpty ? "Looking at your screen" : s) }
		if tool.hasPrefix("mcp__bol__") {
			// Bol's own computer control (src/typescript/control.ts).
			switch String(tool.dropFirst("mcp__bol__".count)) {
			case "screenshot", "zoom": return ("eye", "Looking at your screen")
			case "type": return ("keyboard", "Typing")
			case "key", "hold_key": return ("keyboard", s.isEmpty ? "Pressing keys" : "Pressing \(s)")
			case "scroll": return ("arrow.up.and.down", "Scrolling")
			case "open_application": return ("macwindow", s.isEmpty ? "Opening an app" : "Opening \(s)")
			case "read_clipboard", "write_clipboard": return ("doc.on.clipboard", "Using the clipboard")
			case "wait": return ("hourglass", "Waiting")
			case "computer_batch": return ("cursorarrow.click.2", s.isEmpty ? "Operating your Mac" : s)
			default: return ("cursorarrow.click", "Clicking")
			}
		}
		if tool.hasPrefix("mcp__") {
			let parts = tool.split(separator: "_").filter { !$0.isEmpty }
			return ("puzzlepiece.extension", s.isEmpty ? pretty(name: String(parts.last ?? "tool")) : s)
		}
		switch tool {
		case "Bash": return ("terminal", s.isEmpty ? "Running a command" : s)
		case "Read": return ("doc.text", s.isEmpty ? "Reading a file" : "Reading \(s)")
		case "Write": return ("square.and.pencil", s.isEmpty ? "Writing a file" : "Writing \(s)")
		case "Edit", "MultiEdit": return ("pencil", s.isEmpty ? "Editing a file" : "Editing \(s)")
		case "Glob", "Grep": return ("doc.text.magnifyingglass", s.isEmpty ? "Searching files" : "Searching for \(s)")
		case "WebSearch": return ("magnifyingglass", s.isEmpty ? "Searching the web" : "Searching “\(s)”")
		case "WebFetch": return ("globe", s.isEmpty ? "Opening a page" : "Opening \(s)")
		case "Task", "Agent": return ("person.2", s.isEmpty ? "Delegating to a helper" : s)
		case "TodoWrite": return ("checklist", "Planning steps")
		default: return ("sparkle", s.isEmpty ? pretty(name: tool) : s)
		}
	}
}
