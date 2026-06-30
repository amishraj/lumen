# ⚡ Lumen

A buttery-smooth personal IPTV player — one Flutter codebase for **Android, Google TV / Android TV, iOS, and macOS**. Inspired by [Lume](https://getlume.org), built to stay fluid with **40,000+ channels**.

> Lumen is a *player*. It plays the M3U playlists / Xtream Codes accounts **you** supply. It ships with no channels and no content.

---

## ✨ Features

- **M3U / M3U8 playlists** and **Xtream Codes** accounts
- **Live TV** + **Movies** browsing, sharded by category
- **Instant search** across the entire library (FTS5)
- **Favorites** and **resume-watching** for VOD
- **libmpv playback** (media_kit) — handles MPEG-TS, HLS and the messy real-world codecs IPTV throws at you, with hardware decode
- Polished dark UI, designed to feel premium and calm
- Installs on **Google TV / Android TV** (leanback launcher declared)

---

## 🏎️ How it stays buttery with 40k+ channels

The whole design is built around one rule: **never hold the full library in memory, and never block the UI thread.**

| Concern | Naïve approach (janky) | Lumen's design |
|---|---|---|
| **Parsing** a multi-MB M3U / huge Xtream JSON | Parse on UI thread → multi-second freeze | Parsed in a **background isolate** (`compute`), streamed into the DB |
| **Storage** | Keep 40k objects in RAM | **SQLite is the source of truth**; UI queries indexed windows |
| **Search** | Scan 40k strings per keystroke | **FTS5** virtual table → instant prefix/substring match, debounced |
| **Scrolling** | Build 40k widgets | Virtualized `ListView.builder` with fixed `itemExtent`, fed by a **paged loader** (60 rows at a time) |
| **Category switch** | Re-query everything | Indexed `(playlist, kind, group, num)` — each category is a small shard |
| **Logos** | 40k full-res network images → OOM | `cached_network_image`, **disk-cached + decoded at tile resolution** (`memCacheWidth`), only visible tiles fetch |
| **EPG** | Load entire XMLTV (100s of MB) | Lazy now/next per visible channel, indexed `(channel_id, start)` |
| **Ingest writes** | One giant INSERT | **Batched transactions** (~800 rows) + a single `INSERT..SELECT` to populate FTS |

SQLite is opened in **WAL mode** with `synchronous=NORMAL` for fast concurrent reads while a sync writes.

### Architecture

```
lib/
├─ data/
│  ├─ models/         plain data classes (no codegen)
│  ├─ db/             SQLite schema, FTS5, batched ingest, paged queries
│  ├─ sources/        m3u_parser (isolate) · xtream_client (isolate transform)
│  └─ repositories/   fetch → parse → persist orchestration
├─ state/             Riverpod providers + ChannelPager (paged infinite scroll)
└─ ui/
   ├─ theme/          Lume-style dark theme
   ├─ widgets/        LogoImage (downscaled cache) · ChannelTile
   └─ screens/        onboarding · home · live · search · player · settings
```

---

## 📦 Distribution (how your friends get it)

Releases are built **in the cloud** by GitHub Actions — no local toolchain needed.

1. Tag a version and push:
   ```bash
   git tag v1.0.0 && git push origin v1.0.0
   ```
2. GitHub Actions builds and attaches installers to the **Release**:
   - `Lumen-universal.apk` — installs on any Android phone/tablet **and Google TV / Android TV**
   - `Lumen-arm64.apk` / `Lumen-armv7.apk` — smaller per-architecture builds
   - `Lumen-macOS.zip` — the macOS app
   - `Lumen-iOS-unsigned.ipa` — sideload with AltStore / Sideloadly
3. Friends download from the repo's **Releases** page (or the landing page in `docs/`).

> **Private repo note:** on a private repo, only collaborators can download release assets. Either add your friends as collaborators, or flip the repo to public if you want a plain shareable link. See `docs/index.html` for a Lume-style download page.

---

## 🛠️ Building locally

```bash
flutter pub get
flutter run                 # debug on a connected device/emulator
flutter build apk --release # release APK
```

Requires Flutter 3.4+. Android build needs ~2 GB free disk for the first build (libmpv native libs + Gradle caches).

---

## 🧭 Roadmap / not-yet-done

- Series (episodes/seasons) browsing — schema is ready, UI is stubbed
- XMLTV EPG ingestion (Xtream short-EPG + full XMLTV table)
- Profiles + parental PIN
- Apple TV (tvOS) — **not** covered by Flutter; would be a separate small SwiftUI app sharing this data model
- Cross-device watch-progress sync
