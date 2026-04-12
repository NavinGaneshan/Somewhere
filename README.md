# Somewhere - iPhone App

**Find happy hour deals near you.**

Somewhere is an iOS app that scans bars and restaurants in your area and surfaces happy hour deals, filtered by time, day, category, and distance. It's built on a self-expanding venue database powered by the Progressive Venue Addition (PVA) system.

---

## Architecture

```
Somewhere/
├── Somewhere/
│   ├── App/                    # Entry point (SomewhereApp, AppDelegate)
│   ├── Models/                 # Data models (Venue, Deal, AppUser, SearchFilter, PVAConfig)
│   ├── Services/               # Business logic & API layers
│   │   ├── AuthService.swift       # Firebase Auth + Google Sign-In
│   │   ├── FirestoreService.swift  # All Firestore reads/writes
│   │   ├── LocationService.swift   # CoreLocation wrapper
│   │   ├── PlacesService.swift     # Google Places API
│   │   ├── PVAService.swift        # Progressive Venue Addition engine
│   │   ├── PhotoScanService.swift  # Vision OCR for deal scanning
│   │   └── WebScanService.swift    # Website scraping
│   ├── ViewModels/             # State management for each screen
│   ├── Views/
│   │   ├── Auth/               # Login, SignUp, ForgotPassword
│   │   ├── Main/               # ContentView, MainTabView
│   │   ├── Home/               # Deal discovery (HomeView, VenueCard, DealRow, Filter)
│   │   ├── Map/                # MapDealsView with venue pins
│   │   ├── AddDeal/            # Photo scan, website scan, manual entry
│   │   ├── Profile/            # User profile & settings
│   │   └── Admin/              # Admin dashboard (Users, Venues, Deals, PVA, Analytics)
│   └── Utilities/              # Constants, Extensions
├── SomewhereTests/
├── firebase/
│   ├── functions/              # Cloud Functions (PVA, website scan, scheduled jobs)
│   ├── firestore.rules         # Security rules
│   └── firestore.indexes.json  # Composite indexes
├── project.yml                 # XcodeGen project definition
└── Podfile                     # CocoaPods dependencies
```

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| UI | SwiftUI (iOS 16+) |
| Language | Swift 5.9 |
| Auth | Firebase Auth + Google Sign-In |
| Database | Cloud Firestore |
| Storage | Firebase Storage (deal photos) |
| Functions | Firebase Cloud Functions (Node.js 18) |
| Maps | MapKit (native) |
| Location | CoreLocation |
| OCR | Apple Vision framework |
| Venue Discovery | Google Places API |
| Project Setup | XcodeGen |

---

## Setup Instructions

### Prerequisites
- macOS 13+ with Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- [CocoaPods](https://cocoapods.org): `sudo gem install cocoapods`
- [Firebase CLI](https://firebase.google.com/docs/cli): `npm install -g firebase-tools`
- A Firebase project (free tier works for development)
- A Google Cloud project with **Places API** enabled

---

### Step 1: Create Firebase Project

1. Go to [Firebase Console](https://console.firebase.google.com) → Create a project called "Somewhere"
2. Add an **iOS app** with bundle ID `com.hhsomewhere.app`
3. Download `GoogleService-Info.plist` and place it at `Somewhere/GoogleService-Info.plist`
4. Enable these Firebase services:
   - **Authentication** → Email/Password + Google Sign-In
   - **Firestore** → Create database in production mode
   - **Storage** → Default bucket
   - **Functions** → Upgrade to Blaze plan (required for external API calls)
   - **App Check** → DeviceCheck for production

### Step 2: Configure Google Sign-In

1. In Firebase Console → Authentication → Sign-in method → Google → Enable
2. Note your **Web client ID** (starts with numbers, ends in `.apps.googleusercontent.com`)
3. In `GoogleService-Info.plist`, find `REVERSED_CLIENT_ID`
4. Update `Somewhere/Resources/Info.plist`:
   - Replace `YOUR_REVERSED_CLIENT_ID` with the value from step 3
   - Replace `YOUR_GOOGLE_CLIENT_ID` with the Web client ID from step 2

### Step 3: Get Google Places API Key

1. Go to [Google Cloud Console](https://console.cloud.google.com)
2. Enable **Places API (New)** and **Places API**
3. Create an API key restricted to your iOS app's bundle ID
4. In `Somewhere/Resources/Info.plist`, replace `YOUR_PLACES_API_KEY` with your key

### Step 4: Generate Xcode Project

```bash
cd /path/to/Somewhere
xcodegen generate
pod install
open Somewhere.xcworkspace
```

### Step 5: Deploy Firebase

```bash
cd firebase

# Set environment variables for Cloud Functions
firebase functions:config:set places.api_key="YOUR_PLACES_API_KEY"
firebase functions:config:set openai.api_key="YOUR_OPENAI_API_KEY"  # Optional

# Deploy everything
firebase deploy
```

### Step 6: Initialize Firestore Data

In Firestore console, create a `config/pva` document with the default PVA configuration:

```json
{
  "pvaModeEnabled": true,
  "cellSizeMiles": 0.5,
  "searchRadiusMiles": 1.0,
  "cellStaleDays": 30,
  "venueReverifyDays": 90,
  "maxNewVenuesPerSearch": 50,
  "maxPlacesApiCallsPerDay": 500,
  "dailyApiCallCount": 0,
  "autoScanWebsites": true,
  "autoScanEnabled": true,
  "userSubmissionsEnabled": true,
  "requireApprovalForUserDeals": true,
  "scanDelaySeconds": 1.0,
  "maxScanAttemptsPerVenue": 3
}
```

### Step 7: Create First Admin User

1. Run the app and create an account
2. In Firestore console, find your user document in `users/{uid}`
3. Change the `role` field to `"admin"`
4. You'll now see the Admin tab in the app

---

## Key Features

### Progressive Venue Addition (PVA)
The PVA system minimizes Google Places API costs by:
- Dividing the world into ~0.5 mile grid cells
- Only searching cells that haven't been searched recently (configurable staleness)
- Checking new venues against the existing database to avoid duplicates
- Automatically marking permanently-closed venues
- Respecting daily API quotas set by admin

### Deal Discovery
- Real-time search within 1 mile (configurable)
- Filter by: category (drinks/food/activity), time (now/tonight/weekend/custom), day of week, venue type
- Sort by: distance, active now, newest, top rated
- Collapsible venue cards showing all deals
- Active deal indicators with "happening now" badges

### Deal Addition
Three ways to add deals:
1. **Photo Scan**: Use camera or photo library → Vision OCR extracts deal details
2. **Website Scan**: Enter URL → scraper extracts happy hour info (AI-powered with OpenAI)
3. **Manual Entry**: Full form with all fields

### Admin Dashboard
- User management (roles: user/contributor/moderator/admin, ban/unban)
- Venue management (mark closed, delete, view scan status)
- Deal approval queue (approve/reject with notes)
- PVA controls (all settings configurable without redeployment)
- Analytics (7-day trends, category breakdown, API usage)

---

## Color Scheme

Customize colors by editing the named colors in `Assets.xcassets`:
- `AppPrimary`: Main brand color (suggested: deep navy `#1A2B4A`)
- `AppAccent`: Highlight color (suggested: warm gold `#F0A500`)
- `AppBackground`: Screen background (suggested: off-white `#F5F5F0`)
- `AppSurface`: Card backgrounds (white `#FFFFFF`)
- `AppText`, `AppSubtext`, `AppDivider`, `AppSuccess`, `AppWarning`, `AppError`

---

## Running Tests

```bash
xcodebuild test -workspace Somewhere.xcworkspace -scheme Somewhere -destination 'platform=iOS Simulator,name=iPhone 15'
```

---

## Environment Variables

| Variable | Where | Purpose |
|----------|-------|---------|
| `GOOGLE_PLACES_API_KEY` | `Info.plist` | Client-side venue photo URLs |
| `GIDClientID` | `Info.plist` | Google Sign-In |
| `places.api_key` | Cloud Functions config | Server-side Places API calls |
| `openai.api_key` | Cloud Functions config | AI deal extraction (optional) |

---

## Cost Estimates (Google Places API)

With default PVA settings (500 calls/day limit):
- Nearby Search: $0.032/call → max $16/day
- PVA cells prevent re-searching areas for 30 days
- Actual cost is typically 10-20x less than maximum due to caching

---

## Contributing

1. Fork the repo
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Commit with clear messages
4. Push and create a PR

---

## License

MIT License — see LICENSE file.
