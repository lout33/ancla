import Foundation

/// Pauses whatever is playing (Music, Spotify, YouTube in a browser — anything
/// that shows up in macOS Now Playing) and resumes it afterwards.
enum Media {
    struct NowPlaying {
        let app: String
        let title: String
    }

    // Since macOS 15.4, MediaRemote no longer reports playback state to
    // third-party processes, but it still does to Apple-signed ones such as
    // osascript. Sending commands still works directly.
    private static let probeScript = """
    function run() {
      $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/').load;
      const R = $.NSClassFromString('MRNowPlayingRequest');
      if (!R || !R.localIsPlaying) return '';
      let app = '', title = '';
      try { app = ObjC.unwrap(R.localNowPlayingPlayerPath.client.displayName) || ''; } catch (e) {}
      try { title = ObjC.unwrap(R.localNowPlayingItem.nowPlayingInfo.valueForKey('kMRMediaRemoteNowPlayingInfoTitle')) || ''; } catch (e) {}
      return 'playing\\t' + app + '\\t' + title;
    }
    """

    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
    private static let sendCommand: SendCommand? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let sym = dlsym(h, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(sym, to: SendCommand.self)
    }()
    private static let play: UInt32 = 0
    private static let pause: UInt32 = 1

    /// What is playing right now, or nil if nothing is (or the probe failed).
    static func nowPlaying() -> NowPlaying? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", "-e", probeScript]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Never let a hung probe delay the rep.
        let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: deadline)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        deadline.cancel()
        guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              line.hasPrefix("playing") else { return nil }
        let parts = line.components(separatedBy: "\t")
        return NowPlaying(app: parts.count > 1 ? parts[1] : "", title: parts.count > 2 ? parts[2] : "")
    }

    /// Pauses only if something is actually playing, so the matching resume
    /// can never start media the user had paused on purpose.
    static func pauseIfPlaying() -> NowPlaying? {
        guard let playing = nowPlaying(), let send = sendCommand else { return nil }
        _ = send(pause, nil)
        return playing
    }

    static func resume() {
        _ = sendCommand?(play, nil)
    }
}
