# Kuwait Towing & Flatbed Marketplace App

On-Demand Towing & Flatbed Aggregator Marketplace for the Kuwait market (KWD / Fils).
Built with Flutter (Dart) on Firebase Firestore & Cloud Functions.

## Contents
- [`kuwait_towing_app_handoff.md`](kuwait_towing_app_handoff.md) — full technical handoff & master blueprint (pricing engine, wireframes, DB schemas, deployment roadmap).
- [`lib/main.dart`](lib/main.dart) — runnable interactive prototype (consumer booking, driver dashboard, admin fleet console, pricing engine).
- [`pubspec.yaml`](pubspec.yaml) — dependencies.

## Pricing engine (summary)
`P = min(5.000 + max(0, d − 5.0) × 1.000, 15.000)` KWD — 15% platform commission, 3-decimal Fils formatting.

| Distance | Consumer | Admin cut (15%) | Driver payout |
|----------|----------|-----------------|---------------|
| 3.5 km   | 5.000    | 0.750           | 4.250         |
| 9.0 km   | 9.000    | 1.350           | 7.650         |
| 18.0 km  | 15.000 (capped) | 2.250    | 12.750        |

## Run
```bash
flutter pub get
flutter run
```

> Firebase credentials (`google-services.json`, `GoogleService-Info.plist`) and API keys are gitignored — add them locally per the handoff doc.
