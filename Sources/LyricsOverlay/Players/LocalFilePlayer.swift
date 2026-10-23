import AVFoundation
import AppKit
import LyricsCore
import UniformTypeIdentifiers

/// Plays a local audio file. Lyrics come from a same-named .lrc next to it when
/// there is one; otherwise the model searches online like any other source.
final class LocalFilePlayer: NSObject, MusicSource, AVAudioPlayerDelegate {
    let id = SourceID.localFile

    static let audioTypes: [UTType] = [.mp3, .mpeg4Audio, .wav, .aiff]
        + [UTType(filenameExtension: "flac")].compactMap { $0 }

    private var player: AVAudioPlayer?
    private var title = ""
    private var artist = ""
    private var album = ""
    private var cover: NSImage?
    /// Lyrics from the sidecar .lrc, if any.
    private(set) var sidecarLyrics: [LyricLine]?

    /// Called when playback reaches the end of the file.
    var onFinish: (() -> Void)?

    var isLoaded: Bool { player != nil }

    func load(_ url: URL) async throws {
        let p = try AVAudioPlayer(contentsOf: url)
        p.delegate = self
        p.prepareToPlay()

        let asset = AVURLAsset(url: url)
        let meta = (try? await asset.load(.commonMetadata)) ?? []
        func value(_ key: AVMetadataKey) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: meta, withKey: key, keySpace: .common).first else { return nil }
            return try? await item.load(.stringValue)
        }
        title = await value(.commonKeyTitle) ?? url.deletingPathExtension().lastPathComponent
        artist = await value(.commonKeyArtist) ?? ""
        album = await value(.commonKeyAlbumName) ?? ""
        if let art = AVMetadataItem.metadataItems(from: meta, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common).first,
           let data = try? await art.load(.dataValue) {
            cover = NSImage(data: data)
        } else {
            cover = nil
        }
        sidecarLyrics = LRCParser.load(contentsOf: url.deletingPathExtension().appendingPathExtension("lrc"))

        player?.stop()
        player = p
        log.info("Loaded local file \(url.lastPathComponent, privacy: .public), sidecar LRC: \(self.sidecarLyrics != nil)")
    }

    func eject() {
        player?.stop()
        player = nil
        sidecarLyrics = nil
    }

    func play() { player?.play() }

    func snapshot() async -> PlaybackSnapshot? {
        guard let p = player else { return nil }
        return PlaybackSnapshot(source: id, title: title, artist: artist, album: album,
                                position: p.currentTime, duration: p.duration,
                                isPaused: !p.isPlaying, fetchedAt: Date(), artworkURL: nil)
    }

    func artwork(for snapshot: PlaybackSnapshot) async -> NSImage? { cover }

    func playPause() async {
        guard let p = player else { return }
        if p.isPlaying { p.pause() } else { p.play() }
    }
    func next() async { player?.currentTime = player?.duration ?? 0 }
    func previous() async { player?.currentTime = 0 }
    func seek(to seconds: TimeInterval) async { player?.currentTime = seconds }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.onFinish?() }
    }
}
