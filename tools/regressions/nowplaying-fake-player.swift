// A stand-in player for tools/regressions/nowplaying-controls-tests.swift: registers with Now Playing,
// plays silence and logs every remote command it gets. SIGUSR1 plays and SIGUSR2 pauses, as the user
// would in the app itself.
import AVFoundation
import AppKit
import MediaPlayer

let args = CommandLine.arguments
let title = args.count > 1 ? args[1] : "Song"
let log = args.count > 2 ? args[2] : "/tmp/fakeplayer.log"

func write(_ s: String) {
    let line = "\(Date().timeIntervalSince1970) \(Bundle.main.bundleIdentifier ?? "?") \(s)\n"
    if let h = FileHandle(forWritingAtPath: log) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? Data(line.utf8).write(to: URL(fileURLWithPath: log)) }
}

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player)
let format = engine.mainMixerNode.outputFormat(forBus: 0)
engine.connect(player, to: engine.mainMixerNode, format: format)
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate))!
buffer.frameLength = buffer.frameCapacity // zeros: silence
try! engine.start()

let center = MPNowPlayingInfoCenter.default()
var started = Date()
var offset = 0.0
var playing = false

func publish() {
    center.nowPlayingInfo = [
        MPMediaItemPropertyTitle: title,
        MPMediaItemPropertyArtist: "Tester",
        MPMediaItemPropertyPlaybackDuration: 240.0,
        MPNowPlayingInfoPropertyElapsedPlaybackTime: offset + (playing ? Date().timeIntervalSince(started) : 0),
        MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
    ]
    center.playbackState = playing ? .playing : .paused
}

func resume() {
    guard !playing else { return }
    playing = true; started = Date()
    player.scheduleBuffer(buffer, at: nil, options: .loops)
    player.play()
    publish()
}

func halt() {
    guard playing else { return }
    offset += Date().timeIntervalSince(started)
    playing = false
    player.pause()
    publish()
}

let commands = MPRemoteCommandCenter.shared()
commands.togglePlayPauseCommand.addTarget { _ in write("command togglePlayPause"); playing ? halt() : resume(); return .success }
commands.playCommand.addTarget { _ in write("command play"); resume(); return .success }
commands.pauseCommand.addTarget { _ in write("command pause"); halt(); return .success }
commands.nextTrackCommand.addTarget { _ in write("command next"); return .success }
commands.previousTrackCommand.addTarget { _ in write("command previous"); return .success }
commands.changePlaybackPositionCommand.addTarget { e in
    let p = (e as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? -1
    write("command seek \(p)"); offset = p; started = Date(); publish(); return .success
}

signal(SIGUSR1, SIG_IGN); signal(SIGUSR2, SIG_IGN)
let s1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
s1.setEventHandler { write("user play"); resume() }
s1.resume()
let s2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
s2.setEventHandler { write("user pause"); halt() }
s2.resume()

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
write("started")
publish()
NSApp.run()
