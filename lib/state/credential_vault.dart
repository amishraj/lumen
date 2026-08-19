import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../data/db/sync_origin.dart';
import '../data/models/models.dart';
import '../data/repositories/library_repository.dart';
import 'providers.dart';

/// Small credential vault so a reinstall on the same device restores the
/// user's setup.
///
/// It is written to every location the platform gives us, because no single
/// one survives everywhere:
///
/// 1. **App documents** — snapshotted by Android Auto Backup to the user's
///    Google account (encrypted with the device lock on Android 9+, never
///    readable by other apps or us) and by iOS/macOS device backups. Backup
///    rules include ONLY this file; the multi-MB channel DB is excluded and
///    simply re-syncs from the provider after restore.
/// 2. **`Android/media/<package>/` on shared storage** (Android only) — the
///    one directory an app owns that the system does *not* delete on
///    uninstall, and which needs no storage permission. This is what makes
///    "delete and reinstall the TV APK" keep your setup: Fire TV and other
///    non-Google-certified Android TV devices have no Google backup transport
///    at all, so path 1 does nothing there and every reinstall started from
///    scratch.
///
/// On restore the newest copy wins, so whichever survived is the one used.
///
/// Contents: sources (incl. Xtream credentials) + the account/API settings.
/// Nothing here ever leaves the device except via the OS backup mechanism.
class CredentialVault {
  CredentialVault._();
  static final CredentialVault instance = CredentialVault._();

  static const _fileName = 'lumen_vault.json';
  static const _settingsKeys = [
    'trakt_access_token',
    'trakt_refresh_token',
    'trakt_username',
    'trakt_client_id',
    'trakt_client_secret',
    'rd_token',
    'rd_refresh_token',
    'rd_oauth_client_id',
    'rd_oauth_client_secret',
    'rd_token_expires_at',
    'rd_enabled',
    'tmdb_key',
    'omdb_key',
    // Lumen account session — the reinstall superpower: the media-mirror
    // copy survives uninstall on Fire TV, so a TV logs in once, ever.
    // Device-local by design (NOT in kSyncedSettings — the token must never
    // round-trip through its own sync).
    'lumen_api_base',
    'lumen_token',
    'lumen_device_id',
    'lumen_email',
    'home_rows',
    'sidebar_width',
    'seek_previews',
  ];

  Future<File> _primaryFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// The uninstall-surviving copy: `/…/Android/media/<package>/lumen_vault.json`.
  ///
  /// path_provider hands back `/…/Android/data/<package>/files`, which IS wiped
  /// on uninstall; the sibling `media` tree is not, and the owning package can
  /// read and write it without requesting any storage permission. Derived by
  /// string surgery rather than a new plugin dependency — and every failure
  /// mode simply returns null, leaving the documents copy as the only one.
  Future<File?> _externalFile() async {
    if (!Platform.isAndroid) return null;
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) return null;
      const marker = '/Android/data/';
      final path = dir.path;
      final i = path.indexOf(marker);
      if (i < 0) return null;
      final root = path.substring(0, i); // /storage/emulated/0
      final pkg = path.substring(i + marker.length).split('/').first;
      if (pkg.isEmpty) return null;
      final mediaDir = Directory('$root/Android/media/$pkg');
      if (!await mediaDir.exists()) await mediaDir.create(recursive: true);
      return File('${mediaDir.path}/$_fileName');
    } catch (_) {
      return null; // no shared storage on this device — documents copy stands
    }
  }

  /// Snapshot the current sources + settings into the vault. Cheap (a few KB)
  /// — called on app start and after onboarding/sync so the backup always has
  /// a fresh copy.
  Future<void> save(LibraryRepository repo) async {
    try {
      final playlists = await repo.playlists();
      final settings = <String, String>{};
      for (final k in _settingsKeys) {
        final v = await repo.getSetting(k);
        if (v != null) settings[k] = v;
      }
      final payload = jsonEncode({
        'v': 1,
        // Stamped so restore can pick the freshest copy when both survive.
        'at': DateTime.now().millisecondsSinceEpoch,
        'playlists': [
          for (final p in playlists)
            {
              'name': p.name,
              'kind': p.kind.name,
              'url': p.url,
              'username': p.username,
              'password': p.password,
              'epg_url': p.epgUrl,
            }
        ],
        'settings': settings,
      });
      for (final f in [await _primaryFile(), await _externalFile()]) {
        if (f == null) continue;
        try {
          await f.writeAsString(payload, flush: true);
        } catch (_) {/* one location failing must not lose the other */}
      }
    } catch (_) {/* backup is best-effort — never disturb the app */}
  }

  /// Fresh install with a surviving backup: repopulate sources + settings.
  ///
  /// Returns true when at least one **source** was restored — that's what the
  /// boot path is asking, since it decides whether to leave onboarding. A
  /// settings-only vault still applies (keys and tokens are back), but the
  /// user is sent to onboarding to add a source, rather than to a splash
  /// screen waiting for a playlist list that will never fill.
  Future<bool> restore(LibraryRepository repo) async {
    final data = await _newestPayload();
    if (data == null) return false;
    var restoredPlaylist = false;
    try {
      final settings = data['settings'];
      if (settings is Map) {
        for (final e in settings.entries) {
          // system origin: a restore must not re-push a whole vault as fresh
          // local writes at boot.
          await repo.setSetting('${e.key}', '${e.value}',
              origin: SyncOrigin.system);
        }
      }
      final lists = data['playlists'];
      if (lists is List) {
        for (final p in lists) {
          if (p is! Map || p['url'] == null) continue;
          await repo.addPlaylist(origin: SyncOrigin.system, Playlist(
            name: '${p['name'] ?? 'My playlist'}',
            kind:
                '${p['kind']}' == 'xtream' ? SourceKind.xtream : SourceKind.m3u,
            url: '${p['url']}',
            username: p['username'] as String?,
            password: p['password'] as String?,
            epgUrl: p['epg_url'] as String?,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ));
          restoredPlaylist = true;
        }
      }
      return restoredPlaylist;
    } catch (_) {
      return restoredPlaylist;
    }
  }

  Timer? _debounce;

  /// Re-snapshot shortly after a vault-relevant setting changes, coalescing
  /// bursts (connecting Trakt writes three keys back to back).
  void _scheduleSave(LibraryRepository repo) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 2), () => save(repo));
  }

  /// Keep the vault current automatically: any write to a key the vault
  /// carries schedules a fresh snapshot. Installed once at startup.
  void installAutoSave() {
    LibraryRepository.onSettingChanged = (repo, key) {
      if (!_settingsKeys.contains(key)) return;
      _scheduleSave(repo);
    };
  }

  /// The most recently written surviving copy, or null when there is none.
  Future<Map?> _newestPayload() async {
    Map? best;
    var bestAt = -1;
    for (final f in [await _primaryFile(), await _externalFile()]) {
      if (f == null) continue;
      try {
        if (!await f.exists()) continue;
        final decoded = jsonDecode(await f.readAsString());
        if (decoded is! Map) continue;
        // Vaults written before stamping carry no 'at'; treat them as oldest
        // so any stamped copy wins, but still use one if it's all there is.
        final at = (decoded['at'] as num?)?.toInt() ?? 0;
        if (best == null || at > bestAt) {
          best = decoded;
          bestAt = at;
        }
      } catch (_) {/* corrupt or unreadable — try the next location */}
    }
    return best;
  }
}

/// Ran once when the app starts with an empty library: restores the vault if
/// a backup put one on disk. true = a source was restored.
final vaultRestoreProvider = FutureProvider<bool>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  final existing = await repo.playlists();
  if (existing.isNotEmpty) {
    // Normal start — refresh the vault snapshot instead.
    await CredentialVault.instance.save(repo);
    return false;
  }
  return CredentialVault.instance.restore(repo);
});
