import SwiftUI

/// Debug view for diagnosing playback and API issues on-device
struct DebugView: View {
    @State private var logs: [String] = []
    @State private var isRunning = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(logs.enumerated()), id: \.offset) { _, log in
                    Text(log)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(log.contains("ERR") || log.contains("FAIL") ? .red :
                                        log.contains("OK") ? .green : .primary)
                }

                if isRunning {
                    ProgressView()
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Debug")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Run") { runDiagnostics() }
                    .disabled(isRunning)
            }
        }
        .onAppear { runDiagnostics() }
    }

    private func log(_ msg: String) {
        logs.append(msg)
    }

    private func runDiagnostics() {
        logs = []
        isRunning = true

        Task {
            let client = PlexWatchClient.shared

            // 1. Check credentials
            await MainActor.run {
                if let creds = client.credentials {
                    log("OK creds: \(creds.serverUrl)")
                    log("   token: \(creds.token.prefix(8))...")
                    log("   machineId: \(creds.machineIdentifier ?? "none")")
                } else {
                    log("ERR no credentials stored")
                }
                log("   clientId: \(client.clientIdentifier)")
            }

            // 2. Test server connectivity
            log("--- Testing server ---")
            let libs = await client.getLibraries()
            await MainActor.run {
                if libs.isEmpty {
                    log("ERR getLibraries returned empty")
                } else {
                    log("OK \(libs.count) libraries")
                    for lib in libs {
                        log("   \(lib.title) (\(lib.type), key=\(lib.key))")
                    }
                }
            }

            // 3. Test machine identifier
            let machineId = await client.fetchMachineIdentifier()
            await MainActor.run {
                if let mid = machineId {
                    log("OK machineId: \(mid)")
                } else {
                    log("ERR fetchMachineIdentifier failed")
                }
            }

            // 4. Find a music library and test artist browsing
            let musicLibs = await client.getMusicLibraries()
            guard let musicLib = musicLibs.first else {
                await MainActor.run {
                    log("ERR no music libraries found")
                    isRunning = false
                }
                return
            }

            await MainActor.run { log("--- Music lib: \(musicLib.title) ---") }

            let artists = await client.getArtists(sectionId: musicLib.key)
            guard let artist = artists.first else {
                await MainActor.run {
                    log("ERR no artists in library")
                    isRunning = false
                }
                return
            }

            await MainActor.run {
                log("OK \(artists.count) artists, first: \(artist.title)")
            }

            // 5. Test radio station creation
            await MainActor.run { log("--- Radio test: \(artist.title) ---") }
            let (radioResult, radioError) = await client.createRadioStation(ratingKey: artist.ratingKey)

            await MainActor.run {
                if let result = radioResult {
                    log("OK radio queue: \(result.playQueueId)")
                    log("   \(result.items.count) items from API")
                    for (i, item) in result.items.prefix(3).enumerated() {
                        log("   [\(i)] \(item.title)")
                        log("      ratingKey=\(item.ratingKey)")
                        log("      partKey=\(item.partKey ?? "nil")")
                        log("      type=\(item.type)")
                    }

                    // 6. Test toQueueItem conversion
                    let queueItems = result.toQueueItems(client: client)
                    log("   \(queueItems.count) converted to QueueItem")
                    if let first = queueItems.first {
                        log("   streamUrl: \(first.streamUrl.prefix(80))...")
                    }
                    if queueItems.isEmpty && !result.items.isEmpty {
                        log("ERR toQueueItems returned 0!")
                        log("   streamUrl test: \(client.streamUrl(ratingKey: artist.ratingKey) ?? "nil")")
                    }
                } else {
                    log("FAIL radio: \(radioError ?? "unknown")")
                }
            }

            // 7. Test album playback path
            let albums = await client.getAlbums(ratingKey: artist.ratingKey)
            if let album = albums.first {
                await MainActor.run { log("--- Album test: \(album.title) ---") }

                let albumResult = await client.createPlayAllQueue(ratingKey: album.ratingKey)
                await MainActor.run {
                    if let result = albumResult {
                        log("OK album queue: \(result.playQueueId)")
                        log("   \(result.items.count) items")
                        let queueItems = result.toQueueItems(client: client)
                        log("   \(queueItems.count) converted")
                        if let first = queueItems.first {
                            log("   url: \(first.streamUrl.prefix(80))...")
                        }
                    } else {
                        log("FAIL createPlayAllQueue")
                    }
                }
            }

            // 8. Test audio session
            await MainActor.run {
                log("--- Audio session ---")
                let session = AVAudioSession.sharedInstance()
                log("   category: \(session.category.rawValue)")
                log("   mode: \(session.mode.rawValue)")
                log("   isOtherPlaying: \(session.isOtherAudioPlaying)")

                let player = WatchAudioPlayer.shared
                log("--- Player state ---")
                log("   queue: \(player.queue.count) items")
                log("   isPlaying: \(player.isPlaying)")
                log("   isLoading: \(player.isLoading)")
                log("   error: \(player.error ?? "none")")
                if let item = player.currentItem {
                    log("   current: \(item.title)")
                    log("   url: \(item.streamUrl.prefix(60))...")
                }

                isRunning = false
            }
        }
    }
}

import AVFoundation
