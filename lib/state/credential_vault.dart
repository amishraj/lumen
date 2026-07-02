import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../data/models/models.dart';
import '../data/repositories/library_repository.dart';
import 'providers.dart';

/// Small credential vault so a reinstall on the same device restores the
/// user's setup. The file lives in the app documents dir, which Android Auto
/// Backup snapshots to the user's Google account (encrypted with the device
/// lock on Android 9+, never readable by other apps or us). Backup rules
/// include ONLY this file — the multi-MB channel DB is excluded and simply
/// re-syncs from the provider after restore.
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
    'home_rows',
    'sidebar_width',
  ];

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
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
      final f = await _file();
      await f.writeAsString(payload, flush: true);
    } catch (_) {/* backup is best-effort — never disturb the app */}
  }

  /// Fresh install with a restored backup: repopulate sources + settings.
  /// Returns true when anything was restored (caller then re-syncs).
  Future<bool> restore(LibraryRepository repo) async {
    try {
      final f = await _file();
      if (!await f.exists()) return false;
      final data = jsonDecode(await f.readAsString());
      if (data is! Map) return false;

      var restored = false;
      final settings = data['settings'];
      if (settings is Map) {
        for (final e in settings.entries) {
          await repo.setSetting('${e.key}', '${e.value}');
          restored = true;
        }
      }
      final lists = data['playlists'];
      if (lists is List) {
        for (final p in lists) {
          if (p is! Map || p['url'] == null) continue;
          await repo.addPlaylist(Playlist(
            name: '${p['name'] ?? 'My playlist'}',
            kind:
                '${p['kind']}' == 'xtream' ? SourceKind.xtream : SourceKind.m3u,
            url: '${p['url']}',
            username: p['username'] as String?,
            password: p['password'] as String?,
            epgUrl: p['epg_url'] as String?,
            createdAt: DateTime.now().millisecondsSinceEpoch,
          ));
          restored = true;
        }
      }
      return restored;
    } catch (_) {
      return false;
    }
  }
}

/// Ran once when the app starts with an empty library: restores the vault if
/// a backup put one on disk. true = something was restored.
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
