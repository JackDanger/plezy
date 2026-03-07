import Foundation

/// Lightweight Plex API client for Apple Watch
/// Handles direct communication with the Plex server for independent operation
class PlexWatchClient {
    static let shared = PlexWatchClient()

    private let session = URLSession.shared
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
        guard var creds = credentials else { return nil }
        if creds.machineIdentifier != nil { return creds.machineIdentifier }

        guard let json = await get("/identity") else { return nil }
        if let container = json["MediaContainer"] as? [String: Any],
           let machineId = container["machineIdentifier"] as? String {
            creds.machineIdentifier = machineId
            credentials = creds
            return machineId
        }
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

    /// Create a play queue from a track/album/artist URI
    func createPlayQueue(uri: String, shuffle: Bool = false, continuous: Bool = false) async -> PlayQueueResult? {
        guard let creds = credentials else { return nil }

        var params = "type=audio&uri=\(uri)"
        if shuffle { params += "&shuffle=1" }
        if continuous { params += "&continuous=1" }

        let urlString = "\(creds.serverUrl)/playQueues?\(params)&X-Plex-Token=\(creds.token)"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let container = json["MediaContainer"] as? [String: Any] else { return nil }

            let queueId = container["playQueueID"] as? Int ?? 0
            let metadata = container["Metadata"] as? [[String: Any]] ?? []
            let items = metadata.compactMap { parseMusicItem($0) }

            return PlayQueueResult(playQueueId: queueId, items: items)
        } catch {
            print("[PlexWatch] Create queue error: \(error)")
            return nil
        }
    }

    /// Create a radio station from a track/album/artist
    func createRadioStation(ratingKey: String) async -> PlayQueueResult? {
        let machineId = await fetchMachineIdentifier()
        guard let machineId else {
            print("[PlexWatch] No machine identifier for radio")
            return nil
        }

        let uri = "server://\(machineId)/com.plexapp.plugins.library/library/metadata/\(ratingKey)/station"
        guard let encoded = uri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return await createPlayQueue(uri: encoded, shuffle: true, continuous: true)
    }

    /// Create a play queue for an album or artist (play all tracks)
    func createPlayAllQueue(ratingKey: String, type: String = "audio") async -> PlayQueueResult? {
        guard let machineId = await fetchMachineIdentifier() else { return nil }
        let uri = "server://\(machineId)/com.plexapp.plugins.library/library/metadata/\(ratingKey)"
        guard let encoded = uri.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return await createPlayQueue(uri: encoded)
    }

    /// Build a stream URL for a track
    func streamUrl(partKey: String) -> String? {
        guard let creds = credentials else { return nil }
        return "\(creds.serverUrl)\(partKey)?X-Plex-Token=\(creds.token)"
    }

    /// Build a thumbnail URL
    func thumbnailUrl(_ thumb: String?) -> String? {
        guard let thumb, let creds = credentials else { return nil }
        let path = thumb.hasPrefix("/") ? String(thumb.dropFirst()) : thumb
        return "\(creds.serverUrl)/\(path)?X-Plex-Token=\(creds.token)"
    }

    // MARK: - Private

    private func get(_ path: String) async -> [String: Any]? {
        guard let creds = credentials else { return nil }
        let separator = path.contains("?") ? "&" : "?"
        let urlString = "\(creds.serverUrl)\(path)\(separator)X-Plex-Token=\(creds.token)"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
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

    var durationSeconds: Double { (duration ?? 0) / 1000.0 }

    var subtitle: String? {
        if isTrack { return artist }
        if isAlbum { return artist }
        return nil
    }

    /// Convert to a QueueItem for playback
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
}

struct PlayQueueResult {
    let playQueueId: Int
    let items: [MusicItem]
}
