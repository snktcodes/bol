import AVFoundation
import SwiftUI

/// The macOS voices: offline, always available, and the fallback when a cloud voice fails.
struct SystemTextToSpeech: TextToSpeechProvider {
	struct Settings: Codable, Equatable {
		/// nil = the best installed female English voice.
		var voiceId: String? = nil
	}

	let id = TextToSpeechProviderID.system
	let title = "macOS"
	let subtitle = "Built-in, works offline"
	let icon = "desktopcomputer"
	let credential = ProviderCredential.none

	func synthesize(text: String, config: Config) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
		let utterance = AVSpeechUtterance(string: text)
		utterance.voice =
			config.textToSpeech.system.voiceId.flatMap { AVSpeechSynthesisVoice(identifier: $0) } ?? Self.bestVoice()
		utterance.rate = 0.52
		return AsyncThrowingStream { continuation in
			// Captured by onTermination, which may run on another thread (unchanged behavior; marked to say so).
			nonisolated(unsafe) let synthesizer = AVSpeechSynthesizer()
			synthesizer.write(utterance) { buffer in
				// An empty buffer marks the end.
				guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
					continuation.finish()
					return
				}
				continuation.yield(pcm)
			}
			continuation.onTermination = { _ in synthesizer.stopSpeaking(at: .immediate) }
		}
	}

	static func englishVoices() -> [AVSpeechSynthesisVoice] {
		AVSpeechSynthesisVoice.speechVoices()
			.filter { $0.language.hasPrefix("en") }
			.sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
	}

	/// Prefers premium/enhanced female English voices, else Samantha.
	static func bestVoice() -> AVSpeechSynthesisVoice? {
		let femaleNames = [
			"Zoe", "Ava", "Allison", "Susan", "Serena", "Kate", "Samantha", "Karen", "Moira", "Tessa", "Fiona",
			"Victoria",
		]
		func rank(voice: AVSpeechSynthesisVoice) -> Int {
			var rank = voice.quality.rawValue * 100
			if let i = femaleNames.firstIndex(where: { voice.name.hasPrefix($0) }) { rank += 50 - i }
			if voice.gender == .female { rank += 20 }
			return rank
		}
		return englishVoices().max { rank(voice: $0) < rank(voice: $1) }
	}

	@MainActor func settingsSection(model: SettingsModel) -> AnyView {
		AnyView(
			SettingsGroup(
				title: "macOS",
				footer: "Download better voices in System Settings → Accessibility → Spoken Content → Manage Voices."
			) {
				SettingsRow("Voice", icon: "person.wave.2") {
					Select(
						options: [SelectOption(id: "", title: "Automatic", subtitle: "Best installed female voice")]
							+ Self.englishVoices().map { voice in
								SelectOption(
									id: voice.identifier, title: voice.name,
									subtitle: voice.language + Self.qualityLabel(voice: voice))
							},
						selection: Binding(root: model, keyPath: \.config.textToSpeech.system.voiceId).emptyAsNil,
						isSearchable: true, prompt: "Search voices")
				}
			}
		)
	}

	private static func qualityLabel(voice: AVSpeechSynthesisVoice) -> String {
		switch voice.quality {
		case .premium: return " · Premium"
		case .enhanced: return " · Enhanced"
		case .default: return ""
		@unknown default: return ""
		}
	}
}
