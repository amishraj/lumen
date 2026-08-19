import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';

import '../db/sync_origin.dart';
import '../repositories/library_repository.dart';

/// Lumen account auth against the Worker (server/). Tokens are long-lived
/// bearers; the vault mirrors them, so a TV logs in once, ever — even across
/// reinstalls.
///
/// Settings keys (device-local — deliberately NOT in kSyncedSettings; the
/// session token must never round-trip through its own sync):
///   lumen_api_base   — https://lumen-api.<you>.workers.dev
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

  Future<String?> apiBase() async {
    final b = await _repo.getSetting('lumen_api_base');
    if (b == null || b.isEmpty) return null;
    return b.replaceAll(RegExp(r'/+$'), '');
  }

  Future<String?> token() => _repo.getSetting('lumen_token');
  Future<bool> get signedIn async => (await token())?.isNotEmpty ?? false;
  Future<String?> email() => _repo.getSetting('lumen_email');

  Future<Options> authOptions() async => Options(headers: {
        'authorization': 'Bearer ${await token()}',
        'content-type': 'application/json',
      });

  Future<void> saveBase(String base) =>
      _repo.setSetting('lumen_api_base', base.trim(),
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
