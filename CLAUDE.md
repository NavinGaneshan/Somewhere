# Somewhere — iOS Happy Hour App

Discover happy hour deals at bars and restaurants nearby. iOS app with a Firebase backend.

## Stack

- **iOS**: 16+, Swift 5.9, SwiftUI, CocoaPods, XcodeGen
- **Backend**: Firebase (Auth, Firestore, Storage, Functions, Analytics, App Check) + Google Cloud Functions in Node 22
- **External APIs**: Google Places (client-side, bundle-ID-restricted), Anthropic Claude (server-side via Cloud Functions), Firecrawl (server-side via Cloud Functions)
- **On-device**: Apple Vision for OCR, CoreLocation, MapKit

## Layout

```
Somewhere/                        iOS app source
  App/                            Entry point, AppDelegate, App Check setup
  Services/                       Networking, scanning, location, Firestore wrappers
  Models/                         Firestore-backed types (Deal, Venue, AppUser, SearchFilter, PVAConfig)
  ViewModels/                     MVVM view models
  Views/                          SwiftUI views, grouped by feature (Home, AddDeal, Map, Admin, Auth, Profile)
  Utilities/                      Extensions.swift, Constants.swift
  Resources/                      Info.plist, PrivacyInfo.xcprivacy, Fonts, Assets.xcassets
  App Store Assets/               1024 icon, screenshots, hero image (untracked of nothing useful in dev)
SomewhereTests/                   Unit tests
firebase/                         Server side
  functions/index.js              All Cloud Functions
  firestore.rules                 Firestore security rules
project.yml                       XcodeGen spec (see Gotchas)
Podfile                           CocoaPods deps
Somewhere.xcworkspace             Open this in Xcode (not the .xcodeproj)
```

## Build / run

- Open `Somewhere.xcworkspace` (CocoaPods workspace — not `.xcodeproj`).
- Run `pod install` after Podfile changes.
- For archiving: select **Any iOS Device (arm64)** as the destination, then **Product → Archive**.
- Bundle ID: `com.hhsomewhere.app`. Team: `R4SV6TP7KZ`. Automatic signing.

## Cloud Functions

- Source: `firebase/functions/index.js`. Node 22 runtime.
- Secrets in Google Cloud Secret Manager: `ANTHROPIC_KEY`, `FIRECRAWL_KEY`. Set via `firebase functions:secrets:set <NAME>`.
- Legacy: `PLACES_API_KEY` is still on the deprecated `functions.config()` system; migrate to secrets before March 2027.
- Deploy: `cd firebase && firebase deploy --only functions`
- Logs: `firebase functions:log --only scanWebsite,extractDealsFromText`
- Key callables:
  - `scanWebsite({ url })` — Firecrawl + Claude end-to-end deal extraction from a URL
  - `extractDealsFromText({ text, sourceURL? })` — Claude-only extraction from already-OCR'd text
  - `triggerPVA({ latitude, longitude, radiusMiles })` — venue discovery via Google Places
  - Scheduled: `resetDailyApiCounter`, `reverifyVenues`, `cleanupExpiredDeals`

## Architecture conventions

- **All Cloud Function callables require Firebase Auth** (`context.auth` null-check at top of handler). The iOS app calls them via `Functions.functions().httpsCallable(...)`.
- **Public Swift service APIs are stable**. `AnthropicService.shared.extractDeals(from:sourceURL:)`, `WebScanService.shared.scanForDeals(url:)`, etc. have many call sites — internal refactors fine, signature changes need site updates.
- **No LLM/3rd-party API keys in the iOS bundle, ever.** Anthropic, Firecrawl, anything LLM-ish lives behind Cloud Functions. Google Places key stays in `Info.plist` *only* because it's iOS-bundle-ID-restricted in GCP (the X-Ios-Bundle-Identifier header validates the request).
- **Photos never leave the device.** OCR runs locally via Apple Vision; only the resulting text is sent to Cloud Functions.

## Domain glossary

- **PVA** = Progressive Venue Addition — auto-discovery as users search. Adds new venues to Firestore on demand based on user location.
- **Cell** = 0.5-mile grid square. PVA tracks which cells have been searched (`pvaCells` collection) to avoid redundant Places API calls.
- **ExtractedDeal** = pre-confirmation raw output from the extraction pipeline. Becomes a `Deal` after user/admin confirms.
- **scanStatus** = a venue field tracking whether its website has been scraped yet (`pending` / `scanned` / `failed`).
- **searchLogs** = Firestore collection logging every user search with new-venue counts (used for abuse detection + analytics).

## Gotchas (in priority order)

1. **`project.yml` vs `Info.plist`**: the repo has an XcodeGen spec, but Info.plist is hand-maintained. Running `xcodegen generate` will overwrite Info.plist from the YAML's placeholder values (`GIDClientID: YOUR_GOOGLE_CLIENT_ID` etc.) and break the app. **Don't run xcodegen** until that's reconciled. The Info.plist file is the source of truth for plist values.

2. **`.xcodeproj` is gitignored.** Any edits to `Somewhere.xcodeproj/project.pbxproj` won't be tracked. Changes that need to persist (build settings, device family, version) must go in `project.yml` *and* be applied to the on-disk `.pbxproj` manually until #1 is resolved.

3. **Every Google Maps/Places request from iOS needs `X-Ios-Bundle-Identifier`.** The Places key is restricted to `com.hhsomewhere.app` and Google validates that restriction by looking for this header. `URLSession.data(from:)` does NOT set it — always build a `URLRequest`, set `X-Ios-Bundle-Identifier` from `Bundle.main.bundleIdentifier`, and pass to `URLSession.data(for:)`. This bit us twice: for photo URLs (fixed by `VenuePhotoView` in `Utilities/Extensions.swift`) and for nearby/details/textsearch (fixed by `PlacesService.fetch(_:)`). Do NOT use `AsyncImage` for Places photo URLs. The Google SDKs (GooglePlaces, GMSPlacesClient) add the header automatically — this is only a problem when you make raw HTTP calls to `maps.googleapis.com`.

4. **App ID in Apple's portal is Xcode-managed.** Listed as "com hhsomewhere app" in Identifiers; appears as "XC com hhsomewhere app" in App Store Connect dropdowns. The "XC" prefix is informational only — the underlying `com.hhsomewhere.app` works for App Store submission.

5. **Firebase Functions v4.9 + Node 22.** Deprecation warnings on `functions.config()` and outdated SDK. Don't run `npm audit fix --force` without testing — it breaks at deploy. Upgrade to firebase-functions v5+ is a planned post-launch task.

6. **PVA daily quota is configurable in Firestore**, not in code. `config/pva` doc has `maxPlacesApiCallsPerDay`, `dailyApiCallCount`, `cellStaleDays`. Reset the counter manually if you hit the cap during dev. Cell-stale-days is currently 90 to avoid burning quota on repeat-area searches.

7. **App Check is enforced.** Cloud Functions reject calls from unattested clients. The debug provider is wired up for simulator (in `AppDelegate.swift`); on a real device you may need to add the device's debug token in the Firebase console under App Check.

8. **Firebase Functions SDK drops auth on burst-parallel calls.** Firing 8+ `httpsCallable` requests to the same function URL in one tick makes the SDK send some without valid auth headers, and the server returns `UNAUTHENTICATED` (error 16) — with zero server-side log entries because the SDK bails before the request leaves the device. The GTMSessionFetcher "was already running" warning is the visible tell. `AutoScanLimiter` in `PVAService.swift` caps `autoScanVenue` at 3 concurrent to prevent this. If you add any other fan-out that hits Cloud Functions in parallel, gate it similarly.

## State of the app

- **v1.0 build 3** submitted to App Store on 2026-05-24. Waiting for review.
- iPhone only (dropped iPad before submission; orientations declared in Info.plist for both anyway).
- 5 screenshots at 1290×2796 in `Somewhere/App Store Assets/screenshots/`.
- Privacy manifest at `Somewhere/Resources/PrivacyInfo.xcprivacy` matches the App Privacy nutrition label in App Store Connect.

## Post-launch backlog

- Move `GOOGLE_PLACES_API_KEY` to a server-side proxy so the IPA has zero secrets.
- Migrate `PLACES_API_KEY` from `functions.config()` to Secret Manager.
- Refactor the `WIP` commit (`d218b90`) into focused commits.
- Reconcile `project.yml` and `Info.plist` (either resync the YAML to truth or remove XcodeGen entirely).
- Upgrade `firebase-functions` to v5+ and address `npm audit` findings.
- In-app account deletion button (currently satisfied via email path in the privacy policy).
- Build the evals pipeline for deal extraction — see the eval strategy notes.
- iPad-optimized layouts for v1.1.
