import AppKit
import CoreAudio
import Foundation

/// What happens to other apps' sound while Bol listens or speaks: lower, mute, pause media, or nothing.
///
/// Lowering the Mac's output volume would lower Bol's voice too, so lower and mute tap
/// the audio of every process except Bol's (macOS 14.2+), mute it at the source, and play it back
/// at the chosen level. The tap belongs to this process: if Bol quits or crashes, macOS removes it
/// and the sound is back at full volume, with nothing to restore. Volume keys keep working, since
/// the Mac's own volume still applies on top. Pause media pauses Music, Spotify and VLC and plays
/// them again afterwards.
///
/// Main thread only, apart from the audio callback.
final class AudioDucker {
	/// How long other audio stays down after Bol stops listening or speaking: a short think between
	/// your question and its answer keeps it down rather than pumping it up and back.
	private static let holdSeconds = 3.0

	var behavior = OtherAudioBehavior.lower {
		didSet { if behavior != oldValue, isWanted { switchBehavior() } }
	}
	/// What `lower` goes down to: 0 silences, 1 leaves it alone.
	var level: Float = 0.2 {
		didSet { if isWanted, tap != nil { ramp.target = tapLevel } }
	}

	private let ramp = Ramp()
	private var tap: Tap?
	/// Players paused for Bol, to play again afterwards.
	private var pausedPlayers: [MediaPlayer] = []
	private var isPausing = false
	private var isWanted = false
	private var release: DispatchWorkItem?
	private var outputListener: AudioObjectPropertyListenerBlock?

	init() {
		// The tap plays through the output that was current when it was made; follow a switch to
		// headphones or a display.
		let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.outputChanged() }
		var address = Self.defaultOutputAddress
		if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == 0
		{
			outputListener = listener
		}
	}

	private var tapLevel: Float { behavior == .mute ? 0 : level }

	/// Whether other audio should be held back now. Letting it go waits `holdSeconds`.
	func setDucked(isDucked: Bool) {
		guard isDucked != isWanted else { return }
		isWanted = isDucked
		release?.cancel()
		release = nil
		if isDucked {
			apply()
			return
		}
		let release = DispatchWorkItem { [weak self] in self?.restore() }
		self.release = release
		DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdSeconds, execute: release)
	}

	private func apply() {
		switch behavior {
		case .lower, .mute:
			ramp.target = tapLevel
			if tap == nil { tap = Tap.make(ramp: ramp) }
		case .pauseMedia:
			pauseMedia()
		case .nothing:
			break
		}
	}

	private func restore() {
		if tap != nil { fadeUp() }
		resumeMedia()
	}

	/// The setting changed mid-conversation: undo what the old choice did, then apply the new one.
	private func switchBehavior() {
		if tap != nil, behavior != .lower, behavior != .mute { fadeUp() }
		if behavior != .pauseMedia { resumeMedia() }
		apply()
	}

	private func fadeUp() {
		ramp.target = 1
		let remove = DispatchWorkItem { [weak self] in self?.removeWhenRestored() }
		if !isWanted { release = remove }
		DispatchQueue.main.asyncAfter(deadline: .now() + Double(Ramp.fadeUpSeconds) + 0.1, execute: remove)
	}

	/// Once other audio is back at full level, hands it back to macOS: the switch is then silent.
	private func removeWhenRestored() {
		guard tap != nil, ramp.target >= 1 else { return }
		guard ramp.gain >= 0.999 else {
			fadeUp()  // still on its way up (a slow output); look again shortly
			return
		}
		tap = nil
		Log.info(message: "ducking: other audio restored")
	}

	private func outputChanged() {
		guard tap != nil else { return }
		tap = nil
		tap = Tap.make(ramp: ramp)
	}

	private static var defaultOutputAddress = AudioObjectPropertyAddress(
		mSelector: kAudioHardwarePropertyDefaultOutputDevice,
		mScope: kAudioObjectPropertyScopeGlobal,
		mElement: kAudioObjectPropertyElementMain)

	// MARK: Pausing media

	private func pauseMedia() {
		guard !isPausing, pausedPlayers.isEmpty else { return }
		let running = MediaPlayer.running()
		guard !running.isEmpty else { return }
		isPausing = true
		DispatchQueue.global(qos: .userInitiated).async { [weak self] in
			let paused = MediaPlayer.pause(players: running)
			DispatchQueue.main.async {
				guard let self else { return }
				self.isPausing = false
				self.pausedPlayers = paused
				if !paused.isEmpty { Log.info(message: "ducking: paused \(paused.map(\.rawValue))") }
				// Bol finished (or the setting changed) while the players were being paused.
				if !self.isWanted || self.behavior != .pauseMedia { self.resumeMedia() }
			}
		}
	}

	private func resumeMedia() {
		guard !pausedPlayers.isEmpty else { return }
		let players = pausedPlayers
		pausedPlayers = []
		DispatchQueue.global(qos: .userInitiated).async { MediaPlayer.resume(players: players) }
		Log.info(message: "ducking: resumed \(players.map(\.rawValue))")
	}

	// MARK: Gain

	/// The level the audio callback applies, eased from where it was to `target`. `target` is set
	/// from the main thread; everything else belongs to the audio thread.
	final class Ramp: @unchecked Sendable {
		/// Quick down, so the first word isn't fighting the music; slow back up.
		static let fadeDownSeconds: Float = 0.12
		static let fadeUpSeconds: Float = 1.0

		var target: Float = 1
		private(set) var gain: Float = 1
		private var from: Float = 1
		private var to: Float = 1
		private var progress: Float = 1

		/// The gain for each of `frames` frames, written to `gains`.
		func advance(frames: Int, sampleRate: Float, gains: UnsafeMutablePointer<Float>) {
			let target = self.target
			if target != to {
				from = gain
				to = target
				progress = 0
			}
			let seconds = to < from ? Self.fadeDownSeconds : Self.fadeUpSeconds
			let step = 1 / (seconds * max(sampleRate, 1))
			for frame in 0..<frames {
				if progress < 1 {
					progress = min(progress + step, 1)
					let eased = progress * progress * (3 - 2 * progress)
					gain = from + (to - from) * eased
				} else {
					gain = to
				}
				gains[frame] = gain
			}
		}
	}

	// MARK: The tap

	/// A tap of every process but Bol, muted at the source, and a private device that plays it
	/// back through the current output. Deinit takes both down.
	private final class Tap {
		private var tapID = AudioObjectID(kAudioObjectUnknown)
		private var deviceID = AudioObjectID(kAudioObjectUnknown)
		private var procID: AudioDeviceIOProcID?

		static func make(ramp: Ramp) -> Tap? {
			guard #available(macOS 14.2, *) else { return nil }
			// Without the permission a tap reads silence while still muting everything else.
			guard SystemAudioAccess.status() == .granted else {
				Log.info(message: "ducking: skipped, System Audio Recording isn't granted")
				return nil
			}
			let tap = Tap()
			if let error = tap.start(ramp: ramp) {
				Log.info(message: "ducking: couldn't lower other audio: \(error)")
				return nil
			}
			Log.info(message: "ducking: other audio lowered")
			return tap
		}

		@available(macOS 14.2, *)
		private func start(ramp: Ramp) -> String? {
			guard let bol = Self.processObject(pid: getpid()) else { return "Bol isn't known to Core Audio yet" }
			guard let output = Self.defaultOutput(), let outputUID = Self.uid(device: output) else {
				return "no output device"
			}
			guard Self.isFloatOutput(device: output) else { return "the output doesn't take float samples" }

			let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [bol])
			description.uuid = UUID()
			description.isPrivate = true
			// Muted only while this tap is read: if playback stops, the sound goes back to normal.
			description.muteBehavior = .mutedWhenTapped
			guard AudioHardwareCreateProcessTap(description, &tapID) == 0 else { return "creating the tap failed" }

			let aggregate: [String: Any] = [
				kAudioAggregateDeviceNameKey: "Bol Ducking",
				kAudioAggregateDeviceUIDKey: "com.snktcodes.bol.ducking.\(UUID().uuidString)",
				kAudioAggregateDeviceMainSubDeviceKey: outputUID,
				kAudioAggregateDeviceIsPrivateKey: true,
				kAudioAggregateDeviceIsStackedKey: false,
				kAudioAggregateDeviceTapAutoStartKey: true,
				kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
				kAudioAggregateDeviceTapListKey: [
					[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]
				],
			]
			guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID) == 0 else {
				return "creating the playback device failed"
			}

			// The aggregate's inputs list the output device's own inputs (if any) before the tap's.
			let skippedInputs = Self.bufferCount(device: output, scope: kAudioObjectPropertyScopeInput)
			let sampleRate = Float(Self.sampleRate(device: deviceID))
			let gains = UnsafeMutablePointer<Float>.allocate(capacity: 16_384)
			let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, input, _, output, _ in
				Self.render(
					input: UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)),
					output: UnsafeMutableAudioBufferListPointer(output),
					skippedInputs: skippedInputs, ramp: ramp, sampleRate: sampleRate, gains: gains)
			}
			// The callback (and with it `gains`) lives as long as the device; it's freed with the tap.
			self.gains = gains
			guard status == 0, let procID else { return "creating the playback callback failed" }
			guard AudioDeviceStart(deviceID, procID) == 0 else { return "starting playback failed" }
			return nil
		}

		private var gains: UnsafeMutablePointer<Float>?

		deinit {
			if let procID {
				AudioDeviceStop(deviceID, procID)
				AudioDeviceDestroyIOProcID(deviceID, procID)
			}
			if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
			if #available(macOS 14.2, *), tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
			gains?.deallocate()
		}

		/// Copies the tapped audio (stereo) to the output at the ramp's gain. On the audio thread:
		/// no locks, no allocation.
		private static func render(
			input: UnsafeMutableAudioBufferListPointer, output: UnsafeMutableAudioBufferListPointer,
			skippedInputs: Int, ramp: Ramp, sampleRate: Float, gains: UnsafeMutablePointer<Float>
		) {
			for buffer in output {
				if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
			}
			// The tap's stereo comes as one interleaved buffer or as one buffer per channel.
			guard input.count > skippedInputs, input[skippedInputs].mData != nil else { return }
			func source(channel: Int) -> (samples: UnsafeMutablePointer<Float>, stride: Int, frames: Int)? {
				var first = 0
				for index in skippedInputs..<input.count {
					let buffer = input[index]
					let channels = max(Int(buffer.mNumberChannels), 1)
					if channel < first + channels, let data = buffer.mData {
						let samples = data.assumingMemoryBound(to: Float.self) + (channel - first)
						return (samples, channels, Int(buffer.mDataByteSize) / (4 * channels))
					}
					first += channels
				}
				return nil
			}
			guard let left = source(channel: 0) else { return }
			let right = source(channel: 1) ?? left

			var frames = min(left.frames, right.frames, 16_384)
			for buffer in output {
				let channels = max(Int(buffer.mNumberChannels), 1)
				frames = min(frames, Int(buffer.mDataByteSize) / (4 * channels))
			}
			ramp.advance(frames: frames, sampleRate: sampleRate, gains: gains)

			// Left and right go to the output's first two channels, whichever buffers hold them.
			var channel = 0
			for buffer in output {
				guard let data = buffer.mData else { continue }
				let channels = max(Int(buffer.mNumberChannels), 1)
				let target = data.assumingMemoryBound(to: Float.self)
				for offset in 0..<channels where channel + offset < 2 {
					let from = channel + offset == 0 ? left : right
					for frame in 0..<frames {
						target[frame * channels + offset] = from.samples[frame * from.stride] * gains[frame]
					}
				}
				channel += channels
				if channel >= 2 { break }
			}
		}

		// MARK: Core Audio lookups

		/// A plain-value property (no object references: use `readString` for CFString properties).
		private static func read<T: BitwiseCopyable>(
			object: AudioObjectID, address: AudioObjectPropertyAddress, initial: T
		) -> T? {
			var address = address
			var value = initial
			var size = UInt32(MemoryLayout<T>.size)
			return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == 0 ? value : nil
		}

		/// A CFString property. Core Audio hands back a retained reference, which this takes ownership of.
		private static func readString(object: AudioObjectID, address: AudioObjectPropertyAddress) -> String? {
			var address = address
			var value: Unmanaged<CFString>?
			var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
			guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == 0, let value else {
				return nil
			}
			return value.takeRetainedValue() as String
		}

		private static func defaultOutput() -> AudioObjectID? {
			read(
				object: AudioObjectID(kAudioObjectSystemObject), address: AudioDucker.defaultOutputAddress,
				initial: AudioObjectID(0)
			)
			.flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
		}

		private static func processObject(pid: pid_t) -> AudioObjectID? {
			var address = AudioObjectPropertyAddress(
				mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
				mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
			var pid = pid
			var object = AudioObjectID(kAudioObjectUnknown)
			var size = UInt32(MemoryLayout<AudioObjectID>.size)
			let status = AudioObjectGetPropertyData(
				AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size,
				&object)
			return status == 0 && object != kAudioObjectUnknown ? object : nil
		}

		private static func uid(device: AudioObjectID) -> String? {
			let address = AudioObjectPropertyAddress(
				mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
				mElement: kAudioObjectPropertyElementMain)
			return readString(object: device, address: address)
		}

		private static func sampleRate(device: AudioObjectID) -> Double {
			let address = AudioObjectPropertyAddress(
				mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
				mElement: kAudioObjectPropertyElementMain)
			return read(object: device, address: address, initial: Float64(48_000)) ?? 48_000
		}

		private static func bufferCount(device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
			var address = AudioObjectPropertyAddress(
				mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
				mElement: kAudioObjectPropertyElementMain)
			var size: UInt32 = 0
			guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == 0, size > 0 else { return 0 }
			let list = AudioBufferList.allocate(maximumBuffers: Int(size) / MemoryLayout<AudioBuffer>.size + 1)
			defer { free(list.unsafeMutablePointer) }
			guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, list.unsafeMutablePointer) == 0 else {
				return 0
			}
			return list.count
		}

		/// The callback writes 32-bit floats, which is what every current Mac output takes.
		private static func isFloatOutput(device: AudioObjectID) -> Bool {
			var address = AudioObjectPropertyAddress(
				mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
				mElement: kAudioObjectPropertyElementMain)
			var size: UInt32 = 0
			guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == 0, size > 0 else { return false }
			var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
			guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == 0 else { return false }
			let formatAddress = AudioObjectPropertyAddress(
				mSelector: kAudioStreamPropertyVirtualFormat, mScope: kAudioObjectPropertyScopeGlobal,
				mElement: kAudioObjectPropertyElementMain)
			return streams.allSatisfy { stream in
				guard let format = read(object: stream, address: formatAddress, initial: AudioStreamBasicDescription())
				else { return false }
				return format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32
					&& format.mFormatFlags & kAudioFormatFlagIsFloat != 0
			}
		}
	}
}

/// The players Bol pauses: the ones that answer AppleScript's play and pause.
enum MediaPlayer: String, CaseIterable {
	case music = "Music"
	case spotify = "Spotify"
	case vlc = "VLC"

	private var bundleID: String {
		switch self {
		case .music: return "com.apple.Music"
		case .spotify: return "com.spotify.client"
		case .vlc: return "org.videolan.vlc"
		}
	}

	/// Only running players are asked: a script that names a closed one would launch it.
	static func running() -> [MediaPlayer] {
		let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
		return allCases.filter { ids.contains($0.bundleID) }
	}

	/// Pauses those that are playing; returns them. Blocks on AppleScript, so not on the main thread.
	static func pause(players: [MediaPlayer]) -> [MediaPlayer] {
		let script = players.map { player in
			let playing = player == .vlc ? "playing" : "player state is playing"
			return """
				try
				  if application "\(player.rawValue)" is running then
				    tell application "\(player.rawValue)"
				      if \(playing) then
				        pause
				        set end of pausedPlayers to "\(player.rawValue)"
				      end if
				    end tell
				  end if
				end try
				"""
		}
		let output = run(script: "set pausedPlayers to {}\n" + script.joined() + "return pausedPlayers")
		return output.split(separator: ",").compactMap {
			MediaPlayer(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines))
		}
	}

	static func resume(players: [MediaPlayer]) {
		let running = Set(Self.running())
		let script = players.filter(running.contains).map { player in
			"try\n  if application \"\(player.rawValue)\" is running then tell application \"\(player.rawValue)\" to play\nend try"
		}
		if !script.isEmpty { _ = run(script: script.joined(separator: "\n")) }
	}

	private static func run(script: String) -> String {
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
		process.arguments = ["-e", script]
		let pipe = Pipe()
		process.standardOutput = pipe
		process.standardError = FileHandle.nullDevice
		do { try process.run() } catch { return "" }
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		return String(data: data, encoding: .utf8) ?? ""
	}
}
