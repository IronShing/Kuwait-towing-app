# 📑 TECHNICAL HANDOFF & MASTER BLUEPRINT
**Project:** On-Demand Towing & Flatbed Aggregator Marketplace App  
**Target Market:** Kuwait (KWD / Fils Currency Formats)  
**Development Framework:** Cross-Platform Flutter SDK (Dart)  
**Backend Infrastructure:** Firebase Firestore & Cloud Functions  

---

## 💰 1. CORE PRICING ENGINE & SYSTEM LOGIC
The application must execute a strict, capped pricing matrix based on real-world driving distance ($d$) calculated via the Google Maps Directions API. All currency outputs must display to 3 decimal places to respect Kuwaiti Fils formatting.

### 1.1 Pricing Rules
*   **Base Tier:** $d \le 5.0\text{ km} \implies \mathbf{5.000\text{ KWD}}$ (Flat Minimum)
*   **Incremental Tier:** $d > 5.0\text{ km} \implies \mathbf{+1.000\text{ KWD}}$ per additional kilometer
*   **Maximum Cap:** $\mathbf{15.000\text{ KWD}}$ (Absolute system limit)
*   **Platform Monetization:** $15\%$ commission fee taken from the gross consumer fare on every completed transaction.

### 1.2 Mathematical Model
$$P = \min\left(5.000 + \max(0, d - 5.0) \times 1.000, \, 15.000\right)$$
$$\text{Platform Commission } (C) = P \times 0.15$$
$$\text{Driver Net Payout } (D) = P - C$$

### 1.3 Financial Matrix Lookup
*   **3.5 km run:** Consumer pays `5.000 KWD` | Admin cuts `0.750 KWD` | Driver receives `4.250 KWD`
*   **9.0 km run:** Consumer pays `9.000 KWD` | Admin cuts `1.350 KWD` | Driver receives `7.650 KWD`
*   **18.0 km run:** Consumer pays `15.000 KWD` (Capped) | Admin cuts `2.250 KWD` | Driver receives `12.750 KWD`

---

## 🎨 2. SCREEN-BY-SCREEN ARCHITECTURAL WIREFRAMES

### 2.1 Consumer Booking App Layer
```
+----------------------------------------------------------------------+
| [=] Menu                                                    [Profile] |
|----------------------------------------------------------------------|
|                                                                      |
|                       GOOGLE MAPS VIEW (70%)                         |
|              (Green Pickup Pin) ---> (Red Workshop Pin)              |
|                                                                      |
|----------------------------------------------------------------------|
| Vehicle Breakdown Location Input Field                               |
| Target Repair Destination Input Field                                |
|----------------------------------------------------------------------|
| Service Vehicle Options:  [*] Flatbed Truck     [ ] Standard Tow     |
| Total Distance: 12.00 Km                                             |
|----------------------------------------------------------------------|
| [ CONFIRM & LAUNCH CHECKOUT VIA KNET ]                               |
+----------------------------------------------------------------------+
```

### 2.2 Subscriber Driver Dashboard Layer
```
+----------------------------------------------------------------------+
| [Status: ONLINE (•)]        Driver Lead Board          Today: 48 KWD |
|----------------------------------------------------------------------|
| Incoming Job Requests:                                               |
| +------------------------------------------------------------------+ |
| | Flatbed Fleet Active                  Payout: 7.650 KWD          | |
| | Pickup:  Fahaheel Highway, Blk 2                                 | |
| | Dropoff: Shuwaikh Industrial Area                                | |
| |                                                                  | |
| | [ Decline ]                          [ Accept Tow Run ]          | |
| +------------------------------------------------------------------+ |
+----------------------------------------------------------------------+
```

### 2.3 Portal Admin Terminal Layer
```
+----------------------------------------------------------------------+
| [System Terminal]            Marketplace Core            [Live Sync] |
|----------------------------------------------------------------------|
| Metrics: [ Fleet Active: 42 ] [ Active Trips: 7 ] [ Daily Fees: 110 ]|
|----------------------------------------------------------------------|
| Add New Fleet Asset Profile:                                         |
| Driver Name:     [_________________________________________________] |
| Kuwait Contact:  +965 [___________________________]                  |
| Plate License:   [___________________________]                       |
| Vehicle Profile: [Dropdown: Flatbed Deck / Hydraulic Lift / Chain v] |
|----------------------------------------------------------------------|
| [ DEPLOY ASSET TO ACTIVE RADAR ]                                     |
+----------------------------------------------------------------------+
```

---

## 📂 3. DATABASE SCHEMAS (FIREBASE FIRESTORE COMPATIBLE)
Maintain strict structural normalization across these primary collections.

### 3.1 `users`
```json
{
  "uid": "String (Unique Identity Document Key ID)",
  "full_name": "String",
  "phone_number": "String (+965 Kuwait Country Code Syntax Validation)",
  "user_role": "String (Consumer / Driver / Admin enum)",
  "joined_date": "Timestamp"
}
```

### 3.2 `fleet_units`
```json
{
  "truck_id": "String",
  "driver_name": "String",
  "driver_phone": "String",
  "license_plate": "String",
  "machinery_type": "String (Flatbed / Standard)",
  "is_available": "Boolean",
  "current_gps_lat": "Number (Double Precision Geo-Node)",
  "current_gps_lng": "Number (Double Precision Geo-Node)"
}
```

### 3.3 `orders`
```json
{
  "order_id": "String",
  "consumer_id": "String",
  "driver_id": "String (Nullable on creation)",
  "pickup_lat": "Number",
  "pickup_lng": "Number",
  "dropoff_lat": "Number",
  "dropoff_lng": "Number",
  "distance_km": "Number",
  "gross_fare_kwd": "Number",
  "admin_cut_kwd": "Number",
  "driver_cut_kwd": "Number",
  "order_status": "String (PendingPayment / Searching / OnRoute / Completed)"
}
```

---

## ⚙️ 4. FULL SCRIPT INTERACTIVE COMPONENT TARGET SOURCE
See [`lib/main.dart`](lib/main.dart) for the complete runnable Flutter source.

---

## 🛠️ 5. DEPLOYMENT & ROADMAP SEQUENCE (FROM A TO Z)

### Phase A: Environment Set Up
1. Initialize template directories: `flutter create kuwait_towing_app`
2. Add dependencies to `pubspec.yaml`:
```yaml
dependencies:
  flutter:
    sdk: flutter
  firebase_core: ^3.0.0
  cloud_firestore: ^5.0.0
  google_maps_flutter: ^2.11.0
  webview_flutter: ^4.8.0
```

### Phase B: Backend Infrastructure (Firebase Setup)
1. Provision project folder instance `kuwait-towing-marketplace` via Firebase Console.
2. Initialize target platforms using native application credentials:
   * **Android Manifest target naming namespace:** `com.marketplace.kwtow`
   * **iOS Bundle Configuration identifier:** `com.marketplace.kwtow`
3. Route download files to local structural trees: Place `google-services.json` inside `/android/app/` and `GoogleService-Info.plist` inside `/ios/Runner/`.

### Phase C: Google Maps SDK Key Provisioning
1. Activate **Maps SDK for Android**, **Maps SDK for iOS**, and **Directions API** layers via Google Cloud Dashboard.
2. Inject secret keys securely inside system build properties:
   * **Android Target Setup:** Add line to `AndroidManifest.xml`:
     `<meta-data android:name="com.google.android.geo.API_KEY" android:value="KEY_HERE"/>`
   * **iOS Target Setup:** Call service layer string within `AppDelegate.swift`:
     `GMSServices.provideAPIKey("KEY_HERE")`

### Phase D: KNET WebView Integration
1. Establish backend pipelines linking directly to regional gateway checkout APIs (e.g., MyFatoorah, Tap Payments).
2. Use dynamic HTTP POST mapping nodes targeting `/v2/SendPayment` endpoints, passing along the calculated payload values parsed directly out of the `KuwaitPricingEngine`.
3. Catch dynamic response callback handlers and launch native WebViews via the integrated library to render the secure local payment portal layout to users.

### Phase E: Compile & Run
Target device simulators directly via active CLI script execution flags:
```bash
flutter run
```
