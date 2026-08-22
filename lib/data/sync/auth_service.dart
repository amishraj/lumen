import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';

import '../db/sync_origin.dart';
import '../repositories/library_repository.dart';

/// The Worker this build talks to, baked in — same idea as the embedded Trakt
/// credentials next door.
///
/// Typing `https://lumen-api.<something>.workers.dev` on a TV remote, one
/// character at a time on an on-screen keyboard, was a hard gate in front of
/// signing in: every new device and every reinstall paid it again, and one
/// typo reads as "could not reach the server". Nobody should ever have to know
/// this string. It stays overridable two ways — `--dart-define` at build time
/// for a fork or a staging Worker, and the Advanced field on the sign-in
/// screen at run time — so hosting your own is still one setting, not a
/// rebuild.
const String kEmbeddedLumenApiBase = String.fromEnvironment(
  'LUMEN_API_BASE',
  defaultValue: 'https://lumen-api.amishu197.workers.dev',
);

String _trimBase(String b) => b.trim().replaceAll(RegExp(r'/+$'), '');

/// The Worker base for this device: the user's own override if they set one,
/// otherwise [kEmbeddedLumenApiBase]. Null only when the embedded default has
/// been compiled out AND nothing is saved.
///
/// Shared with the TMDB / OMDb / Trakt proxies so all four agree on where the
/// server is — they each used to read the raw setting, which meant a device
/// that had never visited the sign-in screen had no base at all.
Future<String?> lumenApiBase(LibraryRepository repo) async {
  final saved = await repo.getSetting('lumen_api_base');
  if (saved != null && saved.trim().isNotEmpty) return _trimBase(saved);
  return kEmbeddedLumenApiBase.isEmpty ? null : _trimBase(kEmbeddedLumenApiBase);
}

/// Lumen account auth against the Worker (server/). Tokens are long-lived
/// bearers; the vault mirrors them, so a TV logs in once, ever — even across
/// reinstalls.
///
/// Settings keys (device-local — deliberately NOT in kSyncedSettings; the
/// session token must never round-trip through its own sync):
///   lumen_api_base   — the Worker; defaults to [kEmbeddedLumenApiBase]
///   lumen_token      — bearer
///   lumen_device_id  — server-issued device id
///   lumen_email      — display only
///   lumen_epoch      — last seen force-mode epoch
class AuthService {
  AuthService(this._repo);
  final LibraryRepository _repo;

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 20),
    validateStatus: (s) => s != null && s < 500,
  ));

  Future<String?> apiBase() => lumenApiBase(_repo);

  /// True when the user has pointed this device at their own Worker rather
  /// than the built-in one — the sign-in screen keeps its Advanced section
  /// open in that case, so an override is never invisible.
  Future<bool> hasCustomApiBase() async {
    final saved = await _repo.getSetting('lumen_api_base');
    if (saved == null || saved.trim().isEmpty) return false;
    return _trimBase(saved) != _trimBase(kEmbeddedLumenApiBase);
  }

  Future<String?> token() => _repo.getSetting('lumen_token');
  Future<bool> get signedIn async => (await token())?.isNotEmpty ?? false;
  Future<String?> email() => _repo.getSetting('lumen_email');

  Future<Options> authOptions() async => Options(headers: {
        'authorization': 'Bearer ${await token()}',
        'content-type': 'application/json',
      });

  /// Persist the base the user typed. An empty string means "use the built-in
  /// one" — stored as the resolved value so the TMDB / OMDb / Trakt proxies,
  /// which read the setting to decide whether they can proxy at all, see a
  /// concrete URL rather than a blank.
  Future<void> saveBase(String base) => _repo.setSetting(
      'lumen_api_base',
      base.trim().isEmpty ? _trimBase(kEmbeddedLumenApiBase) : _trimBase(base),
      origin: SyncOrigin.system);

  Future<({bool ok, String detail})> login(
      String base, String email, String password, String deviceLabel) async {
    await saveBase(base);
    final b = await apiBase();
    final res = await _dio.post('$b/v1/auth/login',
        data: jsonEncode({
          'email': email.trim(),
          'password': password,
          'device': deviceLabel,
          'platform': _platform(),
        }));
    if (res.statusCode != 200) {
      final msg = res.data is Map ? '${res.data['error']}' : 'HTTP ${res.statusCode}';
      return (ok: false, detail: msg);
    }
    final d = res.data is String ? jsonDecode(res.data) : res.data;
    await _storeSession(d);
    return (ok: true, detail: 'Signed in');
  }

  /// TV pairing step 1: get a code to show on screen.
  Future<({String deviceCode, String userCode})?> pairStart(
      String base, String deviceLabel) async {
    await saveBase(base);
    final b = await apiBase();
    final res = await _dio.post('$b/v1/auth/pair/start',
        data: jsonEncode({'device': deviceLabel, 'platform': _platform()}));
    if (res.statusCode != 200) return null;
    final d = res.data is String ? jsonDecode(res.data) : res.data;
    return (
      deviceCode: d['device_code'] as String,
      userCode: d['user_code'] as String
    );
  }

  /// TV pairing step 2: poll. true = paired, false = pending, throws = dead.
  Future<bool> pairPoll(String deviceCode) async {
    final b = await apiBase();
    final res = await _dio.post('$b/v1/auth/pair/poll',
        data: jsonEncode({'device_code': deviceCode}));
    if (res.statusCode == 200) {
      final d = res.data is String ? jsonDecode(res.data) : res.data;
      await _storeSession(d);
      return true;
    }
    if (res.statusCode == 428) return false;
    throw Exception('pairing expired');
  }

  /// Phone side: approve the code shown on a TV.
  Future<bool> pairApprove(String userCode) async {
    final b = await apiBase();
    final res = await _dio.post('$b/v1/auth/pair/approve',
        data: jsonEncode({'user_code': userCode}),
        options: await authOptions());
    return res.statusCode == 200;
  }

  Future<Map<String, Object?>?> me() async {
    final b = await apiBase();
    if (b == null || !await signedIn) return null;
    final res = await _dio.get('$b/v1/auth/me', options: await authOptions());
    if (res.statusCode != 200) return null;
    return (res.data is String ? jsonDecode(res.data) : res.data)
        as Map<String, Object?>;
  }

  Future<bool> revokeDevice(String deviceId) async {
    final b = await apiBase();
    final res = await _dio.post('$b/v1/auth/devices/revoke',
        data: jsonEncode({'device_id': deviceId}),
        options: await authOptions());
    return res.statusCode == 200;
  }

  Future<void> signOut() async {
    final b = await apiBase();
    try {
      if (b != null && await signedIn) {
        await _dio.post('$b/v1/auth/logout', options: await authOptions());
      }
    } catch (_) {/* revoked locally regardless */}
    for (final k in ['lumen_token', 'lumen_device_id', 'lumen_email']) {
      await _repo.setSetting(k, null, origin: SyncOrigin.system);
    }
  }

  Future<void> _storeSession(Map d) async {
    await _repo.setSetting('lumen_token', d['token'] as String,
        origin: SyncOrigin.system);
    await _repo.setSetting('lumen_device_id', '${d['device_id']}',
        origin: SyncOrigin.system);
    final user = d['user'];
    if (user is Map) {
      await _repo.setSetting('lumen_email', '${user['email'] ?? ''}',
          origin: SyncOrigin.system);
      await _repo.setSetting('lumen_epoch', '${user['epoch'] ?? 0}',
          origin: SyncOrigin.system);
    }
  }

  String _platform() => Platform.operatingSystem; // shown in the Devices list
}
