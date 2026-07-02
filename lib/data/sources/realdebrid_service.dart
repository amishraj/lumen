import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/library_repository.dart';
import '../../state/providers.dart';
import 'tmdb_service.dart';
import 'trakt_service.dart';

/// Real-Debrid integration. The user pastes their private API token
/// (real-debrid.com/apitoken) in Settings and flips the enable switch; streams
/// are then resolved per-title through the Torrentio addon with the RD token
/// configured, which returns direct, RD-cached HTTPS links the player can use.
///
/// The token is stored only in the local app database and sent only to
/// api.real-debrid.com and torrentio (which needs it to build RD links) —
/// never anywhere else.
class RealDebridService {
  RealDebridService(this._repo);
  final LibraryRepository _repo;

  static const _api = 'https://api.real-debrid.com/rest/1.0';
  static const _torrentio = 'https://torrentio.strem.fun';

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 30),
    validateStatus: (s) => s != null && s < 500,
  ));

  Future<String?> token() => _repo.getSetting('rd_token');
  Future<void> saveToken(String t) => _repo.setSetting('rd_token', t.trim());

  Future<bool> get enabled async =>
      (await _repo.getSetting('rd_enabled')) == '1' &&
      ((await token())?.isNotEmpty ?? false);

  Future<void> setEnabled(bool on) =>
      _repo.setSetting('rd_enabled', on ? '1' : '0');

  /// Fast health probe: does the token authenticate, and is premium active?
  Future<({bool configured, bool ok, String detail})> ping() async {
    final t = await token();
    if (t == null || t.isEmpty) {
      return (configured: false, ok: false, detail: 'No token');
    }
    try {
      final res = await _dio.get('$_api/user',
          options: Options(headers: {'Authorization': 'Bearer $t'}));
      if (res.statusCode == 200) {
        final d = res.data is String ? jsonDecode(res.data) : res.data;
        final premium = d is Map && '${d['type']}' == 'premium';
        final user = d is Map ? '${d['username'] ?? ''}' : '';
        return (
          configured: true,
          ok: premium,
          detail: premium ? '@$user · premium' : 'Not premium'
        );
      }
      return (
        configured: true,
        ok: false,
        detail:
            res.statusCode == 401 ? 'Invalid token' : 'HTTP ${res.statusCode}'
      );
    } catch (_) {
      return (configured: true, ok: false, detail: 'Unreachable');
    }
  }

  /// Junk releases we never offer: cams, telesyncs, screeners, 3D — bad
  /// quality or unwatchable on a normal screen.
  static final _junk = RegExp(
      r'\b(cam(rip)?|hd-?cam|hd-?ts|telesync|\bts\b|telecine|\btc\b|scr(eener)?|dvdscr|workprint|3d)\b',
      caseSensitive: false);

  /// Debrid streams for a title. Curated: only RD-cached (instant) results,
  /// capped at 1080p, junk releases (CAM/TS/screener/3D) removed, and ranked
  /// best-quality-first with the *smallest* file per quality tier first —
  /// high quality without pointless 60 GB remux downloads.
  Future<List<RdStream>> streams(String imdbId,
      {int? season, int? episode}) async {
    final t = await token();
    if (t == null || t.isEmpty) return [];
    final isEpisode = season != null && episode != null;
    final path = isEpisode
        ? '/realdebrid=$t/stream/series/$imdbId:$season:$episode.json'
        : '/realdebrid=$t/stream/movie/$imdbId.json';
    try {
      final res = await _dio.get('$_torrentio$path');
      if (res.statusCode != 200) return [];
      final d = res.data is String ? jsonDecode(res.data) : res.data;
      final list = d is Map ? d['streams'] : null;
      final out = <RdStream>[];
      if (list is List) {
        for (final s in list) {
          if (s is! Map || s['url'] == null) continue;
          final name = '${s['name'] ?? ''}';
          final title = '${s['title'] ?? ''}';
          // Torrentio prefixes uncached results with [RD download]; skip them —
          // they'd start a torrent download instead of playing instantly.
          if (name.contains('download')) continue;
          final quality = _quality(name, title);
          // Cap at 1080p and drop junk releases.
          if (quality == '4K') continue;
          if (_junk.hasMatch('$name $title')) continue;
          out.add(RdStream(
            url: '${s['url']}',
            quality: quality,
            label: title.split('\n').first.trim(),
            size: _size(title),
            sizeMb: _sizeMb(title),
          ));
        }
      }
      // Best quality first; within a tier, smallest file first.
      const rank = {'1080p': 0, '720p': 1, '480p': 2, 'SD': 3};
      out.sort((a, b) {
        final q = (rank[a.quality] ?? 9).compareTo(rank[b.quality] ?? 9);
        if (q != 0) return q;
        return (a.sizeMb ?? 1 << 30).compareTo(b.sizeMb ?? 1 << 30);
      });
      return out;
    } catch (_) {
      return [];
    }
  }

  static String _quality(String name, String title) {
    final all = '$name $title'.toLowerCase();
    if (all.contains('2160') || all.contains('4k')) return '4K';
    if (all.contains('1080')) return '1080p';
    if (all.contains('720')) return '720p';
    if (all.contains('480')) return '480p';
    return 'SD';
  }

  static String? _size(String title) {
    final m = RegExp(r'💾\s*([\d.]+\s*[GM]B)').firstMatch(title);
    return m?.group(1);
  }

  /// Parsed size in MB for compact-file-first sorting.
  static int? _sizeMb(String title) {
    final m = RegExp(r'💾\s*([\d.]+)\s*([GM])B').firstMatch(title);
    if (m == null) return null;
    final v = double.tryParse(m.group(1)!);
    if (v == null) return null;
    return (m.group(2) == 'G' ? v * 1024 : v).round();
  }
}

/// One playable debrid stream option.
class RdStream {
  final String url;
  final String quality;
  final String label;
  final String? size;
  final int? sizeMb;
  const RdStream(
      {required this.url,
      required this.quality,
      required this.label,
      this.size,
      this.sizeMb});
}

final realDebridServiceProvider =
    FutureProvider<RealDebridService>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  return RealDebridService(repo);
});

/// Whether debrid playback is available (enabled + token present). Bump
/// [rdRevProvider] after changing settings to re-evaluate.
final rdEnabledProvider = FutureProvider<bool>((ref) async {
  ref.watch(rdRevProvider);
  final svc = await ref.watch(realDebridServiceProvider.future);
  return svc.enabled;
});

final rdRevProvider = StateProvider<int>((ref) => 0);

/// Resolve the IMDb id for a title: TMDB external ids when available,
/// falling back to Trakt search (works with just the embedded api key).
Future<String?> imdbIdForTitle(WidgetRef ref, String title,
    {bool isShow = false}) async {
  try {
    final tmdb = await ref.read(tmdbServiceProvider.future);
    final info = await tmdb.lookup(title, isShow: isShow);
    if (info?.imdbId != null && info!.imdbId!.startsWith('tt')) {
      return info.imdbId;
    }
  } catch (_) {/* fall through to Trakt */}
  try {
    final trakt = await ref.read(traktServiceProvider.future);
    final ids = await trakt.idsFor(title, isShow: isShow);
    final imdb = ids?['imdb'];
    if (imdb is String && imdb.startsWith('tt')) return imdb;
  } catch (_) {}
  return null;
}
