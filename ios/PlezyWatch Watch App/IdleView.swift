import SwiftUI

struct IdleView: View {
    @EnvironmentObject var connectivity: WatchConnectivityManager
    private var hasCredentials: Bool { PlexWatchClient.shared.hasCredentials }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    // Loading state
                    if connectivity.isLoading {
                        VStack(spacing: 4) {
                            ProgressView()
                            Text("Loading...")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    // Error state
                    else if let error = connectivity.errorMessage {
                        VStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 16))
                                .foregroundStyle(.orange)
                            Text(error)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        Button("Retry") { connectivity.errorMessage = nil }
                            .font(.system(size: 10))
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                    }

                    // Browse library (only if we have credentials)
                    if hasCredentials {
                        NavigationLink(destination: LibraryBrowserView()) {
                            HStack {
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 16))
                                Text("Browse Library")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.2)))
                        }
                        .buttonStyle(.plain)

                        NavigationLink(destination: SearchView()) {
                            HStack {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 16))
                                Text("Search")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.purple.opacity(0.2)))
                        }
                        .buttonStyle(.plain)
                    }

                    // Phone queue transfer
                    Button(action: { connectivity.requestPlayPhoneQueue() }) {
                        HStack {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                                .font(.system(size: 16))
                            Text("Phone Queue")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(connectivity.isReachable ? 0.2 : 0.1)))
                    }
                    .buttonStyle(.plain)

                    // Status
                    HStack(spacing: 3) {
                        Circle()
                            .fill(connectivity.isReachable ? Color.green : Color.red)
                            .frame(width: 5, height: 5)
                        Text(connectivity.isReachable ? "Connected" : "Not connected")
                            .font(.system(size: 8))
                        if hasCredentials {
                            Text("· Server saved")
                                .font(.system(size: 8))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
                .padding(.horizontal, 6)
            }
            .navigationTitle("Plezy")
        }
    }
}

#Preview {
    IdleView()
        .environmentObject(WatchConnectivityManager.shared)
}
