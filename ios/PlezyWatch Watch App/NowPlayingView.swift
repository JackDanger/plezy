import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject var connectivity: WatchConnectivityManager
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 8) {
                // Album art
                AlbumArtView(imageData: connectivity.albumArtData)
                    .frame(
                        width: min(geometry.size.width - 16, 120),
                        height: min(geometry.size.width - 16, 120)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                
                // Track info
                VStack(spacing: 2) {
                    Text(connectivity.trackTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    
                    if let artist = connectivity.trackArtist {
                        Text(artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
                
                // Playback controls
                PlaybackControlsView()
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 8)
    }
}

struct AlbumArtView: View {
    let imageData: Data?
    
    var body: some View {
        Group {
            if let data = imageData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // Placeholder
                ZStack {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                    Image(systemName: "music.note")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct PlaybackControlsView: View {
    @EnvironmentObject var connectivity: WatchConnectivityManager
    
    var body: some View {
        HStack(spacing: 20) {
            // Previous
            Button(action: {
                connectivity.sendCommand(.previous)
            }) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 20))
            }
            .buttonStyle(.plain)
            .disabled(!connectivity.canGoPrevious)
            .opacity(connectivity.canGoPrevious ? 1.0 : 0.4)
            
            // Play/Pause
            Button(action: {
                connectivity.sendCommand(connectivity.isPlaying ? .pause : .play)
            }) {
                Image(systemName: connectivity.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28))
            }
            .buttonStyle(.plain)
            
            // Next
            Button(action: {
                connectivity.sendCommand(.next)
            }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 20))
            }
            .buttonStyle(.plain)
            .disabled(!connectivity.canGoNext)
            .opacity(connectivity.canGoNext ? 1.0 : 0.4)
        }
    }
}

#Preview {
    NowPlayingView()
        .environmentObject(WatchConnectivityManager.shared)
}

