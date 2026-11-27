import AppKit
@testable import Orbit

/// The player's buttons reach the app whose song they show, through macOS's real Now Playing.
///
/// Two stand-in players (tools/regressions/nowplaying-fake-player.swift): a music app plays and pauses,
/// then a video plays and pauses. Now Playing stays on the paused video while Orbit shows the paused
/// song, so play, next, previous and seeking from the widget or the notch must go to the music app,
/// not start the video again. And auto-pause, with both playing, pauses the music rather than the video.
@main struct NowPlayingControlsTests {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        guard args.count == 3 else { print("Usage: nowplaying-controls-tests <players directory> <log>"); exit(2) }
        let dir = args[1], log = args[2]
        var failed = 0
        func check(_ condition: Bool, _ name: String) {
            if !condition { failed += 1 }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

        UserDefaults.standard.setVolatileDomain([NowPlayingPrefs.autoPause: false, NowPlayingPrefs.directControl: false,
                                                 NowPlayingPrefs.sources: "music"], forName: UserDefaults.argumentDomain)
        try? FileManager.default.removeItem(atPath: log)
        func launch(_ name: String, _ title: String) -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "\(dir)/\(name).app/Contents/MacOS/\(name)")
            p.arguments = [title, log]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try! p.run()
            return p
        }
        func commands(_ bundle: String) -> [String] {
            let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map(String.init)
                .filter { $0.contains(" \(bundle) command ") }
                .map { $0.components(separatedBy: " command ").last ?? "" }
        }
        let music = "dev.orbit.test.fakemelon", video = "dev.orbit.test.fakevideo"

        let np = NowPlaying.shared
        np.start()
        let melon = launch("FakeMelon", "Test Song")
        await sleep(1)
        kill(melon.processIdentifier, SIGUSR1)
        await sleep(2)
        kill(melon.processIdentifier, SIGUSR2)
        await sleep(1.5)
        let blog = launch("FakeVideo", "Blog Video")
        await sleep(1)
        kill(blog.processIdentifier, SIGUSR1)
        await sleep(2)
        kill(blog.processIdentifier, SIGUSR2)
        await sleep(2)

        check(np.track?.bundle == music, "shows the paused song (shown: \(np.track?.bundle ?? "nothing"))")
        check(!np.playing, "the song shows as paused")

        np.togglePlayPause()
        await sleep(1.5)
        check(commands(music).count == 1, "play goes to the music app (music got \(commands(music)))")
        check(commands(video).isEmpty, "play doesn't start the video (video got \(commands(video)))")

        np.next()
        await sleep(1)
        check(commands(music).last == "next", "next goes to the music app (music got \(commands(music)))")
        np.previous()
        await sleep(1)
        check(commands(music).last == "previous", "previous goes to the music app (music got \(commands(music)))")
        np.seek(to: 30)
        await sleep(1)
        check(commands(music).last?.hasPrefix("seek 30") == true, "seeking moves the song (music got \(commands(music)))")
        check(commands(video).isEmpty, "the video got nothing (video got \(commands(video)))")

        // Auto-pause: the video plays again over the song, and the song is what has to stop.
        kill(blog.processIdentifier, SIGUSR1)
        await sleep(1.5)
        np.send(.pause, to: music)
        await sleep(1)
        check(commands(music).last == "pause", "auto-pause pauses the music app (music got \(commands(music)))")
        check(commands(video).isEmpty, "auto-pause leaves the video playing (video got \(commands(video)))")

        np.stop()
        melon.terminate()
        blog.terminate()
        print(failed == 0 ? "All passed" : "\(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
