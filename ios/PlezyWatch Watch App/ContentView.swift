import SwiftUI

struct ContentView: View {
    @EnvironmentObject var connectivity: WatchConnectivityManager
    @StateObject private var audioPlayer = WatchAudioPlayer.shared
    
    var body: some View {
        Group {
            if connectivity.isPlayingLocally || audioPlayer.isPlaying || audioPlayer.isLoading {
                // Local playback mode - playing on watch
                LocalPlaybackView()
            } else if connectivity.isPlaying || connectivity.hasTrackInfo {
                // Remote control mode - phone is playing
                NowPlayingView()
            } else {
                // Idle state
                IdleView()
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(WatchConnectivityManager.shared)
}
