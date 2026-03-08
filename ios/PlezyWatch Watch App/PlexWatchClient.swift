import Foundation

/// Lightweight Plex API client for Apple Watch
/// Handles direct communication with the Plex server for independent operation
class PlexWatchClient {
    static let shared = PlexWatchClient()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()
    private let credentialsKey = "plexServerCredentials"

    struct Credentials: Codable {
        let serverUrl: String
        let token: String
        var machineIdentifier: String?
    }

    /// Stored server credentials for independent operation
    var credentials: Credentials? {
        get {
            guard let data = UserDefaults.standard.data(forKey: credentialsKey) else { return nil }
            return try? JSONDecoder().decode(Credentials.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: credentialsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: credentialsKey)
            }
        }
    }

    var hasCredentials: Bool { credentials != nil }

    /// Save credentials from a queue transfer
    func saveCredentials(serverUrl: String, token: String) {
        credentials = Credentials(serverUrl: serverUrl, token: token)
        // Fetch machine identifier in the background
        Task { await fetchMachineIdentifier() }
    }

    // MARK: - API Methods

    /// Fetch and cache the server's machine identifier (needed for radio stations)
    @discardableResult
    func fetchMachineIdentifier() async -> String? {
        guard var creds = credentials else {
            print("[PlexWatch] fetchMachineIdentifier: no credentials")
            return nil
        }
        if let cached = creds.machineIdentifier {
            print("[PlexWatch] fetchMachineIdentifier: using cached \(cached)")
            return cached
        }

        print("[PlexWatch] fetchMachineIdentifier: fetching from \(creds.serverUrl)/identity")
        guard let json = await get("/identity") else {
            print("[PlexWatch] fetchMachineIdentifier: /identity request failed")
            return nil
        }
        if let container = json["MediaContainer"] as? [String: Any],
           let machineId = container["machineIdentifier"] as? String {
            creds.machineIdentifier = machineId
            credentials = creds
            print("[PlexWatch] fetchMachineIdentifier: got \(machineId)")
            return machineId
        }
        print("[PlexWatch] fetchMachineIdentifier: unexpected response: \(json)")
        return nil
    }

    /// Get all libraries
    func getLibraries() async -> [LibrarySection] {
        guard let json = await get("/library/sections") else { return [] }
        guard let container = json["MediaContainer"] as? [String: Any],
              let directories = container["Directory"] as? [[String: Any]] else { return [] }

        return directories.compactMap { dir in
            guard let key = dir["key"] as? String,
                  let title = dir["title"] as? String,
                  let type = dir["type"] as? String else { return nil }
            return LibrarySection(key: key, title: title, type: type)
        }
    }

    /// Get music libraries only
    func getMusicLibraries() async -> [LibrarySection] {
        await getLibraries().filter { $0.type == "artist" }
    }

    /// Get artists in a music library
    func getArtists(sectionId: String) async -> [MusicItem] {
        await getMetadataList("/library/sections/\(sectionId)/all?type=8")
    }

    /// Get albums for an artist
    func getAlbums(ratingKey: String) async -> [MusicItem] {
        await getMetadataList("/library/metadata/\(ratingKey)/children")
    }

    /// Get tracks for an album
    func getTracks(ratingKey: String) async -> [MusicItem] {
        await getMetadataList("/library/metadata/\(ratingKey)/children")
    }

    /// Get all albums in a music library
    func getAllAlbums(sectionId: String) async -> [MusicItem] {
        await getMetadataList("/library/sections/\(sectionId)/all?type=9&sort=titleSort")
    }

    /// Get playlists (audio only)
    func getPlaylists() async -> [MusicItem] {
        guard let json = await get("/playlists?playlistType=audio") else { return [] }
        guard let container = json["MediaContainer"] as? [String: Any],
              let metadata = container["Metadata"] as? [[String: Any]] else { return [] }

        return metadata.compactMap { dict -> MusicItem? in
            guard let ratingKey = dict["ratingKey"] as? String,
                  let title = dict["title"] as? String else { return nil }
            let duration = dict["duration"] as? Double
            let thumb = dict["composite"] as? String ?? dict["thumb"] as? String
            let leafCount = dict["leafCount"] as? Int
            return MusicItem(
                ratingKey: ratingKey,
                title: title,
                type: "playlist",
                artist: leafCount != nil ? "\(leafCount!) tracks" : nil,
                album: nil,
                thumb: thumb,
                duration: duration,
                partKey: nil
            )
        }
    }

    /// Get tracks in a playlist
    func getPlaylistItems(ratingKey: String) async -> [MusicItem] {
        await getMetadataList("/playlists/\(ratingKey)/items")
    }

    /// Create a play queue from a playlist
    func createPlaylistQueue(ratingKey: String, shuffle: Bool = false) async -> PlayQueueResult? {
        guard let creds = credentials else { return nil }

        var params = "type=audio&playlistID=\(ratingKey)"
        if shuffle { params += "&shuffle=1" }

        let urlString = "\(creds.serverUrl)/playQueues?\(params)&X-Plex-Token=\(creds.token)"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("Plezy", forHTTPHeaderField: "X-Plex-Product")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let container = json["MediaContainer"] as? [String: Any] else { return nil }

            let queueId = container["playQueueID"] as? Int ?? 0
            let metadata = container["Metadata"] as? [[String: Any]] ?? []
            let items = metadata.compactMap { parseMusicItem($0) }
            print("[PlexWatch] Created playlist queue \(queueId) with \(items.count) items")

            return PlayQueueResult(playQueueId: queueId, items: items)
        } catch {
            print("[PlexWatch] Create playlist queue error: \(error)")
            return nil
        }
    }

    /// Search across all content
    func search(query: String) async -> [MusicItem] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let json = await get("/hubs/search?query=\(encoded)&limit=20") else { return [] }
        guard let container = json["MediaContainer"] as? [String: Any],
              let hubs = container["Hub"] as? [[String: Any]] else { return [] }

        var results: [MusicItem] = []
        for hub in hubs {
            guard let metadata = hub["Metadata"] as? [[String: Any]] else { continue }
            let items = metadata.compactMap { parseMusicItem($0) }
            results.append(contentsOf: items)
        }
        return results
    }

    /// Plex client identifier for API requests
    var clientIdentifier: String {
        if let stored = UserDefaults.standard.string(forKey: "plexClientId") {
            return stored
        }
        let id = "plezy-watch-\(UUID().uuidString.prefix(8))"
        UserDefaults.standard.set(id, forKey: "plexClientId")
        return id
    }

    /// Create a play queue from a track/album/artist URI
    func createPlayQueue(uri: String, shuffle: Bool = false, continuous: Bool = false) async -> PlayQueueResult? {
        guard let creds = credentials else {
            print("[PlexWatch] No credentials for createPlayQueue")
            return nil
        }

        var components = URLComponents(string: "\(creds.serverUrl)/playQueues")
        var queryItems = [
            URLQueryItem(name: "type", value: "audio"),
            URLQueryItem(name: "uri", value: uri),
            URLQueryItem(name: "X-Plex-Token", value: creds.token),
        ]
        if shuffle { queryItems.append(URLQueryItem(name: "shuffle", value: "1")) }
        if continuous { queryItems.append(URLQueryItem(name: "continuous", value: "1")) }
        components?.queryItems = queryItems

        guard let url = components?.url else {
            print("[PlexWatch] Failed to build play queue URL from: \(creds.serverUrl)/playQueues")
            return nil
        }

        print("[PlexWatch] POST \(url)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("Plezy", forHTTPHeaderField: "X-Plex-Product")
        request.setValue("Watch", forHTTPHeaderField: "X-Plex-Device")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("[PlexWatch] Create queue HTTP \(http.statusCode): \(body.prefix(200))")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let container = json["MediaContainer"] as? [String: Any] else {
                print("[PlexWatch] Create queue: unexpected JSON structure")
                return nil
            }

            let queueId = container["playQueueID"] as? Int ?? 0
            let metadata = container["Metadata"] as? [[String: Any]] ?? []
            let items = metadata.compactMap { parseMusicItem($0) }
            print("[PlexWatch] Created queue \(queueId) with \(items.count) items (keys: \(Array(container.keys)))")

            return PlayQueueResult(playQueueId: queueId, items: items)
        } catch {
            print("[PlexWatch] Create queue error: \(error)")
            return nil
        }
    }

    /// Create a radio station from a track/album/artist
    /// Returns (result, errorDetail) — errorDetail is non-nil on failure for UI display
    func createRadioStation(ratingKey: String) async -> (PlayQueueResult?, String?) {
        print("[PlexWatch] createRadioStation: ratingKey=\(ratingKey), hasCredentials=\(hasCredentials)")

        guard hasCredentials else {
            return (nil, "No credentials")
        }

        let machineId = await fetchMachineIdentifier()
        guard let machineId else {
            return (nil, "Can't reach server (/identity failed)")
        }

        let uri = "server://\(machineId)/com.plexapp.plugins.library/library/metadata/\(ratingKey)/station"
        print("[PlexWatch] createRadioStation: uri=\(uri)")
        let result = await createPlayQueue(uri: uri, shuffle: true, continuous: true)
        if let result {
            print("[PlexWatch] createRadioStation: \(result.items.count) items, queueId=\(result.playQueueId)")
            return (result, nil)
        } else {
            return (nil, "Server rejected radio request")
        }
    }

    /// Create a play queue for an album or artist (play all tracks)
    func createPlayAllQueue(ratingKey: String, type: String = "audio") async -> PlayQueueResult? {
        guard let machineId = await fetchMachineIdentifier() else {
            print("[PlexWatch] No machine identifier for play all")
            return nil
        }
        let uri = "server://\(machineId)/com.plexapp.plugins.library/library/metadata/\(ratingKey)"
        print("[PlexWatch] Creating play all queue with uri: \(uri)")
        return await createPlayQueue(uri: uri)
    }

    /// Build a stream URL for a track using its part key (direct file access)
    func streamUrl(partKey: String) -> String? {
        guard let creds = credentials else { return nil }
        return "\(creds.serverUrl)\(partKey)?X-Plex-Token=\(creds.token)"
    }

    /// Fetch the partKey for a track by loading its full metadata
    /// Used when Media/Part data is not available (e.g. radio station responses)
    func fetchPartKey(ratingKey: String) async -> String? {
        guard let json = await get("/library/metadata/\(ratingKey)") else {
            print("[PlexWatch] fetchPartKey(\(ratingKey)): request failed")
            return nil
        }
        guard let container = json["MediaContainer"] as? [String: Any],
              let metadata = container["Metadata"] as? [[String: Any]],
              let track = metadata.first,
              let media = (track["Media"] as? [[String: Any]])?.first,
              let part = (media["Part"] as? [[String: Any]])?.first,
              let partKey = part["key"] as? String else {
            print("[PlexWatch] fetchPartKey(\(ratingKey)): no partKey in response")
            return nil
        }
        return partKey
    }

    /// Build a thumbnail URL
    func thumbnailUrl(_ thumb: String?) -> String? {
        guard let thumb, let creds = credentials else { return nil }
        let path = thumb.hasPrefix("/") ? String(thumb.dropFirst()) : thumb
        return "\(creds.serverUrl)/\(path)?X-Plex-Token=\(creds.token)"
    }

    // MARK: - Private

    private func get(_ path: String) async -> [String: Any]? {
        guard let creds = credentials else {
            print("[PlexWatch] GET \(path): no credentials")
            return nil
        }
        let separator = path.contains("?") ? "&" : "?"
        let urlString = "\(creds.serverUrl)\(path)\(separator)X-Plex-Token=\(creds.token)"
        guard let url = URL(string: urlString) else {
            print("[PlexWatch] GET \(path): invalid URL")
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                print("[PlexWatch] GET \(path): no HTTP response")
                return nil
            }
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("[PlexWatch] GET \(path): HTTP \(http.statusCode) \(body.prefix(200))")
                if http.statusCode == 401 {
                    print("[PlexWatch] Token expired or invalid — clearing credentials")
                    DispatchQueue.main.async { self.credentials = nil }
                }
                return nil
            }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            print("[PlexWatch] GET \(path) error: \(error)")
            return nil
        }
    }

    private func getMetadataList(_ path: String) async -> [MusicItem] {
        guard let json = await get(path) else { return [] }
        guard let container = json["MediaContainer"] as? [String: Any],
              let metadata = container["Metadata"] as? [[String: Any]] else { return [] }
        return metadata.compactMap { parseMusicItem($0) }
    }

    private func parseMusicItem(_ dict: [String: Any]) -> MusicItem? {
        guard let ratingKey = dict["ratingKey"] as? String,
              let title = dict["title"] as? String else { return nil }

        let type = dict["type"] as? String ?? "track"

        // Extract stream info for tracks
        var partKey: String?
        if let media = (dict["Media"] as? [[String: Any]])?.first,
           let part = (media["Part"] as? [[String: Any]])?.first {
            partKey = part["key"] as? String
        }

        return MusicItem(
            ratingKey: ratingKey,
            title: title,
            type: type,
            artist: dict["grandparentTitle"] as? String ?? dict["parentTitle"] as? String,
            album: dict["parentTitle"] as? String,
            thumb: dict["thumb"] as? String ?? dict["parentThumb"] as? String,
            duration: dict["duration"] as? Double,
            partKey: partKey
        )
    }
}

// MARK: - Models

struct LibrarySection: Identifiable {
    let key: String
    let title: String
    let type: String
    var id: String { key }
}

struct MusicItem: Identifiable {
    let ratingKey: String
    let title: String
    let type: String  // artist, album, track
    let artist: String?
    let album: String?
    let thumb: String?
    let duration: Double?  // milliseconds
    let partKey: String?

    var id: String { ratingKey }

    var isArtist: Bool { type == "artist" }
    var isAlbum: Bool { type == "album" }
    var isTrack: Bool { type == "track" }
    var isPlaylist: Bool { type == "playlist" }

    var durationSeconds: Double { (duration ?? 0) / 1000.0 }

    var subtitle: String? {
        if isTrack { return artist }
        if isAlbum { return artist }
        return nil
    }

    /// Convert to a QueueItem for playback (sync — requires partKey to already be present)
    func toQueueItem(client: PlexWatchClient) -> QueueItem? {
        guard let partKey, let streamUrl = client.streamUrl(partKey: partKey) else { return nil }
        guard let token = client.credentials?.token else { return nil }
        return QueueItem(from: [
            "id": ratingKey,
            "title": title,
            "artist": artist as Any,
            "albumArtUrl": client.thumbnailUrl(thumb) as Any,
            "streamUrl": streamUrl,
            "plexToken": token,
            "duration": durationSeconds,
        ])
    }

    /// Convert to a QueueItem, fetching partKey from server if missing
    func toQueueItemAsync(client: PlexWatchClient) async -> QueueItem? {
        // If we already have a partKey, use it directly
        if let result = toQueueItem(client: client) {
            return result
        }
        // Fetch full metadata to get the partKey
        guard let fetchedPartKey = await client.fetchPartKey(ratingKey: ratingKey) else { return nil }
        guard let streamUrl = client.streamUrl(partKey: fetchedPartKey) else { return nil }
        guard let token = client.credentials?.token else { return nil }
        return QueueItem(from: [
            "id": ratingKey,
            "title": title,
            "artist": artist as Any,
            "albumArtUrl": client.thumbnailUrl(thumb) as Any,
            "streamUrl": streamUrl,
            "plexToken": token,
            "duration": durationSeconds,
        ])
    }
}

struct PlayQueueResult {
    let playQueueId: Int
    let items: [MusicItem]

    /// Convert all items to QueueItems, fetching partKeys as needed
    func toQueueItems(client: PlexWatchClient) async -> [QueueItem] {
        var queueItems: [QueueItem] = []
        for item in items {
            if let qi = await item.toQueueItemAsync(client: client) {
                queueItems.append(qi)
            }
        }
        return queueItems
    }

    /// Build a PlayQueueReference from this result for queue refreshing
    func toQueueReference(client: PlexWatchClient) -> PlayQueueReference? {
        guard let creds = client.credentials else { return nil }
        return PlayQueueReference(
            playQueueId: playQueueId,
            plexServerUrl: creds.serverUrl,
            plexToken: creds.token,
            currentIndex: 0
        )
    }
}
