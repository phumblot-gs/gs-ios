import SwiftUI
import GSAPIClient
import GSCore

/// Compact pill at the top of the screen showing the backend connectivity.
/// Pings `/health` on appear and every 30 s; turns green/red/grey.
///
/// Lets us spot in 1 second whether the iOS app is reaching the right
/// backend (and whether the right `env` value comes back). Cheap to leave
/// in production builds — single GET against a Lambda, < 1 ms server time.
struct BackendStatusBanner: View {
    private let service: BackendHealthService
    private let environmentName: String

    @State private var status: Status = .pinging
    @State private var pingTask: Task<Void, Never>?

    enum Status: Equatable {
        case pinging
        case ok(env: String)
        case failed(message: String)
    }

    init(environment: GSEnvironment, environmentName: String) {
        self.service = BackendHealthService(environment: environment)
        self.environmentName = environmentName
    }

    var body: some View {
        // Healthy path stays invisible — no value in showing a
        // green "everything is fine" pill on every screen. The
        // banner only materialises on `.failed` so the user sees
        // it exactly when there's something to act on.
        Group {
            if case .failed = status {
                pill
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: status)
        .task { await loop() }
        .onDisappear { pingTask?.cancel() }
        .accessibilityHidden({ if case .ok = status { return true } else { return false } }())
        .accessibilityLabel("Backend status: \(label)")
    }

    private var pill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .monospaced()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
    }

    private var dotColor: Color {
        switch status {
        case .pinging: return .gray
        case .ok: return .green
        case .failed: return .red
        }
    }

    private var label: String {
        switch status {
        case .pinging:
            return environmentName
        case .ok(let env):
            // When the backend confirms the same env we asked for, no point
            // showing it twice — keep the badge compact. Surface the mismatch
            // explicitly when they diverge (e.g. a stale custom domain).
            return env == environmentName ? environmentName : "\(environmentName) ≠ \(env)"
        case .failed(let msg):
            return "\(environmentName) · \(msg)"
        }
    }

    private func loop() async {
        while !Task.isCancelled {
            await ping()
            try? await Task.sleep(for: .seconds(30))
        }
    }

    private func ping() async {
        do {
            let response = try await service.ping()
            status = .ok(env: response.environment)
        } catch BackendHealthService.HealthError.http(let code) {
            status = .failed(message: "HTTP \(code)")
        } catch BackendHealthService.HealthError.transport {
            status = .failed(message: "offline")
        } catch {
            status = .failed(message: "error")
        }
    }
}
