import SwiftUI
import WatchKit

struct LocalPlaybackView: View {
    @StateObject private var audioPlayer = WatchAudioPlayer.shared
    @EnvironmentObject var connectivity: WatchConnectivityManager
    @State private var selectedPage: Int = 0
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        TabView(selection: $selectedPage) {
            // Page 0: Main playback screen
            MainPlaybackPage(dragOffset: $dragOffset, onDismiss: {
                // Dismiss to background — audio keeps playing
                connectivity.dismissToBackground()
            })
            .tag(0)

            // Page 1: Queue controls (swipe left to access)
            QueueControlsPage()
                .tag(1)

            // Page 2: Up Next
            UpNextPage()
                .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .automatic))
        .offset(y: dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Only allow dragging down (positive translation) when on main page
                    if selectedPage == 0 && value.translation.height > 0 {
                        dragOffset = value.translation.height
                    }
                }
                .onEnded { value in
                    // If dragged down more than 50 points, dismiss to background
                    if selectedPage == 0 && value.translation.height > 50 {
                        withAnimation(.easeOut(duration: 0.2)) {
                            dragOffset = 200
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            connectivity.dismissToBackground()
                            dragOffset = 0
                        }
                    } else {
                        withAnimation(.spring(response: 0.3)) {
                            dragOffset = 0
                        }
                    }
                }
        )
    }
}

// MARK: - Main Playback Page
struct MainPlaybackPage: View {
    @StateObject private var audioPlayer = WatchAudioPlayer.shared
    @EnvironmentObject var connectivity: WatchConnectivityManager
    @Binding var dragOffset: CGFloat
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            // Album art
            LocalAlbumArtView(url: audioPlayer.currentItem?.albumArtUrl, token: audioPlayer.currentItem?.plexToken)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Track info
            VStack(spacing: 2) {
                Text(audioPlayer.currentItem?.title ?? "Loading...")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                if let artist = audioPlayer.currentItem?.artist {
                    Text(artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)

            // Progress bar
            if audioPlayer.duration > 0 {
                ProgressView(value: min(audioPlayer.currentPosition, audioPlayer.duration), total: audioPlayer.duration)
                    .tint(.white.opacity(0.6))
                    .scaleEffect(y: 0.5)
                    .padding(.horizontal, 8)
            }

            // Loading indicator
            if audioPlayer.isLoading {
                ProgressView()
                    .scaleEffect(0.8)
            }

            // Error display
            if let error = audioPlayer.error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            // Main playback controls
            HStack(spacing: 20) {
                Button(action: {
                    WKInterfaceDevice.current().play(.click)
                    audioPlayer.previous()
                }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .opacity((audioPlayer.canGoPrevious || audioPlayer.currentPosition >= 3) ? 1.0 : 0.4)

                Button(action: {
                    WKInterfaceDevice.current().play(.click)
                    audioPlayer.togglePlayPause()
                }) {
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .disabled(audioPlayer.isLoading)

                Button(action: {
                    WKInterfaceDevice.current().play(.click)
                    audioPlayer.next()
                }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .opacity(audioPlayer.canGoNext ? 1.0 : 0.4)
            }
            .padding(.top, 2)

            // Radio + queue position
            HStack(spacing: 12) {
                if PlexWatchClient.shared.hasCredentials, let item = audioPlayer.currentItem {
                    Button(action: { startRadio(from: item) }) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 12))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }

                if audioPlayer.queue.count > 1 {
                    HStack(spacing: 4) {
                        Text("\(audioPlayer.currentIndex + 1)/\(audioPlayer.queue.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.left")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8)
    }

    private func startRadio(from item: QueueItem) {
        Task {
            let client = PlexWatchClient.shared
            guard let result = await client.createRadioStation(ratingKey: item.id) else {
                WKInterfaceDevice.current().play(.failure)
                return
            }
            let queueItems = result.items.compactMap { $0.toQueueItem(client: client) }
            if !queueItems.isEmpty {
                let queueRef = result.toQueueReference(client: client)
                await MainActor.run {
                    WatchAudioPlayer.shared.loadQueue(queueItems, queueRef: queueRef)
                }
            } else {
                WKInterfaceDevice.current().play(.failure)
            }
        }
    }
}

// MARK: - Queue Controls Page
struct QueueControlsPage: View {
    @StateObject private var audioPlayer = WatchAudioPlayer.shared
    @EnvironmentObject var connectivity: WatchConnectivityManager

    var body: some View {
        VStack(spacing: 12) {
            Text("Queue")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            // Shuffle button
            Button(action: {
                WKInterfaceDevice.current().play(.success)
                audioPlayer.toggleShuffle()
            }) {
                HStack {
                    Image(systemName: "shuffle")
                        .font(.system(size: 18))
                    Text("Shuffle")
                        .font(.system(size: 14))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(audioPlayer.isShuffled ? Color.blue.opacity(0.3) : Color.gray.opacity(0.2))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .foregroundColor(audioPlayer.isShuffled ? .blue : .primary)

            // Repeat button
            Button(action: {
                WKInterfaceDevice.current().play(.click)
                audioPlayer.toggleRepeatMode()
            }) {
                HStack {
                    Image(systemName: audioPlayer.repeatMode.icon)
                        .font(.system(size: 18))
                    Text(repeatModeLabel)
                        .font(.system(size: 14))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(audioPlayer.repeatMode.isActive ? Color.blue.opacity(0.3) : Color.gray.opacity(0.2))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .foregroundColor(audioPlayer.repeatMode.isActive ? .blue : .primary)

            // Restart button
            Button(action: {
                WKInterfaceDevice.current().play(.click)
                audioPlayer.restartQueue()
            }) {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 18))
                    Text("Restart")
                        .font(.system(size: 14))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)

            // Stop button (explicit stop clears queue)
            Button(action: {
                WKInterfaceDevice.current().play(.stop)
                connectivity.stopLocalPlayback()
            }) {
                HStack {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 18))
                    Text("Stop")
                        .font(.system(size: 14))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.red.opacity(0.2))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var repeatModeLabel: String {
        switch audioPlayer.repeatMode {
        case .off: return "Repeat"
        case .one: return "Repeat One"
        case .all: return "Repeat All"
        }
    }
}

// MARK: - Up Next Page
struct UpNextPage: View {
    @StateObject private var audioPlayer = WatchAudioPlayer.shared

    var body: some View {
        VStack(spacing: 6) {
            Text("Up Next")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            if audioPlayer.currentIndex + 1 >= audioPlayer.queue.count {
                Spacer()
                Text("No more tracks")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        let startIndex = min(audioPlayer.currentIndex + 1, audioPlayer.queue.count)
                        let endIndex = min(startIndex + 15, audioPlayer.queue.count)

                        ForEach(startIndex..<endIndex, id: \.self) { index in
                            let track = audioPlayer.queue[index]
                            Button(action: {
                                WKInterfaceDevice.current().play(.click)
                                audioPlayer.skipTo(index: index)
                            }) {
                                HStack(spacing: 6) {
                                    Text("\(index - audioPlayer.currentIndex)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(track.title)
                                            .font(.system(size: 11))
                                            .lineLimit(1)
                                        if let artist = track.artist {
                                            Text(artist)
                                                .font(.system(size: 9))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

struct LocalAlbumArtView: View {
    let url: String?
    let token: String?
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var loadingUrl: String?

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            loadImage()
        }
        .onChange(of: url) { _ in
            image = nil
            loadImage()
        }
    }

    private func loadImage() {
        guard let urlString = url else { return }

        // Try cache first
        if let cached = WatchImageCache.shared.get(urlString) {
            self.image = cached
            return
        }

        isLoading = true
        loadingUrl = urlString
        WatchImageCache.shared.loadImage(urlString: urlString, token: token) { loaded in
            // Only apply if this is still the URL we're loading
            guard loadingUrl == urlString else { return }
            isLoading = false
            self.image = loaded
        }
    }
}

#Preview {
    LocalPlaybackView()
        .environmentObject(WatchConnectivityManager.shared)
}
