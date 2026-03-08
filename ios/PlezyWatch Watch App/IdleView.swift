import SwiftUI
import WatchKit

struct IdleView: View {
    @EnvironmentObject var connectivity: WatchConnectivityManager
    @StateObject private var audioPlayer = WatchAudioPlayer.shared
    @StateObject private var recentlyPlayed = RecentlyPlayedManager.shared
    @State private var hasCredentials = PlexWatchClient.shared.hasCredentials
    @State private var searchText = ""
    @State private var searchResults: [MusicItem] = []
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    Section {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                } else if !searchResults.isEmpty {
                    searchResultsSection
                } else {
                    // Now Playing
                    if audioPlayer.hasQueue {
                        nowPlayingSection
                    }

                    // Library
                    if hasCredentials {
                        librarySection
                        recentlyPlayedSection
                    } else if connectivity.isReachable {
                        syncingSection
                    } else {
                        setupSection
                    }

                    // Phone
                    phoneSection

                    // Status (only when no credentials — once working, hide the noise)
                    if !hasCredentials {
                        statusSection
                    }
                }
            }
            .navigationTitle("Plezy")
            .searchable(text: $searchText, prompt: "Search music")
            .onSubmit(of: .search) {
                guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                isSearching = true
                Task {
                    let items = await PlexWatchClient.shared.search(query: searchText)
                    await MainActor.run {
                        searchResults = items
                        isSearching = false
                    }
                }
            }
        }
        .onReceive(connectivity.objectWillChange) { _ in
            // Re-check credentials when connectivity state changes
            // (credentials arrive via requestCredentials reply)
            let updated = PlexWatchClient.shared.hasCredentials
            if updated != hasCredentials {
                hasCredentials = updated
            }
        }
    }

    // MARK: - Now Playing

    private var nowPlayingSection: some View {
        Section {
            Button(action: {
                WKInterfaceDevice.current().play(.click)
                connectivity.returnToPlayer()
            }) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.2))
                            .frame(width: 36, height: 36)
                        Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.body)
                            .foregroundColor(.accentColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(audioPlayer.currentItem?.title ?? "Now Playing")
                            .font(.headline)
                            .lineLimit(1)
                        if let artist = audioPlayer.currentItem?.artist {
                            Text(artist)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .listRowBackground(Color.accentColor.opacity(0.1))
        }
    }

    // MARK: - Search Results

    @ViewBuilder
    private var searchResultsSection: some View {
        let artists = searchResults.filter { $0.isArtist }
        let albums = searchResults.filter { $0.isAlbum }
        let tracks = searchResults.filter { $0.isTrack }

        if !artists.isEmpty {
            Section("Artists") {
                ForEach(artists) { item in
                    NavigationLink(destination: ArtistDetailView(artist: item)) {
                        HStack(spacing: 10) {
                            CachedThumbnailView(
                                urlString: PlexWatchClient.shared.thumbnailUrl(item.thumb),
                                size: 36
                            ).clipShape(Circle())
                            Text(item.title).font(.body).lineLimit(1)
                        }
                    }
                }
            }
        }
        if !albums.isEmpty {
            Section("Albums") {
                ForEach(albums) { item in
                    NavigationLink(destination: TrackListView(albumKey: item.ratingKey, albumTitle: item.title)) {
                        HStack(spacing: 10) {
                            CachedThumbnailView(
                                urlString: PlexWatchClient.shared.thumbnailUrl(item.thumb),
                                size: 36
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.body).lineLimit(1)
                                if let artist = item.artist {
                                    Text(artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        }
        if !tracks.isEmpty {
            Section("Songs") {
                ForEach(tracks) { item in
                    Button(action: { playTrackRadio(item) }) {
                        HStack(spacing: 10) {
                            CachedThumbnailView(
                                urlString: PlexWatchClient.shared.thumbnailUrl(item.thumb),
                                size: 36
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.body).lineLimit(1)
                                if let artist = item.artist {
                                    Text(artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Library

    private var librarySection: some View {
        Section {
            NavigationLink(destination: LibraryBrowserView()) {
                Label("Library", systemImage: "music.note.list")
            }
            NavigationLink(destination: DebugView()) {
                Label("Debug", systemImage: "ant")
                    .font(.caption2)
            }
            Text("Build: \(BuildInfo.stamp)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .listRowBackground(Color.clear)
        }
    }

    // MARK: - Recently Played

    @ViewBuilder
    private var recentlyPlayedSection: some View {
        if !recentlyPlayed.items.isEmpty {
            Section("Recently Played") {
                ForEach(recentlyPlayed.items.prefix(5)) { item in
                    Button(action: { replayItem(item) }) {
                        HStack(spacing: 10) {
                            CachedThumbnailView(
                                urlString: PlexWatchClient.shared.thumbnailUrl(item.thumb),
                                size: 40
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.body)
                                    .lineLimit(1)
                                Text(item.type.rawValue.capitalized)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Phone

    private var phoneSection: some View {
        Section {
            if connectivity.isReachable {
                Button(action: { connectivity.requestPlayPhoneQueue() }) {
                    Label("Phone Queue", systemImage: "iphone.radiowaves.left.and.right")
                }
            }
        }
    }

    // MARK: - Syncing / Setup states

    private var syncingSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connecting to server...")
                        .font(.body)
                    Text("Getting credentials from phone")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .onAppear {
                connectivity.requestCredentials()
            }
        }
    }

    private var setupSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Open Plezy on iPhone", systemImage: "iphone")
                    .font(.body)
                Text("Or set up manually:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            NavigationLink(destination: SetupView()) {
                Label("Manual Setup", systemImage: "gear")
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            HStack(spacing: 4) {
                Circle()
                    .fill(connectivity.isReachable ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text(connectivity.isReachable ? "Phone connected" : "Phone not connected")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .listRowBackground(Color.clear)
            Text("Build: \(BuildInfo.stamp)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .listRowBackground(Color.clear)
        }
    }

    // MARK: - Actions

    private func playTrackRadio(_ item: MusicItem) {
        WKInterfaceDevice.current().play(.click)
        Task {
            let client = PlexWatchClient.shared
            let (radioResult, _) = await client.createRadioStation(ratingKey: item.ratingKey)
            guard let result = radioResult else {
                WKInterfaceDevice.current().play(.failure)
                return
            }
            let queueItems = await result.toQueueItems(client: client)
            guard !queueItems.isEmpty else {
                WKInterfaceDevice.current().play(.failure)
                return
            }
            let queueRef = result.toQueueReference(client: client)
            await MainActor.run {
                connectivity.startLocalPlayback()
                WatchAudioPlayer.shared.loadQueue(queueItems, queueRef: queueRef)
                searchText = ""
                searchResults = []
            }
            RecentlyPlayedManager.shared.record(
                ratingKey: item.ratingKey,
                title: item.title,
                type: .station,
                thumb: item.thumb
            )
        }
    }

    private func replayItem(_ item: RecentlyPlayedManager.RecentItem) {
        WKInterfaceDevice.current().play(.click)
        Task {
            let client = PlexWatchClient.shared
            var result: PlayQueueResult?

            switch item.type {
            case .album, .artist:
                result = await client.createPlayAllQueue(ratingKey: item.ratingKey)
            case .station:
                let (radioResult, _) = await client.createRadioStation(ratingKey: item.ratingKey)
                result = radioResult
            }

            guard let result = result else {
                WKInterfaceDevice.current().play(.failure)
                return
            }

            let queueItems = await result.toQueueItems(client: client)
            if !queueItems.isEmpty {
                // For radio stations, store the queue ref so we can fetch more tracks
                let queueRef = (item.type == .station) ? result.toQueueReference(client: client) : nil
                await MainActor.run {
                    connectivity.startLocalPlayback()
                    WatchAudioPlayer.shared.loadQueue(queueItems, queueRef: queueRef)
                }
            } else {
                WKInterfaceDevice.current().play(.failure)
            }
        }
    }
}

/// Small cached thumbnail view used in browse lists and recently played
struct CachedThumbnailView: View {
    let urlString: String?
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.4))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 36 ? 6 : 4))
        .onAppear { loadImage() }
        .onChange(of: urlString) { _, _ in loadImage() }
    }

    private func loadImage() {
        guard let urlString = urlString else { return }
        let token = PlexWatchClient.shared.credentials?.token
        WatchImageCache.shared.loadImage(urlString: urlString, token: token) { loaded in
            self.image = loaded
        }
    }
}

#Preview {
    IdleView()
        .environmentObject(WatchConnectivityManager.shared)
}
