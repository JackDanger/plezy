import Foundation
import AVFoundation
import Combine

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
    
    // Play queue reference for refreshing from Plex
    var playQueueRef: PlayQueueReference?
    
    var currentItem: QueueItem? {
        guard currentIndex >= 0 && currentIndex < queue.count else { return nil }
        return queue[currentIndex]
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
            } else {
                isPlaying = false
            }
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
            
            // Convert metadata to QueueItems
            let items = metadata.compactMap { item -> QueueItem? in
                guard let key = item["ratingKey"] as? String,
                      let title = item["title"] as? String else { return nil }
                
                // Build stream URL
                guard let media = (item["Media"] as? [[String: Any]])?.first,
                      let part = (media["Part"] as? [[String: Any]])?.first,
                      let partKey = part["key"] as? String else { return nil }
                
                let streamUrl = "\(ref.plexServerUrl)\(partKey)?X-Plex-Token=\(ref.plexToken)"
                
                // Get album art URL
                var albumArtUrl: String?
                if let thumb = item["thumb"] as? String {
                    albumArtUrl = "\(ref.plexServerUrl)\(thumb)?X-Plex-Token=\(ref.plexToken)"
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
        }
    }
    
    // MARK: - Playback Controls
    
    func play() {
        if playerItem == nil, let item = currentItem {
            loadAndPlay(item)
        } else {
            player?.play()
            isPlaying = true
        }
    }
    
    func pause() {
        player?.pause()
        isPlaying = false
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
    }
    
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
    
    init(from dict: [String: Any]) {
        self.id = dict["id"] as? String ?? UUID().uuidString
        self.title = dict["title"] as? String ?? "Unknown"
        self.artist = dict["artist"] as? String
        self.albumArtUrl = dict["albumArtUrl"] as? String
        self.streamUrl = dict["streamUrl"] as? String ?? ""
        self.plexToken = dict["plexToken"] as? String ?? ""
        self.duration = dict["duration"] as? Double ?? 0
    }
}

/// Reference to a Plex play queue for direct fetching
struct PlayQueueReference {
    let playQueueId: Int
    let plexServerUrl: String
    let plexToken: String
    let currentIndex: Int
    
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

