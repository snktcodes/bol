import Foundation

/// App-wide constants. Provider-specific ones (endpoints, models) live in each provider's file.
enum Constants {
	// MARK: Files (~/.bol)

	static let bolDirectory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".bol")
	static let configFile = bolDirectory.appendingPathComponent("config.json")
	static let logFile = bolDirectory.appendingPathComponent("bol.log")
	static let memoryDirectory = bolDirectory.appendingPathComponent("memory")
	static let memoryIndexFile = memoryDirectory.appendingPathComponent("MEMORY.md")
	/// Instructions appended to Claude Code's system prompt (written by Settings, read by the brain).
	static let promptFile = bolDirectory.appendingPathComponent("system_prompt.md")
	/// The brain writes its built-in prompt here so Settings can show and restore it.
	static let defaultPromptFile = bolDirectory.appendingPathComponent("default_system_prompt.md")
	/// The brain appends one line per conversation start or move here (see session.ts), for the Threads window.
	static let threadsFile = bolDirectory.appendingPathComponent("threads.jsonl")
	/// One line per task session: id, name and the thread that started it (written by the brain).
	static let tasksFile = bolDirectory.appendingPathComponent("tasks.jsonl")
	/// The brain's current foreground session id.
	static let sessionFile = bolDirectory.appendingPathComponent("session_id")
	/// Recent dictations (a week's worth), one JSON line each.
	static let dictationsFile = bolDirectory.appendingPathComponent("dictations.jsonl")
	/// Bol's own copy of every conversation (the brain mirrors each transcript here), kept whatever Claude Code
	/// cleans up.
	static let threadsDirectory = bolDirectory.appendingPathComponent("threads")
	/// Where Bol's Claude Code runs unless Settings picks a folder, so its sessions are a project of their own.
	static let workspaceDirectory = bolDirectory.appendingPathComponent("workspace")
	/// Where Claude Code keeps session transcripts, one folder per working directory.
	static let claudeProjectsDirectory = URL(fileURLWithPath: NSHomeDirectory())
		.appendingPathComponent(".claude/projects")

	// MARK: Threads

	/// Context window of the models Bol offers; Claude Code compacts a conversation as it nears this.
	static func contextWindow(model: String) -> Int {
		model.contains("haiku-4") ? 200_000 : 1_000_000
	}

	// MARK: Defaults keys and Info.plist keys

	/// Dev-only hooks (demo recordings, HUD previews): `defaults write <bundle id> BolDevHooks -bool true`.
	static let devHooksDefaultsKey = "BolDevHooks"
	static let sayNotification = Notification.Name("com.snktcodes.bol.say")
	static let previewHUDNotification = Notification.Name("com.snktcodes.bol.previewHUD")
	/// Dev-only: run a menu action by name (stop, newConversation, sendToBackground, stopBackground, state, permissions…).
	static let actionNotification = Notification.Name("com.snktcodes.bol.action")

	// MARK: Audio

	/// Microphone audio is 16 kHz mono signed 16-bit PCM everywhere after capture.
	static let micSampleRate: Double = 16000
	static let micBytesPerSecond = 32000

	/// Spelling hints for speech-to-text, so "Bol" isn't heard as "bowl" and "Claude" as "cloud".
	static let speechKeyterms = ["Bol", "Claude", "Claude Code"]

	// MARK: Voice loop timing (seconds)

	/// Mic audio kept from before speech-to-text connects, so the first words aren't lost.
	static let micRingBufferSeconds = 3.0
	/// No speech at all after ⌘J for this long cancels listening (once you speak, only Enter sends).
	static let manualNoSpeechTimeout = 20.0
	/// Longest single utterance before it is sent anyway, if Enter never comes.
	static let maxUtteranceSeconds = 600.0
	/// A dictation shows its bar and lowers other apps only once the key is held this long.
	static let dictationRevealSeconds = 0.2
	/// Batch transcribers have no live text, so this mic level counts as speech.
	static let batchSpeechLevel = 0.12
	/// The speaker's audio engine pauses once it has been silent this long, so an idle Bol holds no output
	/// device open (a reply right after another reuses the running engine).
	static let speakerIdleSeconds = 3.0

	// MARK: Brain

	static let maxBrainRestarts = 5

	// MARK: Heads-up

	/// The version of setup's last step ("Before you start": Bol acts without asking) the user acknowledged.
	/// Bump it (to the date of the change) when that page changes enough to need acknowledging again.
	static let termsVersion = "2026-11-25"

	// MARK: Updates

	/// The update feed (a latest.json like website/public/latest.json). nil: this build never checks for
	/// updates; update by pulling and rebuilding. Set it to your own feed to turn updates on, or try one with
	/// `defaults write com.snktcodes.bol BolUpdateFeedURL <url>`.
	static let updateFeedURL: URL? = nil
	static let updateCheckSeconds: TimeInterval = 6 * 60 * 60
}
