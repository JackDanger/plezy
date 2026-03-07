import SwiftUI

struct SearchView: View {
    @State private var searchText = ""
    @State private var results: [MusicItem] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @EnvironmentObject var connectivity: WatchConnectivityManager

    var body: some View {
        VStack(spacing: 0) {
            // watchOS TextField automatically offers dictation
            TextField("Search music...", text: $searchText)
                .font(.system(size: 14))
                .onSubmit { performSearch() }

            if isSearching {
                Spacer()
                ProgressView("Searching...")
                Spacer()
            } else if results.isEmpty && hasSearched {
                Spacer()
                Text("No results")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(results) { item in
                    Button(action: { handleTap(item) }) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Image(systemName: iconFor(item))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(item.title)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                            }
                            if let sub = item.subtitle {
                                Text(sub)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Search")
    }

    private func iconFor(_ item: MusicItem) -> String {
        switch item.type {
        case "artist": return "person.fill"
        case "album": return "square.stack"
        default: return "music.note"
        }
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

    private func handleTap(_ item: MusicItem) {
        Task {
            if item.isTrack {
                // Play the track directly via radio (creates endless queue from it)
                if let result = await PlexWatchClient.shared.createRadioStation(ratingKey: item.ratingKey) {
                    startPlayback(result.items)
                }
            } else if item.isAlbum {
                if let result = await PlexWatchClient.shared.createPlayAllQueue(ratingKey: item.ratingKey) {
                    startPlayback(result.items)
                }
            } else if item.isArtist {
                // For artists, start a radio station
                if let result = await PlexWatchClient.shared.createRadioStation(ratingKey: item.ratingKey) {
                    startPlayback(result.items)
                }
            }
        }
    }

    private func startPlayback(_ items: [MusicItem]) {
        let client = PlexWatchClient.shared
        let queueItems = items.compactMap { $0.toQueueItem(client: client) }
        if !queueItems.isEmpty {
            DispatchQueue.main.async {
                connectivity.isPlayingLocally = true
                connectivity.hasLocalQueue = true
                WatchAudioPlayer.shared.loadQueue(queueItems)
            }
        }
    }
}
