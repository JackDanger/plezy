import SwiftUI

struct LibraryBrowserView: View {
    @State private var libraries: [LibrarySection] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading...")
            } else if libraries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.house")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("No music libraries")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                List(libraries) { library in
                    NavigationLink(destination: ArtistListView(sectionId: library.key, libraryTitle: library.title)) {
                        Label(library.title, systemImage: "music.note.list")
                            .font(.system(size: 14))
                    }
                }
            }
        }
        .navigationTitle("Libraries")
        .task {
            libraries = await PlexWatchClient.shared.getMusicLibraries()
            isLoading = false
        }
    }
}

struct ArtistListView: View {
    let sectionId: String
    let libraryTitle: String
    @State private var artists: [MusicItem] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading...")
            } else {
                List(artists) { artist in
                    NavigationLink(destination: AlbumListView(artistKey: artist.ratingKey, artistName: artist.title)) {
                        Text(artist.title)
                            .font(.system(size: 13))
                            .lineLimit(2)
                    }
                }
            }
        }
        .navigationTitle(libraryTitle)
        .task {
            artists = await PlexWatchClient.shared.getArtists(sectionId: sectionId)
            isLoading = false
        }
    }
}

struct AlbumListView: View {
    let artistKey: String
    let artistName: String
    @State private var albums: [MusicItem] = []
    @State private var isLoading = true
    @EnvironmentObject var connectivity: WatchConnectivityManager

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading...")
            } else {
                List {
                    // Play all / Radio buttons
                    Button(action: { playAll() }) {
                        Label("Play All", systemImage: "play.fill")
                    }
                    Button(action: { startRadio() }) {
                        Label("Artist Radio", systemImage: "antenna.radiowaves.left.and.right")
                    }

                    ForEach(albums) { album in
                        NavigationLink(destination: TrackListView(albumKey: album.ratingKey, albumTitle: album.title)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.title)
                                    .font(.system(size: 13))
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(artistName)
        .task {
            albums = await PlexWatchClient.shared.getAlbums(ratingKey: artistKey)
            isLoading = false
        }
    }

    private func playAll() {
        Task {
            if let result = await PlexWatchClient.shared.createPlayAllQueue(ratingKey: artistKey) {
                let client = PlexWatchClient.shared
                let queueItems = result.items.compactMap { $0.toQueueItem(client: client) }
                if !queueItems.isEmpty {
                    await MainActor.run {
                        connectivity.isPlayingLocally = true
                        connectivity.hasLocalQueue = true
                        WatchAudioPlayer.shared.loadQueue(queueItems)
                    }
                }
            }
        }
    }

    private func startRadio() {
        Task {
            if let result = await PlexWatchClient.shared.createRadioStation(ratingKey: artistKey) {
                let client = PlexWatchClient.shared
                let queueItems = result.items.compactMap { $0.toQueueItem(client: client) }
                if !queueItems.isEmpty {
                    await MainActor.run {
                        connectivity.isPlayingLocally = true
                        connectivity.hasLocalQueue = true
                        WatchAudioPlayer.shared.loadQueue(queueItems)
                    }
                }
            }
        }
    }
}

struct TrackListView: View {
    let albumKey: String
    let albumTitle: String
    @State private var tracks: [MusicItem] = []
    @State private var isLoading = true
    @EnvironmentObject var connectivity: WatchConnectivityManager

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading...")
            } else {
                List {
                    Button(action: { playAlbum() }) {
                        Label("Play Album", systemImage: "play.fill")
                    }

                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        Button(action: { playFrom(index: index) }) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.system(size: 13))
                                    .lineLimit(2)
                                if let artist = track.artist {
                                    Text(artist)
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
        }
        .navigationTitle(albumTitle)
        .task {
            tracks = await PlexWatchClient.shared.getTracks(ratingKey: albumKey)
            isLoading = false
        }
    }

    private func playAlbum() {
        Task {
            if let result = await PlexWatchClient.shared.createPlayAllQueue(ratingKey: albumKey) {
                startPlayback(result.items)
            }
        }
    }

    private func playFrom(index: Int) {
        Task {
            if let result = await PlexWatchClient.shared.createPlayAllQueue(ratingKey: albumKey) {
                startPlayback(result.items, startIndex: index)
            }
        }
    }

    private func startPlayback(_ items: [MusicItem], startIndex: Int = 0) {
        let client = PlexWatchClient.shared
        let queueItems = items.compactMap { $0.toQueueItem(client: client) }
        if !queueItems.isEmpty {
            DispatchQueue.main.async {
                connectivity.isPlayingLocally = true
                connectivity.hasLocalQueue = true
                WatchAudioPlayer.shared.loadQueue(queueItems, startIndex: min(startIndex, queueItems.count - 1))
            }
        }
    }
}
