import SwiftUI

struct LocalPlaybackView: View {
    @StateObject private var audioPlayer = WatchAudioPlayer.shared
    @EnvironmentObject var connectivity: WatchConnectivityManager
    @State private var selectedPage: Int = 0
    @State private var dragOffset: CGFloat = 0
    
    var body: some View {
        TabView(selection: $selectedPage) {
            // Page 0: Main playback screen
            MainPlaybackPage(dragOffset: $dragOffset, onDismiss: {
                connectivity.stopLocalPlayback()
            })
            .tag(0)
            
            // Page 1: Queue controls (swipe left to access)
            QueueControlsPage()
                .tag(1)
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
                    // If dragged down more than 50 points, dismiss
                    if selectedPage == 0 && value.translation.height > 50 {
                        withAnimation(.easeOut(duration: 0.2)) {
                            dragOffset = 200
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            connectivity.stopLocalPlayback()
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
    @Binding var dragOffset: CGFloat
    var onDismiss: () -> Void
    
    var body: some View {
        VStack(spacing: 6) {
            // Album art
            LocalAlbumArtView(url: audioPlayer.currentItem?.albumArtUrl, token: audioPlayer.currentItem?.plexToken)
                .frame(width: 90, height: 90)
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
            
            // Main playback controls only
            HStack(spacing: 20) {
                Button(action: { audioPlayer.previous() }) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .opacity((audioPlayer.canGoPrevious || audioPlayer.currentPosition >= 3) ? 1.0 : 0.4)
                
                Button(action: { audioPlayer.togglePlayPause() }) {
                    Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .disabled(audioPlayer.isLoading)
                
                Button(action: { audioPlayer.next() }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .opacity(audioPlayer.canGoNext ? 1.0 : 0.4)
            }
            .padding(.top, 4)
            
            // Queue position + hint to swipe
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 8)
    }
}

// MARK: - Queue Controls Page
struct QueueControlsPage: View {
    @StateObject private var audioPlayer = WatchAudioPlayer.shared
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Queue")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            
            // Shuffle button
            Button(action: { audioPlayer.toggleShuffle() }) {
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
            Button(action: { audioPlayer.toggleRepeatMode() }) {
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
            Button(action: { audioPlayer.restartQueue() }) {
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
            
            Spacer()
            
            // Swipe hint
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Text("Swipe for player")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
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

struct LocalAlbumArtView: View {
    let url: String?
    let token: String?
    @State private var image: UIImage?
    @State private var isLoading = false
    
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
            loadImage()
        }
    }
    
    private func loadImage() {
        guard let urlString = url, let url = URL(string: urlString), let token = token else {
            return
        }
        
        isLoading = true
        
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async {
                isLoading = false
                if let data = data, let uiImage = UIImage(data: data) {
                    self.image = uiImage
                }
            }
        }.resume()
    }
}

#Preview {
    LocalPlaybackView()
        .environmentObject(WatchConnectivityManager.shared)
}

