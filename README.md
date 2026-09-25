<p align="center">
  <img src="berkeley-plate-ios/CalSwipes/Assets%202.xcassets/AppIcon.appiconset/AppIcon.png" width="120" alt="CalSwipes app icon" />
</p>

<h1 align="center">CalSwipes</h1>

<p align="center">
  <b>Smarter meals at Berkeley.</b><br />
  An iOS app that turns live UC Berkeley Dining menus into meals that fit your calorie and macro goals.
</p>

<p align="center">
  <img alt="iOS 17+" src="https://img.shields.io/badge/iOS-17%2B-000000?logo=apple" />
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white" />
  <img alt="FastAPI" src="https://img.shields.io/badge/Backend-FastAPI-009688?logo=fastapi&logoColor=white" />
  <img alt="PostgreSQL" src="https://img.shields.io/badge/DB-PostgreSQL-4169E1?logo=postgresql&logoColor=white" />
  <img alt="Status" src="https://img.shields.io/badge/App%20Store-coming%20soon-003262" />
</p>

---

## What it does

Berkeley Dining publishes nutrition data for every item, but it is buried and hard to act on. CalSwipes pulls that data in every few hours and answers the question students actually have: *what should I eat right now to hit my goals?*

- **Make My Meal.** Pick a dining hall and meal period and get complete meal suggestions (protein, carb, produce) scored against your remaining calories and macros for the day.
- **Live Berkeley Dining menus.** Crossroads, Cafe 3, Foothill, Clark Kerr, and the campus cafes and markets, with per-serving calories, protein, carbs, and fat straight from the source.
- **Auto hall detection.** A one-time location fix picks the nearest dining hall so the right menu is already open.
- **Track your day.** Log meals from the menu, scan a packaged food's nutrition label, or enter macros manually. Daily totals, calorie history, and weight tracking included.
- **Plan My Day.** Lay out breakfast, lunch, and dinner ahead of time around your daily targets.
- **Personal goals.** Onboarding computes calorie and macro targets from your goal (lose, maintain, gain), pace, and activity level. Dietary restrictions and allergens filter every recommendation.
- **Recurring foods.** Save things you eat every day (protein shake, morning coffee) and log them in one tap.
- **Meal scanning (in development).** Photograph your tray and have the items identified and matched to today's menu, so nutrition always comes from Berkeley Dining rather than a guess.
- **Works offline.** Downloaded menus stay usable in the dining hall basement with no signal, clearly labeled as cached.

## How it works

```
 Berkeley Dining (public Eatec XML feeds)
             │  every 3 hours
             ▼
 ┌──────────────────────────────┐
 │  FastAPI backend (Fly.io)    │   parse → normalize servings/nutrition
 │  + PostgreSQL + worker       │   → versioned daily menu snapshots
 └──────────────┬───────────────┘
                │  HTTPS, ETag caching, Sign in with Apple sessions
                ▼
 ┌──────────────────────────────┐
 │  CalSwipes iOS (SwiftUI)     │   goals, recommender, logging,
 │                              │   label scanning, offline cache
 └──────────────────────────────┘
```

### Recommendation engine

`LocalRecommender` runs fully on device:

1. Hard filter: allergens, dietary tags, unpublished items, condiments/accessories
2. Classify each item into food roles (protein, carb, produce) using macros and keywords
3. Build a top candidate pool per role
4. Generate valid multi-component combinations
5. Score each combo on macro fit, completeness, preference, and meal period
6. Return the top N diverse combos (at most one shared item between any two)

### Computer vision

- **Nutrition label scanning** uses Apple's Vision text recognition on device to pull calories, protein, carbs, and fat off a label.
- **Meal scanning** sends a tray photo to the backend, which uses Gemini to identify items and match them against the live menu. Nutrition values come only from Berkeley Dining data, never from model estimates.
- **Guided segmentation** (experimental) bundles MobileSAM converted to CoreML for tap-to-outline plate and food masks, the groundwork for portion size estimation.

## Tech stack

| Layer | Tools |
| --- | --- |
| iOS | Swift, SwiftUI, AuthenticationServices, AVFoundation, Vision, CoreML, CoreLocation, Keychain |
| Backend | Python 3.12, FastAPI, SQLAlchemy, Alembic, APScheduler, HTTPX, PyJWT |
| Data | PostgreSQL 17 |
| ML | Gemini (meal identification), Apple Vision (OCR), MobileSAM via CoreML (segmentation) |
| Infra | Docker Compose, Fly.io, GitHub Actions, GitHub Pages (website) |

No third-party iOS runtime libraries. Everything on device uses Apple frameworks.

## Repository layout

```
CalSwipes/
├── berkeley-plate-ios/        SwiftUI app (XcodeGen project)
│   ├── CalSwipes/
│   │   ├── Goals/             Dashboard, onboarding, plan my day, recommender, history
│   │   ├── Scan/              Meal scan, label scan, manual entry
│   │   ├── Inference/         Gemini, Vision, and CoreML/MobileSAM pipelines
│   │   ├── Camera/            Capture session and preview
│   │   └── ...                API client, menu cache, models, design system
│   ├── Tests/                 XCTest suite
│   └── Tools/                 Model export and verification scripts
└── berkeley-dining-backend/   FastAPI + PostgreSQL menu API and importer
    ├── app/                   Parser, importer, API, auth, planning, vision
    ├── migrations/            Alembic schema revisions
    └── tests/                 Parser and PostgreSQL tests with real Berkeley fixtures
```

## Running locally

### Backend

```sh
cd berkeley-dining-backend
cp .env.example .env        # set POSTGRES_PASSWORD, scraper contact, SESSION_SECRET, GEMINI_API_KEY
docker compose up --build -d
```

API docs at http://localhost:8000/docs. See [`berkeley-dining-backend/README.md`](berkeley-dining-backend/README.md) for local Python setup and tests.

### iOS app

Requires a Mac with Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd berkeley-plate-ios
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # bundle ID, team, HTTPS API URL
xcodegen generate
open CalSwipes.xcodeproj
```

The app needs an HTTPS backend URL and a Sign in with Apple enabled App ID. Details in [`berkeley-plate-ios/README.md`](berkeley-plate-ios/README.md).

## Privacy

No ads, no tracking, no selling data. Sign in with Apple requests no name or email. Credentials live in the device Keychain. Location is used once, only to pick the nearest dining hall. Full policy on the [CalSwipes website](https://ashcash6.github.io/CalSwipes_website/privacy/).

## Authors

Built by **Ashkon Chaghajerdi** and **Dylan Brown**.

CalSwipes is an independent project and is not affiliated with, endorsed by, or sponsored by the University of California, Berkeley or Berkeley Dining.
