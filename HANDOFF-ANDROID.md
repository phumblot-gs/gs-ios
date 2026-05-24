# Android port — handoff

Bootstrap document for a fresh Claude session porting the iOS app
in `/Users/phf/grandshooting/gs-ios` to Android in
`/Users/phf/grandshooting/gs-android`. Read once, then dive into
the iOS source for the gritty details on a per-feature basis.

The iOS repo stays the source of truth for product behaviour;
this document is the map.

---

## 1. What the app does

GS Mobile is the iPhone companion to the Grand Shooting (GS)
e-commerce shooting platform. Day-to-day workflow:

1. **Scan a product barcode** (EAN by default) → open its
   reference detail.
2. **Update stock-item status** (in stock / received / dispatched
   / lost / etc.) for that product.
3. **Capture technical views** (Presentation / Detail / OCR)
   under a chosen *shooting method*, uploaded straight to GS
   production with a per-mode filename pattern.
4. **Measure** the product with LiDAR (or as a photo on
   non-LiDAR devices) and persist the dimensions to
   `reference.extra.measures`.
5. **Tag OCR text** detected on labels into structured
   `extra.tech_views` categories (composition, care, etc.).
6. Browse a **history** of the last 50 visited references.

Settings let the user configure the GS API shard, OAuth env
(staging vs prod), focal lengths, white balance, colour profiles,
filename patterns, feature toggles, language, etc.

## 2. Project metadata to mirror

| Field | iOS value |
|---|---|
| App display name | GS Mobile |
| Bundle / package id | `com.grandshooting.gsmobile` |
| Development team | Grand Shooting (Apple team `545V88LR3Z` — Android uses Play Console) |
| Minimum OS | iOS 26 → Android target: min SDK 26 (Android 8) reasonable; ideally 30+ |
| Orientation | Portrait only |
| URL scheme for OAuth | `gsmobile://` |
| Localizations | en (source), fr, pl |

## 3. Architecture — five tabs

Bottom tab bar (SwiftUI `TabView`):

```
Scan  Photo  Measures  History  Settings
```

- **Scan**: live barcode scanner → `ReferenceDetailView` on hit.
  Also exposes "Search references" (paginated catalog search).
- **Photo**: placeholder ("Coming soon"). All capture is reached
  from the reference detail since the last refactor.
- **Measures**: LiDAR/AR measurement creation flow when the user
  is NOT yet attached to a reference (creates a `MeasureCategory`
  template). Inside a reference, you go through
  `MeasureFlowView` directly.
- **History**: last 50 visited references (UserDefaults-backed).
  Tap → re-fetch + push detail.
- **Settings**: nested screens — Scanner / Photo / Grand
  Shooting / Profile.

`ReferenceDetailView` is the central hub. From there the user can
edit metadata, run measurements, shoot tech-views, and inspect
stock items / pictures.

## 4. Backend — GS REST + mobile-backend Lambda

Two distinct backends:

### 4.1 GS public API

Sharded per tenant. Base URL example:
`https://api-19.grand-shooting.com/v3`.

Auth: `Authorization: Bearer <token>`. Token comes from either
the OAuth dance or a pre-provisioned dev token stored in the iOS
Keychain.

Key endpoints used (see `Packages/GSAPIClient/Sources/GSAPIClient/Services/`):

| Service | Endpoint(s) | Purpose |
|---|---|---|
| `StockService` | `GET /stock?<ean\|ref>=…` | Look up stock + reference by scanned value |
| `ReferenceLookupService` | `GET /reference?<filters>` | Search references (paginated) |
| `ReferenceExtraService` | `PUT /reference/:id/extra` | Persist measures + tech_views fields on `reference.extra` (server merges) |
| `PictureService` | `GET /picture?reference_ref=…` | List pictures for a reference, optionally scoped to a shooting method |
| `ProductionService` | `GET /production?…` + `POST /production` | Find or create today's production for a shooting method |
| `ProductionUploadService` | `POST /production/:rootID/bench/:rootID/upload` | Multipart photo upload |
| `ShootingMethodService` | `GET /shootingmethod` | Pick the user's shooting method in Settings |
| `BatchService`, `CategoryService`, `ZoneService` | resp. `/batch`, `/category`, `/zone` | Logistics support |

Open API spec lives in
`Packages/GSAPIClient/Sources/GSAPIClient/openapi.yaml` —
authoritative source for shapes. Worth porting to a Kotlin
OpenAPI generator on Android.

### 4.2 Mobile backend (AWS Lambda — `gs-mobile-backend` repo)

URLs:
- staging: `https://api-staging.mobile.grand-shooting.com`
- prod:    `https://api.mobile.grand-shooting.com`

Two responsibilities:
- **OAuth brokering**: `/auth/start` → `/auth/exchange` → `/auth/refresh`.
  The OAuth `client_secret` lives in AWS Secrets Manager, never
  ships to the mobile app.
- **Packshot pipeline** (server-side image processing): not yet
  consumed by the mobile app but the URL is reserved for it.

`/health` is used for the in-app banner that signals offline /
degraded backend.

## 5. Auth

Two ways to sign in:

- **OAuth (production)**: `ASWebAuthenticationSession` opens
  `<backend>/auth/start?platform=ios&redirect=gsmobile://callback`.
  GS redirects back to `gsmobile://callback?session_id=…`. The
  iOS app calls `<backend>/auth/exchange?session_id=…` to get
  `{ access_token, refresh_token, account_id?, email? }`.
  - Android: use Chrome Custom Tabs + a `BrowserSwitch`-style
    library, or AndroidX `ActivityResultContracts.StartActivityForResult`
    with an explicit intent filter on `gsmobile`.
- **Dev bearer token**: pre-provisioned token typed into Settings
  → Grand Shooting → API key. Stored in the **iOS Keychain**
  (`GSKeychain`) — on Android use the **AndroidX Security
  EncryptedSharedPreferences** or the system Keystore.

Refresh flow: when a GS API call returns 401, exchange the refresh
token via `/auth/refresh`. If that fails too, surface a re-login
prompt.

### Staff gating (tri-state)

`AuthState.staffStatus: { .staff, .notStaff, .unknown }`. The
mobile backend returns the user's `account_id` (and optionally
`email`); we treat known-staff differently from confirmed
non-staff. `.unknown` (backend doesn't yet return account info)
keeps the user's current environment choice. Non-staff users are
clamped to **production** environment in three places (OAuth
button, Settings, app .task). See
`Packages/GSAPIClient/Sources/GSAPIClient/Auth/GSAuthSession.swift`.

## 6. Persistence — iOS → Android map

| iOS | Android equivalent |
|---|---|
| `UserDefaults` (settings) | `DataStore` (preferences) |
| iOS Keychain (`GSKeychain`) | EncryptedSharedPreferences or Keystore |
| SwiftData (`MeasureCategory`, `LearnedPictogram`) | Room |
| `CGImageSource` + `CGImageDestination` (EXIF metadata) | androidx.exifinterface |
| `FileManager` temp dir | `context.cacheDir` |

The `DevSettings` class is the **single source of truth** for
every user pref. Look at it for the full surface:
`Packages/GSAPIClient/Sources/GSAPIClient/Auth/DevSettings.swift`.
Notable groups:

- **Backend**: `gsAPIShard`, `backendEnvironment` (staging/prod),
  `apiKey` (Keychain), `currentEnvironment` derived
- **Scanner**: `searchAttribute` (.ean / .ref), enabled stock
  statuses, default status on register, active zone
- **Tech views**: `techViewsShootingMethodID` + name, focal
  lengths per mode (presentation / detail / ocr), capture
  persistence (always Presentation vs remember last), white
  balance, colour profile, colour space
- **Filename patterns**: `photoFilename<Mode>Pattern` for
  Presentation / Detail / OCR / Measure. Placeholders: `{EAN}`,
  `{REF}`, `{INC}` (1-based counter, seeded from today's GS
  production)
- **Features**: `isOCREnabled` (default true), `isMeasureEnabled`
  (default = device has LiDAR)
- **Profile**: `languagePreference` (.system, .en, .fr, .pl),
  `measurementUnit` (cm, in)

## 7. Domain models

In `Packages/GSAPIClient/Sources/GSAPIClient/Domain/`:

- **Reference**: catalog product. Identified by `ref` (string,
  user-facing) and `id: Int?` (numeric). Has `displayName`,
  `ean`, `categoryID`, `extra: ReferenceExtra?` (measures +
  tech_views).
- **ReferenceStock**: pair of `Reference` + `[StockItem]`.
- **StockItem**: physical instance of a reference. Has a
  `StockItemStatus` (in stock, received, lost, sent, etc.).
- **Picture**: one row in `/picture`. Many pictures per file
  (status transitions). Use `[Picture].latestByFilePath()` to
  dedupe. `thumbnail` is a CDN URL; `path` / `file_path` are
  storage keys, NOT loadable URLs (see lessons learned).
- **Production**: day's bench grouping for uploads. `rootID` is
  what `ProductionUploadService.upload` keys on.
- **ShootingMethod**: GS concept that scopes pictures (Packshot,
  Lifestyle, Detail…). The user picks one in Settings.
- **Category**: GS catalog category tree (univers / gamme / family).
- **MeasureCategory** (SwiftData @Model, local-only): a local
  template (e.g. "Robe") with N named measurements + an
  illustration image. Auto-matches to GS categories.
- **LearnedPictogram** (SwiftData @Model): user-tagged
  pictograms (care symbols) keyed by Vision feature print +
  label + category. Used to auto-suggest tags on subsequent OCR
  shots.

## 8. Critical flows

### 8.1 Scan → reference detail

`GSApp/Scan/ScanProductFlow.swift` → `BarcodeScannerView` →
`StockService.search` → `ReferenceDetailView`.

If the search returns 0 references but the value is plausibly an
EAN, the user can register it manually.

### 8.2 Reference detail screen

`GSApp/Scan/ReferenceDetailView.swift`. Sections (in order):

1. **Reference card**: name, ref, EAN, category breadcrumb,
   counts.
2. **Reference picker** (when multiple matches): segmented.
3. **Stock items**: picker if >1, status row, "Change status"
   button → status picker sheet → `StockService.updateStatus`.
4. **Measures**: list of `extra.measures`, latest measurement
   illustration thumbnail, "Take/Retake measurements" button.
5. **Metadata**: `extra.tech_views` structured text fields
   (origin, composition, care, standards, restrictions, notes),
   Edit button, plus a "Labels" strip showing the OCR pictures.
6. **Tech views**: gallery of Presentation/Detail pictures,
   "Capture tech views" button.
7. **Pictures**: standard view-type list (cross-checks expected
   views vs uploaded ones).

Each loader has its own LoadStatus (.loaded / .failed /
.refreshing), pull-to-refresh, banner with retry, and silent
retry-with-backoff (0.8 s / 1.8 s) before surfacing the error.

### 8.3 Tech-views capture

`GSApp/Photo/TechViewsCaptureView.swift`. Live camera with a
shutter and a Photo/Detail/OCR toggle (or locked mode for the
measure-as-photo flow). After each shot:
- Filename computed via `TechViewsFilenameCounter` (seeded from
  today's GS production filenames so re-entries don't overwrite).
- Pre-cached locally as a "ghost preview" (filename + JPEG
  bytes) BEFORE the upload, so the reference detail can render
  the just-shot picture even while the upload + GS pipeline are
  still in flight.
- Upload Task fires (multipart to
  `/production/:rootID/bench/:rootID/upload`).
- If in OCR mode AND OCR feature is on: Vision OCR + picto
  detection runs on the bitmap; the user tags each observation
  with a `TechViewCategory`. On Save, the tagged text is pushed
  via `ReferenceExtraService.updateTechViews`.
- Otherwise (Presentation, Detail, OCR-with-feature-off, locked
  Measure): just upload, return to live camera for the next shot.

### 8.4 Measurement flow

`GSApp/Measure/MeasureFlowView.swift`. Five-step state machine:

1. `.capturing` — live ARKit view, single shutter.
2. `.editing` — frozen frame, user selects which detected
   objects to keep (cutout segmentation via Vision).
3. `.picking` — pick the matching `MeasureCategory` (auto-match
   by Vision feature print first; otherwise the user searches).
4. `.placing` — drop N points (or 2-per-measurement) on the
   product in 3D LiDAR space; live distance overlay.
5. `.summary` — review values, attach to reference (or save
   as a new template if creation flow).

On Save:
- `extra.measures` PUT to GS.
- `MeasureSummaryView` renders an illustration (cutout + segment
  polylines + labels + value legend) and uploads it as a
  Measurement-pattern tech view. Same ghost-preview pattern.

When `isMeasureEnabled == false` (non-LiDAR device): the button
opens `TechViewsCaptureView` with `lockedMode: .measure` instead.
Single mode camera, picker hidden, uploads under the Measurement
filename pattern.

### 8.5 History tab

`GSApp/HistoryTab.swift` + `History/ReferenceHistoryStore.swift`.
`ReferenceDetailView.task` records the visit; the store
deduplicates (newest wins), caps at 50, persists to UserDefaults
as ISO-8601 JSON. Row tap → re-fetches the live reference, then
pushes `ReferenceDetailView` with `.stock([…])`.

### 8.6 Settings

`GSApp/Settings/`. Four sub-screens:

- **Scanner**: search attribute (ean/ref), enabled stock
  statuses, default-on-register status, active zone.
- **Photo**: capture persistence, focal lengths (per mode,
  35mm-equivalent, user-configurable), white balance, colour
  profile, colour space, feature toggles (OCR / Measures),
  filename patterns (×4).
- **Grand Shooting**: shooting method picker, API key, env,
  shard, batch types.
- **Profile**: language, measurement unit, sign-out.

## 9. Hardware abstractions

### 9.1 Camera (`Packages/GSCamera`)

Wraps `AVCaptureSession` + `AVCapturePhotoOutput` +
`AVCaptureDevice.RotationCoordinator`. Key concepts to port:

- **CaptureMode** (`.presentation`, `.detail`, `.ocr`, `.measure`):
  drives focal target, white balance behaviour, colour grading.
- **CameraConfiguration**: mode + white balance + colour profile
  + colour space + 35mm-equivalent target focal. Lens selection
  uses `AVCaptureDevice.DiscoverySession` to pick the best
  optical match (telephoto / wide / ultra-wide).
- **35mm-equivalent focal length**: `f = 18 / tan(FOV/2)`. The
  camera applies digital zoom on top to hit the user-configured
  target.
- **White balance**: auto vs fixed Kelvin presets
  (`PresentationWhiteBalance`).
- **Colour profile**: CoreImage post-process curves
  (`PresentationColorProfile.{none, neutral, appleLike, samsungLike,
  pixelLike, studio}`).
- **Colour space**: ICC tag (`sRGB`, `displayP3`).
- **EXIF metadata preservation**: round-trip through
  `CGImageSource` → `CIImage(cgImage:).oriented(_:)` →
  `CGImageDestination`, with TIFF orientation override in two
  places (graph + destination options). Was a multi-attempt
  saga; android.media.ExifInterface is the moral equivalent.

On Android: CameraX (`androidx.camera`) is the modern equivalent.
Focal-length targeting is doable via CameraX zoomRatio +
`CameraInfo.intrinsicZoomRatio`. Colour grading via Renderscript
is dead — use OpenGL / Vulkan compute or `androidx.media3` effects.

### 9.2 LiDAR (`Packages/GSLiDAR`)

ARKit `ARWorldTrackingConfiguration` with
`.sceneReconstruction(.meshWithClassification)`. Detects 3D
points the user taps on the live view. Vision feeds the cutout
segmentation pass.

Android: **ARCore** with Depth API. Same conceptual flow (raycast
into a depth-aware mesh). LiDAR-only iPhones map to depth-capable
Android devices (Samsung S20 Ultra, Pixel 6 Pro, etc.). Feature
detection: `ArCoreApk.checkAvailability()`.

### 9.3 OCR / Vision

- **`VNRecognizeTextRequest`** for OCR. Android: ML Kit Text
  Recognition v2.
- **`VNGenerateImageFeaturePrintRequest`** for picto similarity.
  Android: ML Kit doesn't expose a direct equivalent — use
  TensorFlow Lite's MobileNet embedding or
  `androidx.camera.mlkit.vision` with a custom model.
- **`VNDetectContoursRequest`** for object detection (cutout).
  Android: ML Kit Subject Segmentation or a TFLite DeepLab.

## 10. Internationalization

- Source language: English.
- Catalog: `GSApp/Localizable.xcstrings` (Apple String Catalog).
  Equivalent on Android: `res/values/strings.xml`,
  `res/values-fr/strings.xml`, `res/values-pl/strings.xml`.
- Language override: at the SwiftUI root we apply
  `.environment(\.locale, currentLocale)` derived from
  `DevSettings.languagePreference.localeIdentifier`. On Android:
  `AppCompatDelegate.setApplicationLocales(LocaleListCompat.create(Locale("fr")))`.
- Helper scripts to bulk-fill translations:
  `bin/add_polish_translations.py` and `bin/sync_translations.py`
  (both idempotent, dictionary-based). Worth porting the
  dictionary verbatim.

## 11. Cross-cutting UX patterns (lessons learned)

These came up during the iOS build and apply 1:1 on Android.

- **Ghost previews**: any flow that uploads to GS shows a local
  thumbnail with an "Uploading…" pill until the GS Picture row
  surfaces. `ReferenceDetailView.localCapturePreviews:
  [String: ByteArray]`. Crucial because GS may take 30+ seconds
  to generate CDN thumbnails after a successful upload.
- **Retry-with-backoff loaders**: every list fetch (stock,
  pictures, tech views) wraps the network call in
  `loadWithRetry(attempts: 3, delays: [800ms, 1800ms])` before
  raising a banner. Transient GS slowness shouldn't flash red.
- **`thumbnail` vs `path` confusion**: ONLY `picture.thumbnail`
  is a CDN URL. `picture.path` and `picture.file_path` are
  storage keys — do NOT pass them to an image loader. Same trap
  awaits on Android.
- **Filename counter seeding**: re-entering a capture flow on
  the same day must NOT overwrite earlier shots. The counter
  queries today's GS filenames at flow start and seeds the
  `{INC}` from the max existing value.
- **`onExit` racing the upload**: the upload Task is
  fire-and-forget. If the user dismisses before it resolves, the
  parent must already have the local preview cached BEFORE the
  upload starts (not after).
- **iOS 18+ matched zoom**: `matchedTransitionSource` +
  `.navigationTransition(.zoom(sourceID:in:))`. Android
  equivalent: Material 3 container transform via
  `androidx.transition` / Compose `SharedTransitionLayout` and
  `Modifier.sharedElement`.

## 12. Security / privacy constraints

- **NEVER commit secrets**: the dev bearer token, OAuth client
  secret, AWS creds are all kept out of source. The mobile app
  only ever holds the dev token (in Keystore) and short-lived
  OAuth tokens. The backend has the client_secret.
- **No user email in logs**: RGPD. `account_id` is fine to log.
- **No tokens in logs**: ever.
- **Mock auth removed**: there is no `test/test2026` shortcut —
  production requires OAuth.
- **Force production for non-staff**: `staffStatus == .notStaff`
  clamps the env in three places.

## 13. CI / repo conventions

- **Single `main` branch**. PRs preferred for big changes but
  direct commits to main are fine for small UX tweaks.
- **xcodegen + Swift Package Manager** for project generation
  (`project.yml`). Android: Gradle + version catalogs (toml).
- **CI**: GitHub Actions builds GSApp + tests each Swift package
  on every push. Android: add `gradle build` + `connectedCheck`.
- **Commit messages**: short subject (≤ 70 char), motivation in
  the body. `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`
  on AI-collab commits.
- **No `--no-verify`**, no force-push to main without explicit
  ask.

## 14. Folders / files to read first when bootstrapping

In priority order:

1. `Packages/GSCore/Sources/GSCore/GSCore.swift` — `GSEnvironment`,
   `GSLogger`, `GSDeviceSupport`.
2. `Packages/GSAPIClient/Sources/GSAPIClient/openapi.yaml` — the
   REST surface authoritative.
3. `Packages/GSAPIClient/Sources/GSAPIClient/Auth/DevSettings.swift`
   — the entire settings surface.
4. `Packages/GSAPIClient/Sources/GSAPIClient/Auth/GSAuthSession.swift`
   + `OAuthSignInService.swift` — auth state + OAuth dance.
5. `GSApp/Scan/ReferenceDetailView.swift` — the central screen,
   long file (~1500 lines) but covers most of the product.
6. `GSApp/Photo/TechViewsCaptureView.swift` — capture loop.
7. `GSApp/Measure/MeasureFlowView.swift` + `MeasureSummaryView.swift`
   — LiDAR flow.
8. `GSApp/Localizable.xcstrings` — translation source.

## 15. Out-of-scope for now

These iOS features can wait or might not need an Android port:

- Long-press-on-logo easter egg to toggle staging mode (dev
  affordance — keep iOS-only or replace with a Settings flag).
- The Apple-specific "Single Size 1024×1024 AppIcon" — Android
  uses `mipmap-anydpi-v26` adaptive icons.
- `AVCaptureDevice.DiscoverySession` lens caching — Android's
  CameraX provider already caches.
- `ScheduleWakeup` / `Monitor` tooling — iOS-only Claude Code
  helpers, irrelevant on Android.

## 16. Suggested kickoff for the new session

```
Prompt to give the new session:

Bootstrap an Android port of the GS Mobile iOS app. The iOS
source of truth is /Users/phf/grandshooting/gs-ios with a full
handoff doc at HANDOFF-ANDROID.md in its root. Read that first,
then propose:

  1. A directory layout for /Users/phf/grandshooting/gs-android
     (Gradle modules, Compose UI, datastore + room, etc.)
  2. The first module to scaffold (suggest: GSCore-like
     equivalent with environment + auth + datastore).
  3. Concrete dependency choices (Compose BOM, CameraX, ARCore,
     ML Kit, Coil for images, Ktor or Retrofit, Kotlin
     Serialization).

Don't start coding until I confirm the layout.
```

That prompt is enough to bootstrap a clean session that won't
drag iOS implementation noise into Android decisions.
