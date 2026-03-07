import SwiftUI

struct IdleView: View {
    @EnvironmentObject var connectivity: WatchConnectivityManager
    
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // App icon placeholder
                Image(systemName: "play.tv")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                
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
                    .padding(.horizontal, 4)
                    
                    // Retry button
                    Button("Retry") {
                        connectivity.errorMessage = nil
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
                // Main action button - always show, but indicate if not reachable
                else {
                    Button(action: {
                        connectivity.requestPlayPhoneQueue()
                    }) {
                        VStack(spacing: 3) {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                                .font(.system(size: 18))
                            Text("Play phone queue")
                                .font(.system(size: 10, weight: .medium))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor.opacity(connectivity.isReachable ? 0.2 : 0.1))
                        )
                    }
                    .buttonStyle(.plain)
                }
                
                // Status section
                VStack(spacing: 4) {
                    // Connection indicator
                    HStack(spacing: 3) {
                        Circle()
                            .fill(connectivity.isReachable ? Color.green : Color.red)
                            .frame(width: 5, height: 5)
                        Text(connectivity.isReachable ? "Connected" : "Not connected")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(.secondary)
                    
                    // Debug info
                    Text(connectivity.debugInfo)
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 4)
        }
    }
}

#Preview {
    IdleView()
        .environmentObject(WatchConnectivityManager.shared)
}
