import SwiftUI
import WatchKit

struct SearchView: View {
    @State private var searchText = ""
    @State private var results: [MusicItem] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var errorMessage: String?
    @FocusState private var isSearchFocused: Bool
    @EnvironmentObject var connectivity: WatchConnectivityManager

    var body: some View {
        List {
            // Search field always visible at top
            Section {
                TextField("Search", text: $searchText)
                    .focused($isSearchFocused)
                    .onSubmit { performSearch() }

                if !searchText.isEmpty {
                    Button(action: { performSearch() }) {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if isSearching {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            } else if results.isEmpty && hasSearched {
                Section {
                    Text("No results found")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            } else {
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
        .navigationTitle("Search")
        .onAppear { isSearchFocused = true }
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
        errorMessage = nil
        Task {
            let client = PlexWatchClient.shared
            let (radioResult, radioError) = await client.createRadioStation(ratingKey: item.ratingKey)
            guard let result = radioResult else {
                await MainActor.run { errorMessage = "Radio: \(radioError ?? "unknown error")" }
                WKInterfaceDevice.current().play(.failure)
                return
            }
            let queueItems = result.items.compactMap { $0.toQueueItem(client: client) }
            if queueItems.isEmpty {
                await MainActor.run { errorMessage = "No playable tracks" }
                WKInterfaceDevice.current().play(.failure)
                return
            }
            let queueRef = result.toQueueReference(client: client)
            await MainActor.run {
                connectivity.startLocalPlayback()
                WatchAudioPlayer.shared.loadQueue(queueItems, queueRef: queueRef)
            }
            RecentlyPlayedManager.shared.record(
                ratingKey: item.ratingKey,
                title: item.title,
                type: .station,
                thumb: item.thumb
            )
        }
    }

}
