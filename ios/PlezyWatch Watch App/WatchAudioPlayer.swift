import Foundation
import AVFoundation
import Combine
import MediaPlayer

/// Repeat mode for queue playback
enum RepeatMode: Int, CaseIterable {
    case off = 0
    case one = 1
    case all = 2

    var icon: String {
        switch self {
        case .off: return "repeat"
        case .one: return "repeat.1"
        case .all: return "repeat"
        }
    }

    var isActive: Bool {
        self != .off
    }

    func next() -> RepeatMode {
        let allCases = RepeatMode.allCases
        let currentIndex = allCases.firstIndex(of: self)!
        let nextIndex = (currentIndex + 1) % allCases.count
        return allCases[nextIndex]
    }
}

/// Audio player for the Apple Watch app
/// Handles streaming audio playback from Plex servers
class WatchAudioPlayer: NSObject, ObservableObject {
    static let shared = WatchAudioPlayer()

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()

    // Published state
    @Published var isPlaying = false
    @Published var currentPosition: Double = 0
    @Published var duration: Double = 0
    @Published var isLoading = false
    @Published var error: String?

    // Queue management
    @Published var queue: [QueueItem] = []
    @Published var currentIndex: Int = 0

    // Queue mode settings
    @Published var repeatMode: RepeatMode = .off
    @Published var isShuffled: Bool = false

    // Original queue order (for un-shuffling)
    private var originalQueue: [QueueItem] = []
    private var shuffledIndices: [Int] = []
    private var isFetchingMore = false

    // Play queue reference for refreshing from Plex
    var playQueueRef: PlayQueueReference?

    var currentItem: QueueItem? {
        guard currentIndex >= 0 && currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    /// Whether there's a queue loaded (even if paused)
    var hasQueue: Bool {
        !queue.isEmpty
    }

    var canGoNext: Bool {
        // Can always go next if repeat all is on
        if repeatMode == .all && queue.count > 0 {
            return true
        }
        return currentIndex < queue.count - 1
    }

    var canGoPrevious: Bool {
        // Can always go previous if repeat all is on
        if repeatMode == .all && queue.count > 0 {
            return true
        }
        return currentIndex > 0
    }

    override init() {
        super.init()
        setupAudioSession()
        setupNotifications()
        setupRemoteCommandCenter()
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try session.setActive(true)
        } catch {
            print("Failed to setup audio session: \(error)")
        }
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            print("[WatchAudio] Audio session interrupted")
            DispatchQueue.main.async { self.isPlaying = false }
        case .ended:
            print("[WatchAudio] Audio session interruption ended")
            if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    print("[WatchAudio] Resuming playback after interruption")
                    DispatchQueue.main.async {
                        self.player?.play()
                        self.isPlaying = true
                        self.updateNowPlayingInfo()
                    }
                }
            }
        @unknown default:
            break
        }
    }

    /// Set up MPRemoteCommandCenter for system Now Playing controls (Digital Crown volume, etc.)
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }

        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    /// Update MPNowPlayingInfoCenter with current track info
    private func updateNowPlayingInfo() {
        var info = [String: Any]()

        if let item = currentItem {
            info[MPMediaItemPropertyTitle] = item.title
            info[MPMediaItemPropertyArtist] = item.artist ?? ""
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentPosition
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    @objc private func playerItemDidFinish() {
        switch repeatMode {
        case .one:
            // Repeat current track
            seek(to: 0)
            play()
        case .all:
            // Go to next, wrapping to beginning if at end
            if currentIndex < queue.count - 1 {
                currentIndex += 1
            } else {
                currentIndex = 0 // Wrap to beginning
            }
            if let item = currentItem {
                loadAndPlay(item)
            }
        case .off:
            // Normal behavior: go to next or stop
            if currentIndex < queue.count - 1 {
                currentIndex += 1
                if let item = currentItem {
                    loadAndPlay(item)
                }
            } else if playQueueRef != nil {
                // Radio/continuous queue — try to fetch more tracks from Plex
                print("[WatchAudio] End of queue, fetching more tracks from Plex...")
                fetchMoreTracks()
            } else {
                isPlaying = false
                updateNowPlayingInfo()
            }
        }

        // Pre-fetch more tracks when we're a few tracks from the end
        if playQueueRef != nil && currentIndex >= queue.count - 3 && queue.count > 1 {
            print("[WatchAudio] Near end of queue (\(currentIndex)/\(queue.count)), pre-fetching more...")
            prefetchMoreTracks()
        }
    }

    /// Fetch more tracks and continue playing (called when queue is exhausted)
    private func fetchMoreTracks() {
        isLoading = true
        Task {
            let success = await refreshQueueFromPlex()
            await MainActor.run {
                self.isLoading = false
                if success && !self.queue.isEmpty {
                    // Queue was replaced with fresh tracks — start from beginning
                    self.currentIndex = 0
                    if let item = self.currentItem {
                        self.loadAndPlay(item)
                    }
                } else {
                    print("[WatchAudio] Failed to fetch more tracks, stopping")
                    self.isPlaying = false
                    self.updateNowPlayingInfo()
                }
            }
        }
    }

    /// Pre-fetch more tracks and append them to the current queue
    private func prefetchMoreTracks() {
        guard !isFetchingMore else { return }
        isFetchingMore = true
        Task {
            let newItems = await fetchAdditionalTracks()
            await MainActor.run {
                self.isFetchingMore = false
                if !newItems.isEmpty {
                    self.queue.append(contentsOf: newItems)
                    self.originalQueue.append(contentsOf: newItems)
                    print("[WatchAudio] Appended \(newItems.count) tracks, queue now \(self.queue.count)")
                }
            }
        }
    }

    /// Fetch additional tracks from the play queue without replacing current queue
    private func fetchAdditionalTracks() async -> [QueueItem] {
        guard let ref = playQueueRef else { return [] }

        let urlString = "\(ref.plexServerUrl)/playQueues/\(ref.playQueueId)?X-Plex-Token=\(ref.plexToken)"
        guard let url = URL(string: urlString) else { return [] }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return [] }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mediaContainer = json["MediaContainer"] as? [String: Any],
                  let metadata = mediaContainer["Metadata"] as? [[String: Any]] else { return [] }

            let existingIds = Set(queue.map { $0.id })
            let audioTypes: Set<String> = ["track"]

            let client = PlexWatchClient.shared
            let newItems: [QueueItem] = metadata.compactMap { item in
                let itemType = item["type"] as? String ?? ""
                guard audioTypes.contains(itemType) else { return nil }
                guard let key = item["ratingKey"] as? String else { return nil }
                guard !existingIds.contains(key) else { return nil }
                guard let title = item["title"] as? String else { return nil }
                guard let streamUrl = client.streamUrl(ratingKey: key) else { return nil }

                var albumArtUrl: String?
                if let thumb = item["thumb"] as? String {
                    albumArtUrl = client.thumbnailUrl(thumb)
                }

                return QueueItem(from: [
                    "id": key,
                    "title": title,
                    "artist": item["grandparentTitle"] ?? item["parentTitle"] ?? "",
                    "albumArtUrl": albumArtUrl as Any,
                    "streamUrl": streamUrl,
                    "plexToken": ref.plexToken,
                    "duration": (item["duration"] as? Double ?? 0) / 1000.0
                ])
            }
            return newItems
        } catch {
            print("[WatchAudio] Error fetching additional tracks: \(error)")
            return []
        }
    }

    /// Load a queue of items to play
    func loadQueue(_ items: [QueueItem], startIndex: Int = 0, queueRef: PlayQueueReference? = nil) {
        queue = items
        originalQueue = items
        currentIndex = startIndex
        playQueueRef = queueRef
        isShuffled = false
        shuffledIndices = []

        print("[WatchAudio] Loading queue with \(items.count) items, startIndex: \(startIndex)")
        if let ref = queueRef {
            print("[WatchAudio] Play queue ref: \(ref.playQueueId) at \(ref.plexServerUrl)")
        }

        if let item = currentItem {
            loadAndPlay(item)
        }
    }

    /// Refresh the queue from Plex using the stored play queue reference
    func refreshQueueFromPlex() async -> Bool {
        guard let ref = playQueueRef else {
            print("[WatchAudio] No play queue reference to refresh from")
            return false
        }

        print("[WatchAudio] Refreshing queue from Plex: \(ref.playQueueId)")

        // Build the play queue URL
        let urlString = "\(ref.plexServerUrl)/playQueues/\(ref.playQueueId)?X-Plex-Token=\(ref.plexToken)"
        guard let url = URL(string: urlString) else {
            print("[WatchAudio] Invalid URL for play queue")
            return false
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("[WatchAudio] Failed to fetch play queue: bad response")
                return false
            }

            // Parse the play queue response
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mediaContainer = json["MediaContainer"] as? [String: Any],
                  let metadata = mediaContainer["Metadata"] as? [[String: Any]] else {
                print("[WatchAudio] Failed to parse play queue response")
                return false
            }

            // Convert metadata to QueueItems, filtering out video content
            let audioTypes: Set<String> = ["track"]
            var items: [QueueItem] = []
            for item in metadata {
                let itemType = item["type"] as? String ?? ""
                guard audioTypes.contains(itemType) else {
                    print("[WatchAudio] Skipping non-audio item: \(item["title"] ?? "?") (type: \(itemType))")
                    continue
                }

                guard let key = item["ratingKey"] as? String,
                      let title = item["title"] as? String else { continue }

                let client = PlexWatchClient.shared
                guard let streamUrl = client.streamUrl(ratingKey: key) else { continue }

                var albumArtUrl: String?
                if let thumb = item["thumb"] as? String {
                    albumArtUrl = client.thumbnailUrl(thumb)
                }

                if let qi = QueueItem(from: [
                    "id": key,
                    "title": title,
                    "artist": item["grandparentTitle"] ?? item["parentTitle"] ?? "",
                    "albumArtUrl": albumArtUrl as Any,
                    "streamUrl": streamUrl,
                    "plexToken": ref.plexToken,
                    "duration": (item["duration"] as? Double ?? 0) / 1000.0
                ]) {
                    items.append(qi)
                }
            }

            if !items.isEmpty {
                await MainActor.run {
                    self.queue = items
                    print("[WatchAudio] Refreshed queue with \(items.count) items")
                }
                return true
            }

            return false
        } catch {
            print("[WatchAudio] Error refreshing queue: \(error)")
            return false
        }
    }

    /// Load and play a specific item
    private func loadAndPlay(_ item: QueueItem) {
        isLoading = true
        error = nil

        guard let url = URL(string: item.streamUrl) else {
            error = "Invalid URL"
            isLoading = false
            return
        }

        // Create player item with headers for Plex authentication
        var request = URLRequest(url: url)
        request.setValue(item.plexToken, forHTTPHeaderField: "X-Plex-Token")

        // Use AVURLAsset with custom options for authentication
        let headers = ["X-Plex-Token": item.plexToken]
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])

        playerItem = AVPlayerItem(asset: asset)

        // Observe status
        playerItem?.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                switch status {
                case .readyToPlay:
                    self?.isLoading = false
                    self?.duration = self?.playerItem?.duration.seconds ?? 0
                    self?.player?.play()
                    self?.isPlaying = true
                    self?.updateNowPlayingInfo()
                case .failed:
                    self?.error = self?.playerItem?.error?.localizedDescription ?? "Playback failed"
                    self?.isLoading = false
                default:
                    break
                }
            }
            .store(in: &cancellables)

        if player == nil {
            player = AVPlayer(playerItem: playerItem)
        } else {
            player?.replaceCurrentItem(with: playerItem)
        }

        setupTimeObserver()
        updateNowPlayingInfo()
    }

    private func setupTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }

        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1),
            queue: .main
        ) { [weak self] time in
            self?.currentPosition = time.seconds
            self?.updateNowPlayingInfo()
        }
    }

    // MARK: - Playback Controls

    func play() {
        if playerItem == nil, let item = currentItem {
            loadAndPlay(item)
        } else {
            player?.play()
            isPlaying = true
            updateNowPlayingInfo()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func next() {
        guard queue.count > 0 else { return }

        if currentIndex < queue.count - 1 {
            currentIndex += 1
        } else if repeatMode == .all {
            // Wrap to beginning
            currentIndex = 0
        } else {
            return // Can't go next
        }

        if let item = currentItem {
            loadAndPlay(item)
        }
    }

    func previous() {
        guard queue.count > 0 else { return }

        // If more than 3 seconds in, restart current track
        if currentPosition > 3 {
            seek(to: 0)
            return
        }

        if currentIndex > 0 {
            currentIndex -= 1
        } else if repeatMode == .all {
            // Wrap to end
            currentIndex = queue.count - 1
        } else {
            return // Can't go previous
        }

        if let item = currentItem {
            loadAndPlay(item)
        }
    }

    func seek(to position: Double) {
        let time = CMTime(seconds: position, preferredTimescale: 1)
        player?.seek(to: time)
        currentPosition = position
        updateNowPlayingInfo()
    }

    /// Stop playback and clear the queue entirely
    func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerItem = nil
        isPlaying = false
        currentPosition = 0
        queue = []
        originalQueue = []
        currentIndex = 0
        isShuffled = false
        shuffledIndices = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Queue Management

    /// Toggle repeat mode (off -> one -> all -> off)
    func toggleRepeatMode() {
        repeatMode = repeatMode.next()
        print("[WatchAudio] Repeat mode: \(repeatMode)")
    }

    /// Toggle shuffle mode
    func toggleShuffle() {
        if isShuffled {
            unshuffle()
        } else {
            shuffle()
        }
    }

    /// Shuffle the queue, keeping current track at the front
    private func shuffle() {
        guard queue.count > 1 else { return }

        // Get the current item
        let currentItem = self.currentItem

        // Create shuffled version (excluding current item)
        var itemsToShuffle = queue.filter { $0.id != currentItem?.id }
        itemsToShuffle.shuffle()

        // Put current item at front
        if let current = currentItem {
            queue = [current] + itemsToShuffle
            currentIndex = 0
        } else {
            queue.shuffle()
        }

        isShuffled = true
        print("[WatchAudio] Queue shuffled, \(queue.count) items")
    }

    /// Restore original queue order
    private func unshuffle() {
        guard !originalQueue.isEmpty else { return }

        // Find current item's position in original queue
        let currentItemId = currentItem?.id
        queue = originalQueue

        if let id = currentItemId,
           let originalIndex = originalQueue.firstIndex(where: { $0.id == id }) {
            currentIndex = originalIndex
        } else {
            // Current item not found in original queue — clamp to valid range
            currentIndex = min(currentIndex, max(0, queue.count - 1))
            print("[WatchAudio] Unshuffle: current item not found in original queue, clamped to \(currentIndex)")
        }

        isShuffled = false
        print("[WatchAudio] Queue unshuffled, restored to original order")
    }

    /// Restart the queue from the beginning
    func restartQueue() {
        guard !queue.isEmpty else { return }

        currentIndex = 0
        if let item = currentItem {
            loadAndPlay(item)
        }
        print("[WatchAudio] Queue restarted from beginning")
    }

    /// Skip to a specific index in the queue
    func skipTo(index: Int) {
        guard index >= 0 && index < queue.count else { return }
        currentIndex = index
        if let item = currentItem {
            loadAndPlay(item)
        }
    }
}

/// Represents a playable item in the queue
struct QueueItem: Identifiable, Codable {
    let id: String
    let title: String
    let artist: String?
    let albumArtUrl: String?
    let streamUrl: String
    let plexToken: String
    let duration: Double

    init?(from dict: [String: Any]) {
        guard let streamUrl = dict["streamUrl"] as? String, !streamUrl.isEmpty else {
            print("[WatchAudio] QueueItem init failed: missing streamUrl")
            return nil
        }
        guard let plexToken = dict["plexToken"] as? String, !plexToken.isEmpty else {
            print("[WatchAudio] QueueItem init failed: missing plexToken")
            return nil
        }
        self.id = dict["id"] as? String ?? UUID().uuidString
        self.title = dict["title"] as? String ?? "Unknown"
        self.artist = dict["artist"] as? String
        self.albumArtUrl = dict["albumArtUrl"] as? String
        self.streamUrl = streamUrl
        self.plexToken = plexToken
        self.duration = dict["duration"] as? Double ?? 0
    }
}

/// Reference to a Plex play queue for direct fetching
struct PlayQueueReference {
    let playQueueId: Int
    let plexServerUrl: String
    let plexToken: String
    let currentIndex: Int

    init(playQueueId: Int, plexServerUrl: String, plexToken: String, currentIndex: Int) {
        self.playQueueId = playQueueId
        self.plexServerUrl = plexServerUrl
        self.plexToken = plexToken
        self.currentIndex = currentIndex
    }

    init?(from dict: [String: Any]) {
        guard let id = dict["playQueueId"] as? Int,
              let url = dict["plexServerUrl"] as? String,
              let token = dict["plexToken"] as? String else {
            return nil
        }
        self.playQueueId = id
        self.plexServerUrl = url
        self.plexToken = token
        self.currentIndex = dict["currentIndex"] as? Int ?? 0
    }
}
