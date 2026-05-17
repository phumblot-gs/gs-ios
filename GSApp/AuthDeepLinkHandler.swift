import Foundation
import GSCore

/// Parses `gsmobile://auth/done?session_id=...` callbacks coming back from
/// `ASWebAuthenticationSession`. The iOS app does NOT speak OAuth directly —
/// the backend at `api.mobile.grand-shooting.com` performs the Authorization
/// Code dance (it holds the `client_secret`) and redirects here with a
/// short-lived session id we can exchange for an access token.
enum AuthDeepLinkHandler {
    private static let logger = GSLogger(category: "App.Auth")

    static func handle(_ url: URL) {
        guard url.scheme == "gsmobile" else { return }
        guard url.host == "auth" else { return }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let sessionID = components?.queryItems?.first(where: { $0.name == "session_id" })?.value

        if let sessionID {
            logger.info("Received OAuth callback with session_id=\(sessionID)")
            // TODO: exchange session_id with backend for an access token,
            //       then `await api.setAccessToken(token)`.
        } else {
            logger.warning("OAuth callback missing session_id: \(url.absoluteString)")
        }
    }
}
