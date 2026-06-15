# MedTrack Plus 💊

<p align="center">
  <img src="assets/icon.png" alt="MedTrack Plus Logo" width="180"/>
</p>

<p align="center">
  <strong>AI-Enhanced Medication Verification & Device-Free Medication Management</strong>
</p>

<p align="center">
  <a href="#-overview">Overview</a> •
  <a href="#-features">Features</a> •
  <a href="#-architecture">Architecture</a> •
  <a href="#-verification-pipeline">Verification</a> •
  <a href="#-device-free-mode">Device-Free Mode</a> •
  <a href="#-hardware">Hardware</a> •
  <a href="#-privacy--kvkk">Privacy</a> •
  <a href="#-installation">Installation</a> •
  <a href="#-team">Team</a>
</p>

<p align="center">
  <img alt="Flutter" src="https://img.shields.io/badge/Flutter-3.8%2B-02569B?logo=flutter&logoColor=white">
  <img alt="Firebase" src="https://img.shields.io/badge/Firebase-Serverless-FFCA28?logo=firebase&logoColor=black">
  <img alt="ML Kit" src="https://img.shields.io/badge/Google%20ML%20Kit-On--Device-4285F4?logo=google&logoColor=white">
  <img alt="ESP32-S3" src="https://img.shields.io/badge/ESP32--S3-Firmware-E7352C?logo=espressif&logoColor=white">
  <img alt="SDG" src="https://img.shields.io/badge/SDG-3%20%26%209-26BDE2">
</p>

---

## 📋 Overview

**MedTrack Plus** is the second development phase (FENG 498) of the Intelligent Medication
Dispensing System originally designed and validated in **FENG 497**. The first phase reliably
confirmed that medication had been *dispensed* from the device — but it could not confirm that
the patient had actually *taken* it, and it required every user to own the physical dispenser.

This phase closes both gaps:

1. **Objective, reviewable evidence of intake** — an on-device computer-vision pipeline watches
   the face, lips and pill in real time, scores each attempt, and routes only the *uncertain*
   ones to a relative for review.
2. **A complete Device-Free Mode** — the entire platform now works for anyone with a smartphone,
   no hardware required, using virtual *patient profiles* in place of physical dispensers.

The result is a **privacy-preserving, low-cost medication adherence platform that turns a
reminder into verifiable evidence**, works with or without the dispenser, and runs entirely
within the free tier of its cloud infrastructure.

### The Problem

- The WHO reports adherence to long-term therapy in chronic disease is **~50%** on average.
- The FENG 497 prototype proved *dispensing*, but intake was only **self-reported** — unreliable
  for patients with cognitive decline.
- Commercial camera-based adherence platforms (e.g. AiCure) are **expensive, subscription-based
  and cloud-dependent**, sending sensitive patient video off-device.
- Users who could not afford the dispenser were excluded from the ecosystem entirely.

### Our Solution

MedTrack Plus brings **camera-based consumption verification** — previously a feature of
expensive clinical platforms — to a low-cost system, with **on-device inference** so that, by
default, no video ever leaves the phone. A caregiver is notified **only when an attempt is
genuinely uncertain**, can watch a short auto-expiring clip, and records an informed decision.

> 🌍 **Sustainable Development Goals:** SDG 3 (Good Health & Well-Being), SDG 9 (Industry,
> Innovation & Infrastructure).

---

## ✨ Features

### 🤖 AI Intake Verification (new in Plus)

| Feature | Description |
|---------|-------------|
| 👁️ **On-Device CV** | Google ML Kit detects face, lip contours, head pose and the pill — entirely on the phone |
| 📏 **Pill-to-Lip Tracking** | Measures the normalized distance of the pill from the lips, frame by frame |
| 🔄 **11-State Session** | A guided state machine walks the patient through face → mouth → pill → close → water → swallow |
| 🎯 **Accuracy Scoring Engine** | Fuses six bounded signals into a single 0–1 confidence score |
| 🚦 **Three-Way Classification** | Every attempt is classified **success / suspicious / rejected** |
| 🎥 **Privacy-First Evidence** | Only *suspicious* attempts upload a short clip; videos auto-expire after 24 h |
| 👨‍⚕️ **Human-in-the-Loop Review** | Relatives are notified of uncertain attempts and approve / deny with a recorded decision |

### 🧑‍🤝‍🧑 Device-Free Mode (new in Plus)

| Feature | Description |
|---------|-------------|
| 👤 **Virtual Patient Profiles** | Full platform without any hardware — same role hierarchy as devices |
| 👥 **Multi-Patient Dashboards** | One caregiver can supervise several patients |
| 💊 **Unlimited Medications** | No three-section limit; add as many medications as needed per patient |
| 🗂️ **Drag-and-Drop Grouping** | Organize patients into named groups in an edit mode |
| 🎛️ **Group Control Panel** | Bulk edit schedule, stock and name across a whole group, plus custom manual groupings |
| 🖼️ **Editable Name & Photo** | Per-patient avatar and profile, per-patient reports |

### 📱 Core Application

| Feature | Description |
|---------|-------------|
| 🔐 **Google Sign-In** | Secure OAuth 2.0 authentication with silent session restore |
| 📡 **BLE Provisioning** | Easy Wi-Fi setup over Bluetooth (device mode only) |
| ⏰ **Full-Screen Alarms** | Exact alarms with snooze, optional pre-notification offset, lock-screen display |
| 🔁 **Central Alarm Coordinator** | Schedules every device *and* patient on the phone at once |
| 👥 **Role-Based Access** | Owner / Secondary / Read-Only for both devices and patients |
| 📈 **Weekly Reports** | Dispensing activity + verification statistics with accuracy gauges |
| 🌍 **Localization** | Full Turkish & English interface |

### 🔧 IoT Device (ESP32-S3, redesigned)

| Feature | Description |
|---------|-------------|
| 🎡 **4-Wheel Hold-and-Reveal** | Pills stay stationary; the wheel reveals the next dose — no free-fall jamming |
| 🧲 **Hall-Effect Homing** | Neodymium magnets + SS49E sensors recalibrate each wheel's absolute position at boot |
| 📡 **Ultrasonic Presence Sensor** | HC-SR04 gates dispensing on user approach and feeds the verification score |
| 🔊 **Voice Feedback** | DFPlayer Mini + speaker for personalized MP3 prompts |
| 💾 **Offline Mode** | NVS storage keeps operating through internet outages |
| 🔋 **Battery Reserve** | 8 × 18650 pack (~9 days calculated) with charge + boost as outage backup |

---

## 🏗️ Architecture

MedTrack Plus is a **three-tier system**:

```
┌──────────────────────────────────────────────────────────────────────────┐
│  CLIENT TIER  ─  Flutter app (Android)                                     │
│  Screens · Services · On-device CV pipeline · Alarm subsystem              │
└───────────────┬──────────────────────────────────────────────────────────┘
                │
┌───────────────▼──────────────────────────────────────────────────────────┐
│  SERVERLESS TIER  ─  Firebase                                              │
│  Firestore (source of truth) · Realtime DB (low-latency device state)      │
│  Cloud Functions (TypeScript) · Cloud Messaging (FCM) · Storage · Auth     │
└───────────────┬──────────────────────────────────────────────────────────┘
                │ Wi-Fi (polls RTDB)
┌───────────────▼──────────────────────────────────────────────────────────┐
│  EMBEDDED TIER  ─  ESP32-S3 firmware                                       │
│  Reads config & commands, reports events, runs the 4-wheel mechanism       │
└────────────────────────────────────────────────────────────────────────────┘
```

### Dual-Database Strategy (retained from FENG 497)

| Database | Purpose | Used By |
|----------|---------|---------|
| **Cloud Firestore** | User profiles, entity configs, verifications, logs — application source of truth | Mobile App |
| **Realtime Database** | Low-latency device config, commands, presence, buzzer | ESP32 Device |

**Why dual databases?** ESP32 Firestore libraries are unstable; RTDB gives ~200 ms latency vs.
~500 ms for Firestore and cleanly separates the app layer from the device layer.

### One Schema, Two Entities (entity polymorphism)

The single most important design decision: **device mode and device-free mode share one code
path.** A physical dispenser (`dispenser/{macAddress}`) and a virtual patient
(`patients/{patient_<uuid>}`) mirror the same schema, and **every service resolves the correct
collection from the identifier alone**:

```
identifier starts with "patient_"  →  patients collection
everything else                    →  dispenser collection
```

Because of this, the **alarm, verification, review, reporting and notification** subsystems all
serve both modes with no duplicated logic.

---

## 🎥 Verification Pipeline

When an alarm is dismissed, a verification session opens and analyses the camera stream
**entirely on the device**.

```
Camera frame → Frame throttler → ML Kit (face · mouth · pill)
            → Pill-to-lip distance → 11-state session machine
            → Accuracy scoring → classify → record (+ upload if suspicious)
```

### Scoring & Classification

The engine fuses **six bounded signals** with explicit weights (the weight set adapts depending
on whether the physical device is present):

| Signal | Weight (with device) | Weight (device-free) |
|--------|:--------------------:|:--------------------:|
| Pill detection | 0.22 | 0.25 |
| Lip closeness | 0.20 | 0.25 |
| Mouth-open duration | 0.18 | 0.20 |
| Pill-to-lip distance | 0.15 | 0.15 |
| Timing | 0.15 | 0.15 |
| Device presence | 0.10 | — |

The final score is **anchored on detector-validated milestones**, so a numeric score can never
contradict what the detector actually observed:

| Detector outcome | Result | Score band | Video |
|------------------|--------|:----------:|:-----:|
| Swallow confirmed | ✅ **Success** | ≥ 0.80 | not uploaded |
| Pill seen + drinking, swallow unconfirmed | ⚠️ **Suspicious** | 0.65 – 0.79 | uploaded for review |
| Pill seen, no drinking yet | ⚠️ **Suspicious** | 0.40 – 0.60 | uploaded for review |
| No stable pill | ❌ **Rejected** | ≤ 0.34 | not uploaded |

### Performance

- **~25–45 ms** measured per-frame cost against a **100 ms** budget on mid-range hardware.
- **Phase-aware frame throttling** removes ~80% of detector invocations during idle phases
  (skip factor 5 when idle, 2 in the critical window, 1 while actively tracking the pill).
- Pill track smoothed over a rolling 10-frame window; last-seen region retained through brief
  occlusions.

### Recording Settings

| Setting | Value | Reason |
|---------|-------|--------|
| Frame rate | 5 fps | Matches sustainable rate; small files |
| Bitrate | 500 kbps | A typical session stays under ~1 MB |
| Audio | off | Unnecessary; better for privacy & size |
| Safety limit | 30 s | Guarantees a session always terminates |

> When recording consent is **withheld**, the identical flow runs with a visible **20-second
> stage watchdog** instead of a recording — a stalled session still records a `not_detected`
> outcome so reports stay complete.

---

## 🧑‍🤝‍🧑 Device-Free Mode

Device-free mode replaces physical dispensers with **virtual patient profiles** that carry the
same owner / secondary / read-only hierarchy, an unlimited medications list, an editable name
and photograph, and per-patient reports.

- **Single-patient** dashboard or **multi-patient** list (selectable at onboarding, changeable
  in settings).
- **Patient grouping** by drag-and-drop in an edit mode.
- **Group Control Panel** aggregates every medication of every group member and supports bulk
  operations:
  - **Time buckets** — change a shared dose time for all members at once.
  - **Stock buckets** — update equal stock counts together.
  - **Name buckets** — rename matching medications together.
  - **Manual groupings** — user-defined groups by criterion (name / time / stock / other).
- **Read-only entries** are dimmed, untouchable, and skipped by bulk operations (which report
  how many were skipped).

---

## 🔧 Hardware

The dispenser was **redesigned** from the FENG 497 three-channel gravity-drop mechanism into a
**four-wheel hold-and-reveal** architecture. In the old design the *pill* moved (fell) while the
mechanism was static; in the new design the *mechanism* moves while the pill stays still until
the user takes it from the window — so **jamming and double-dispensing have no mechanical path
to occur**.

### Concept Comparison

| Aspect | FENG 497 (drop) | MedTrack Plus (hold-and-reveal) |
|--------|-----------------|----------------------------------|
| Dispensing principle | Free fall through feed channel | Pill stays in compartment; wheel reveals it at a window |
| Channels / wheels | 3 channels | 4 independent wheels |
| Capacity | Channel-limited | 4 × 20 = **80 doses** |
| Intake corroboration | None (self-report) | HC-SR04 presence + Hall homing + camera verification |
| Measured / target error | 15.6% (45-trial test) | Failure modes structurally removed (target ~0%) |
| Controls | Multiple buttons | Single multi-function button + mobile app |

### Main Components

| Component | Qty | Role |
|-----------|:---:|------|
| ESP32-S3-DevKitC-1 | 1 | Main controller; Wi-Fi 802.11 b/g/n, BLE 5.0 |
| 28BYJ-48 stepper + ULN2003 driver | 4 | One per wheel; geared compartment rotation |
| SS49E analog Hall sensor | 4 | Absolute home detection of each wheel |
| N52 neodymium magnet (3 × 2 mm) | 4 | Home marker embedded in each wheel's blind compartment |
| HC-SR04 ultrasonic sensor | 1 | User-presence gating + verification confidence |
| DFPlayer Mini + 3 W speaker | 1 | Personalized MP3 voice feedback |
| Tactile multi-function button | 1 | Confirm / wake / stock-status (short / long / double press) |
| 8 × 18650 + TP4056 / DW01 / MT3608 | 1 set | Battery reserve with charging and 5 V boost |
| 608ZZ bearings, M8 shafts | 4 sets | Wheel rotation on fixed shafts |
| PETG / PLA+ printed structure | — | Wheels, platforms, tunnels and enclosure |

### Wheel Geometry

| Parameter | Value |
|-----------|-------|
| Wheels | 4 (stacked, 42 mm vertical + 25 mm depth offset each) |
| Outer diameter / thickness | 200 mm / 20 mm |
| Compartments per wheel | 24 of 15° each (20 active + 4 blind) |
| Total capacity | 80 doses (4 medications × 20 doses) |
| Ring gear | Module 1.5, 130 teeth |
| Enclosure | 270 × 440 × 220 mm; side-loading refill drawers |

> 🧲 Each wheel divides 360° into 24 compartments of exactly 15°; a Hall sensor reading the
> embedded magnet of the blind home compartment recalibrates absolute position at every boot,
> so cumulative step error never exceeds one indexing cycle.

---

## 🔐 Privacy & KVKK

The project processes sensitive personal data (health-related schedules and, with consent, short
videos of the patient), so it complies with **Turkey's Personal Data Protection Law No. 6698
(KVKK)**, aligned in spirit with the GDPR:

- **On-device inference** — all computer-vision analysis runs on the phone; no frame leaves the
  device except consented review clips.
- **Explicit consent (Art. 5/1)** — video recording is **disabled by default** and enabled only
  after the user scrolls through and accepts the in-app consent text.
- **Data minimization** — only *suspicious* attempts upload a clip.
- **Storage limitation** — uploaded videos carry a **24-hour TTL** enforced by a scheduled Cloud
  Function.
- **Revocability** — consent can be withdrawn at any time from Settings.
- **Access control** — uploads are restricted by Firebase Security Rules (authenticated users,
  size & content-type limits); records follow the owner / secondary / read-only hierarchy.

---

## 📡 Data Model

### Firestore — one schema, two entities

```
dispenser/{macAddress}  |  patients/{patient_<uuid>}
   owner_mail, secondary_mails[], read_only_mails[]
   device_name | patient_name
   section_config[] (device) | medications[] (patient):
       { name, isActive, pillCount, schedule: [{h, m}, ...] }
   photo_url            (patients, optional)
   last_verification    { timestamp, score, status }

   verifications/{id}:
       classification : 'success' | 'suspicious' | 'rejected'
       accuracyScore  : 0.0 .. 1.0
       subScores      : { pill, lip, mouth, pillToLip, timing, presence }
       appMode        : 'device' | 'deviceFree'
       sectionIndex, hasDevice, userId, highestPhase
       footageUrl, failureReason?, review_decision?, timestamp

   logs/{id}: type, section, userId, timestamp, ...

users/{uid}:
   email, displayName, photoURL, fcmTokens[]
   owned_dispensers[], secondary_dispensers[], read_only_dispensers[]
   owned_patients[],   secondary_patients[],   read_only_patients[]
   device_groups[], patient_groups[], gcp_custom_groups{}
   app_mode, multi_patient
```

### Realtime Database (device mode only)

```
dispensers/{macAddress}/
   config/{section_0..n}: { name, isActive, pillCount, schedule[] }
   buzzer, presence, verification_required
   commands/dispense: { section, timestamp }
   last_verification: { timestamp, score, status }
   logs/{pushId}: { type, section, timestamp }
```

### Cloud Functions (TypeScript · Node.js 20 · europe-west1)

| Function | Trigger | Purpose |
|----------|---------|---------|
| `onVerificationCreated` | Firestore create on `*/verifications/{id}` | Notify authorized relatives via FCM for *rejected* / *suspicious* outcomes; clean up invalid tokens |
| `onReviewDecisionUpdate` | Firestore update on `*/verifications/{id}` | Notify the patient when a relative approves / denies |
| `cleanupOldVideos` | Pub/Sub schedule (hourly) | Delete `videos/` and `footage/` files older than 24 h |
| `onVideoUploaded` | Storage `onFinalize` | Audit log of uploads |

> The two create/update handlers are deployed **twice each** — once for `dispenser/*` and once
> for `patients/*` (six exports total: `onVerificationCreated` + `onPatientVerificationCreated`,
> `onReviewDecisionUpdate` + `onPatientReviewDecisionUpdate`, `cleanupOldVideos`,
> `onVideoUploaded`) — sharing one handler so both entity types behave identically.

> Notification payloads carry the entity id and verification id, so a tap **deep-links directly
> into the review screen** — even from a cold start.

---

## 🚀 Installation

### Prerequisites

- Flutter SDK **3.8+**
- Android Studio (build targets Android, compile SDK 36)
- A Firebase project with **Authentication (Google), Cloud Firestore, Realtime Database, Cloud
  Storage, Cloud Messaging, Cloud Functions**
- (Device mode) Arduino IDE / PlatformIO with ESP32-S3 board support

### Mobile App

```bash
git clone https://github.com/efesrnn/medTrackPlus.git
cd medTrackPlus

# Configure Firebase (generates lib/firebase_options.dart)
dart pub global activate flutterfire_cli
flutterfire configure

flutter pub get
flutter run
```

### Cloud Functions

```bash
cd functions
npm install
firebase deploy --only functions
```

### ESP32-S3 Firmware (device mode)

1. Install libraries: `Firebase ESP32 Client` (Mobizt), `AccelStepper`, `ArduinoJson`,
   `Preferences`, `DFRobotDFPlayerMini`.
2. Set your Firebase credentials in the firmware config.
3. Wire the four 28BYJ-48 / ULN2003 motors, SS49E Hall sensors, HC-SR04 and DFPlayer Mini per
   the firmware pin definitions, then flash the ESP32-S3.

---

## 📖 Usage

### First-Time Setup

1. Sign in with Google.
2. Choose your mode: **"Do you have a MedTrack Plus device?"**
   - **Yes → Device Mode:** provision the dispenser over BLE (enter Wi-Fi credentials), then it
     connects and registers.
   - **No → Device-Free Mode:** pick single-patient or multi-patient, then create a profile.

### Daily Flow

1. A full-screen alarm fires at each scheduled time (device mode also commands the hardware).
2. Dismissing the alarm chains **one verification session per due medication**.
3. The session guides the patient through six steps (face → mouth → pill → close → water →
   swallow) and classifies the attempt.
4. A relative is notified **only for suspicious / rejected** attempts, reviews the evidence, and
   records approve / deny.

### Role-Based Access

| Permission | Owner | Secondary | Read-Only |
|------------|:-----:|:---------:|:---------:|
| View settings & reports | ✅ | ✅ | ✅ |
| Edit configuration / stock | ✅ | ✅ | ❌ |
| Add / remove users | ✅ | ❌ | ❌ |
| Bulk group operations | ✅ | ✅ | ❌ (skipped) |

---

## 🧪 Testing

```bash
flutter test            # automated unit tests (recording & clip-extraction logic)
```

- **Unit tests** cover the recording ring buffer and clip selection without a camera, by
  constructing frame buffers in memory.
- **Component tests** validated the perception layer on real cameras (pill-shape robustness,
  mouth-open detection, pose gating, per-frame latency, throttling behavior).
- **System tests** exercised all three classifications, the consent-off watchdog, the refund
  path, the notification deep link and the review decision flow on hardware. A **developer
  mock-alarm tool** triggers the full alarm-to-verification chain on demand.

---

## 💰 Cost (prototype, local market, April 2026)

| Category | Subtotal |
|----------|---------:|
| Mechanical (motors, bearings, shafts, PETG + PLA+ filament) | ~1,720 TL |
| Electronic (ESP32-S3, battery + charge/boost, sensors, audio, etc.) | ~1,457 TL |
| Accessories & 10% spares reserve | ~480 TL |
| **Total** | **~3,660 TL** |

> The software stack is entirely free/open tooling and operating cost is held at **zero** by
> design — client-side aggregation, built-in chart widgets, suspicious-only uploads with a 24-h
> TTL, and composite indexes keep everything within the **free Firebase tier**. An enclosure
> optimized to the target dimensions, plus injection molding and a custom PCB at volume, are
> expected to cut the per-unit cost by well over half.

---

## 🗺️ Future Work

- 📊 **Calibrated scoring** — collect human-labelled sessions and learn the weights/bands (e.g.
  logistic regression) to turn the score into a calibrated probability.
- 🔬 **Custom pill model** — a small model trained on pill imagery to raise the pill signal;
  swap the moving-average tracker for a Kalman filter behind the same interface.
- 🆔 **Stable medication identifiers** — replace index-based identification; add reviewer
  identity + timestamp for a full audit trail; queue review decisions offline.
- 📈 **Scalable statistics** — windowed / paged / server-side aggregation as record volumes grow.
- 🛠️ **Hardware trial campaign** — run the same statistically designed trials as FENG 497 on the
  manufactured prototype; full-scale field pilot with elderly users.
- 🍏 **iOS build** and voice-assistant integrations.

---

## 🛠️ Tech Stack

- **Mobile:** Dart / Flutter · Riverpod · easy_localization · camera · video_player · software
  H.264 encoder · image_picker
- **On-device ML:** Google ML Kit (face detection with contours, object detection, image labeling)
- **Backend:** Firebase Auth · Cloud Firestore · Realtime Database · Cloud Storage · Cloud
  Messaging · Cloud Functions (TypeScript / Node.js 20, europe-west1)
- **Embedded:** Arduino-framework firmware on ESP32-S3 · AccelStepper · NTP · NVS · BLE provisioning

---

## 👥 Team

**FENG 498 — İzmir University of Economics, Faculty of Engineering, Computer Engineering**

| Name | Student ID | Contact |
|------|------------|---------|
| Efe Serin | 20210602055 | [@efesrnn](https://github.com/efesrnn) |
| Doğa Orhan | 20210602043 | |
| İpek Sude Yavaş | 20210602064 | |
| Ece Naz Gökalp | 20210602028 | |

**Supervisor:** Kutluhan Erol

### Acknowledgments

- **Ülkü Defne Akın** — physical enclosure & dispensing-mechanism design
- **Ersin Tütüncüoğlu** — adaptation for additive manufacturing & 3D-printed prototype production

This work builds on the FENG 497 first phase of the MedTrack project.

---

## 🙏 Built With

- [Flutter](https://flutter.dev/) — cross-platform framework
- [Firebase](https://firebase.google.com/) — serverless backend
- [Google ML Kit](https://developers.google.com/ml-kit) — on-device perception
- [AccelStepper](https://www.airspayce.com/mikem/arduino/AccelStepper/) — motor control

---

## 📄 License

Released under the MIT License (LICENSE — in progress). The team retains the design files for
the 3D-printed mechanism.

<p align="center">
  <a href="https://github.com/efesrnn/medTrackPlus/stargazers">⭐ Star us on GitHub!</a>
</p>