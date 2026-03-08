import SwiftUI
import WatchKit

struct SearchView: View {
    @State private var searchText = ""
    @State private var results: [MusicItem] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @EnvironmentObject var connectivity: WatchConnectivityManager

    var body: some View {
        List {
            if isSearching {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if results.isEmpty && hasSearched {
                Text("No results")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            } else {
                // Group results by type
                let artists = results.filter { $0.isArtist }
                let albums = results.filter { $0.isAlbum }
                let tracks = results.filter { $0.isTrack }

                if !artists.isEmpty {
                    Section("Artists") {
                        ForEach(artists) { item in
                            NavigationLink(destination: ArtistDetailView(artist: item)) {
                                HStack(spacing: 10) {
                                    CachedThumbnailView(
                                        urlString: PlexWatchClient.shared.thumbnailUrl(item.thumb),
                                        size: 36
                                    )
                                    .clipShape(Circle())
                                    Text(item.title)
                                        .font(.body)
                                        .lineLimit(1)
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
                                        Text(item.title)
                                            .font(.body)
                                            .lineLimit(1)
                                        if let artist = item.artist {
                                            Text(artist)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
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
                            Button(action: { handleTrackTap(item) }) {
                                HStack(spacing: 10) {
                                    CachedThumbnailView(
                                        urlString: PlexWatchClient.shared.thumbnailUrl(item.thumb),
                                        size: 36
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                            .font(.body)
                                            .lineLimit(1)
                                        if let artist = item.artist {
                                            Text(artist)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Artists, albums, songs")
        .onSubmit(of: .search) { performSearch() }
        .navigationTitle("Search")
    }

    private func performSearch() {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        hasSearched = true
        Task {
            let items = await PlexWatchClient.shared.search(query: searchText)
            await MainActor.run {
                results = items
                isSearching = false
            }
        }
    }

    private func handleTrackTap(_ item: MusicItem) {
        WKInterfaceDevice.current().play(.click)
        Task {
            if let result = await PlexWatchClient.shared.createRadioStation(ratingKey: item.ratingKey) {
                startPlayback(result.items)
                RecentlyPlayedManager.shared.record(
                    ratingKey: item.ratingKey,
                    title: item.title,
                    type: .station,
                    thumb: item.thumb
                )
            }
        }
    }

    private func startPlayback(_ items: [MusicItem]) {
        let client = PlexWatchClient.shared
        let queueItems = items.compactMap { $0.toQueueItem(client: client) }
        if !queueItems.isEmpty {
            DispatchQueue.main.async {
                connectivity.startLocalPlayback()
                WatchAudioPlayer.shared.loadQueue(queueItems)
            }
        }
    }
}
