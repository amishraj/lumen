# ⚡ Lumen

A buttery-smooth personal IPTV player — one Flutter codebase for **Android, Google TV / Android TV, iOS, and macOS**. Inspired by [Lume](https://getlume.org), built to stay fluid with **40,000+ channels**.

> Lumen is a *player*. It plays the M3U playlists / Xtream Codes accounts **you** supply. It ships with no channels and no content.

---

## 🌌 1.1 — two experiences, one binary

The 1.1 line ships **Aurora**, a ground-up UI redesign (Apple TV calm × Netflix
density × Prime clarity), *alongside* the untouched **Classic** 1.0 interface —
**one app, two experiences**:

- First launch asks once: **Aurora or Classic** — switchable any time from
  either Settings screen, instantly, with no reinstall. (That in-app switch is
  also how you go "back": Android won't downgrade an installed APK.)
- Both shells share the same database, playback engine, favorites, progress
  and accounts — flipping the switch never touches your data.
- Aurora highlights: cinematic billboard home with a preloaded category wall
  and trending/live shelves; **TMDB-governed** Movies/TV Shows browsing when a
  key is set; cinematic detail pages where **Play** prefers a smart Real-Debrid
  stream (1080p, non-junk, subtitle-preferred) with a **Play on IPTV** fallback;
  a redesigned player (always-on progress bar, ◀ ▶ = ±30s, frame-preview seeks,
  next-episode countdown, fit/fill + speed) and live-TV zapping with channel
  numbers.
- Everything ships in a single build; `releases/latest` always points at the
  newest version, and the same TV Downloader code installs it.

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
├─ state/             Riverpod providers + ChannelPager + experience switch
├─ ui/                CLASSIC (1.0) experience — untouched
│  ├─ theme/          Lume-style dark theme
│  ├─ widgets/        LogoImage (downscaled cache) · ChannelTile
│  └─ screens/        onboarding · home · live · search · player · settings
└─ aurora/            AURORA (1.1) experience — a parallel UI over the same core
   ├─ aurora_theme/focus/providers/navigation
   ├─ widgets/        cards · shelves · panels · badges · search field
   ├─ pages/          home · movies · shows · live · sports · my stuff · search · settings
   ├─ screens/        movie detail · series (seasons/episodes)
   ├─ player/         redesigned player over the same PlaybackEngine
   └─ gate/           first-run experience chooser
```

Both experiences consume the same `data/` + `state/` core; a persisted
`ui_experience` setting (vault-backed, survives reinstall) decides which
shell `main.dart` boots.

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

## ☁️ Google account backup

Settings → Account → **Sign in with Google** backs the user's whole setup into
their own Google Drive **appData** folder (hidden per-app storage — no backend
of ours): sources, all settings/credentials (Trakt, Real-Debrid, TMDB, UI
choice, layout), favorites, watch progress, per-episode progress and pinned
categories. Favorites/progress are keyed by stream *url* so they survive
re-syncs and restore on a brand-new device.

- **First sign-in** (no snapshot yet): the current local setup is uploaded
  immediately.
- **Returning sign-in**: the account snapshot is merged in (newer-wins for
  progress) and the merged state re-uploaded. Anything that needs the library
  index (favorites on a fresh install) re-applies automatically after the
  first source sync.
- Afterwards every relevant change re-uploads automatically (debounced ~20s).

> **One-time setup to enable it on your builds:** Google Sign-In requires an
> OAuth client registered for the app. In Google Cloud Console create OAuth
> clients for **Android** (package `com.example.lumen`-equivalent + the
> signing certificate's SHA-1 — use a fixed keystore in CI, not the default
> debug key) and **iOS/macOS** (add the reversed client id to Info.plist).
> Until that's configured, the Sign in row shows a clear error and everything
> else works normally.

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
