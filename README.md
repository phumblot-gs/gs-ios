# gs-ios — Grand Shooting iOS

Native iOS app for Grand Shooting (B2B photo / logistics SaaS).
Barcode scanning, photo capture, LiDAR measurements, and AI packshot generation.

- Platform: iOS 26+
- Swift: 6.0, strict concurrency, language mode 6
- UI: SwiftUI only (UIKit only when wrapping `UIViewControllerRepresentable`)
- Hardware: iPhone 15 Pro / 16 Pro / 17 Pro (LiDAR + 48 MP main camera)

## Architecture

The app is composed of seven local Swift packages under `Packages/`:

| Package        | Purpose                                                        | Dependencies          |
| -------------- | -------------------------------------------------------------- | --------------------- |
| `GSCore`       | Domain models, logging, environment config                     | —                     |
| `GSAPIClient`  | HTTP client for `api-XX.grand-shooting.com/v3`                 | GSCore                |
| `GSScanner`    | VisionKit barcode scanning (EAN-13 / EAN-8 / QR)               | GSCore                |
| `GSCamera`     | AVFoundation HEIF + ProRAW capture                             | GSCore                |
| `GSLiDAR`      | ARKit scene reconstruction + Object Capture photogrammetry     | GSCore                |
| `GSPackshot`   | Backend-hosted AI packshot generation                          | GSCore, GSAPIClient   |
| `GSLogistics`  | Receive / ship sample use-cases                                | GSCore, GSAPIClient   |

The `GSApp/` target is a thin SwiftUI shell that links the packages and exposes a `TabView` with four tabs: Scan, Photo, LiDAR, History.

## Authentication

The app does **not** speak OAuth directly. Our backend at `api.mobile.grand-shooting.com` holds the `client_secret` and performs the Authorization Code dance.

Flow:

1. App opens an `ASWebAuthenticationSession` pointing at the backend's `/auth/start` URL.
2. User signs in inside the system-provided web view.
3. Backend redirects to `gsmobile://auth/done?session_id=...`.
4. App exchanges the `session_id` for an access token via a separate backend call.

The URL scheme `gsmobile://` is registered in `GSApp/Info.plist`.

API base URL is configurable per user (each account lives on a shard, e.g. `https://api-34.grand-shooting.com/v3`).

The auth header format is **not** Bearer — it is `Authorization: access_token <token>`.

## Setup

1. Clone the repo.
2. Run `bin/bootstrap.sh` to install `xcodegen` (via Homebrew) and generate `GSApp.xcodeproj`.
3. Open `GSApp.xcodeproj` in Xcode 17.
4. Set your Apple Developer team ID in **two places**:
   - `project.yml` → `settings.base.DEVELOPMENT_TEAM`
   - `fastlane/Appfile` → `team_id`
5. Build & run on a real iPhone 15 Pro or newer (the simulator lacks LiDAR).

## Tests

```sh
# All packages
for p in Packages/*; do (cd "$p" && swift test); done

# Or via fastlane
fastlane tests
```

CI (`.github/workflows/ios-ci.yml`) runs each package in parallel via a matrix.

## TestFlight

```sh
cp fastlane/.env.example fastlane/.env
# Fill in App Store Connect API key values
fastlane beta
```

On every push to `main`, `.github/workflows/ios-beta.yml` runs `fastlane beta`. Note: code signing is currently **not wired** — `fastlane match` is left as a TODO until the cert repo exists.

## OpenAPI regeneration

`bin/regenerate-api.sh` is a placeholder. The intended pipeline is:

1. Pull `swagger.json` from the backend.
2. Convert Swagger 2.0 → OpenAPI 3.x via `npx swagger2openapi`.
3. Build `GSAPIClient` — `swift-openapi-generator` runs as a build plugin.

The `swift-openapi-generator` dependency is currently commented out in `Packages/GSAPIClient/Package.swift`.

## Related repos

- Backend: `gs-stream-events` (TypeScript / AWS / Fly).
