import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/models.dart';

/// Talks to an Xtream Codes panel (player_api.php) and normalises everything
/// into [StreamItem]s. Heavy JSON→model transforms run in a background isolate.
class XtreamClient {
  XtreamClient(this.playlist) : _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 60),
          headers: {'User-Agent': 'Lumen/1.0'},
        ));

  final Playlist playlist;
  final Dio _dio;

  String get _base => playlist.url.replaceAll(RegExp(r'/+$'), '');

  Future<String> _get(String action) async {
    final res = await _dio.get(playlist.xtreamApi(action),
        options: Options(responseType: ResponseType.plain));
    return res.data as String;
  }

  /// Validate credentials; returns the account/server info or throws.
  Future<Map<String, dynamic>> authenticate() async {
    final body = await _get('');
    final json = jsonDecode(body) as Map<String, dynamic>;
    final auth = (json['user_info']?['auth']);
    if (auth != 0 && auth != true && auth != '1' && auth != 1) {
      // Some panels omit auth on success; only fail on explicit 0.
      if (auth == 0 || auth == '0') {
        throw Exception('Xtream authentication failed — check credentials.');
      }
    }
    return json;
  }

  /// Fetch live + VOD streams and return them ready to persist.
  Future<List<StreamItem>> fetchAll({
    void Function(String stage)? onStage,
  }) async {
    onStage?.call('Loading live categories…');
    final liveCats = await _get('get_live_categories');
    onStage?.call('Loading live channels…');
    final liveStreams = await _get('get_live_streams');

    onStage?.call('Loading movie categories…');
    final vodCats = await _safe(() => _get('get_vod_categories'));
    onStage?.call('Loading movies…');
    final vodStreams = await _safe(() => _get('get_vod_streams'));

    onStage?.call('Indexing…');
    return compute(
      _transform,
      _XtArgs(
        playlistId: playlist.id!,
        base: _base,
        user: playlist.username ?? '',
        pass: playlist.password ?? '',
        liveCats: liveCats,
        liveStreams: liveStreams,
        vodCats: vodCats ?? '[]',
        vodStreams: vodStreams ?? '[]',
      ),
    );
  }

  Future<String?> _safe(Future<String> Function() f) async {
    try {
      return await f();
    } catch (_) {
      return null;
    }
  }
}

class _XtArgs {
  final int playlistId;
  final String base, user, pass;
  final String liveCats, liveStreams, vodCats, vodStreams;
  const _XtArgs({
    required this.playlistId,
    required this.base,
    required this.user,
    required this.pass,
    required this.liveCats,
    required this.liveStreams,
    required this.vodCats,
    required this.vodStreams,
  });
}

Map<String, String> _catMap(String body) {
  final out = <String, String>{};
  final list = jsonDecode(body);
  if (list is List) {
    for (final c in list) {
      if (c is Map) {
        out['${c['category_id']}'] = '${c['category_name'] ?? 'Uncategorized'}';
      }
    }
  }
  return out;
}

/// Runs in an isolate — turns raw JSON bodies into StreamItems with play URLs.
List<StreamItem> _transform(_XtArgs a) {
  final out = <StreamItem>[];

  final liveCatNames = _catMap(a.liveCats);
  final live = jsonDecode(a.liveStreams);
  if (live is List) {
    for (final s in live) {
      if (s is! Map) continue;
      final id = s['stream_id'];
      out.add(StreamItem(
        playlistId: a.playlistId,
        kind: StreamKind.live,
        name: '${s['name'] ?? ''}'.trim(),
        logo: _nullIfEmpty('${s['stream_icon'] ?? ''}'),
        url: '${a.base}/live/${a.user}/${a.pass}/$id.ts',
        groupTitle: liveCatNames['${s['category_id']}'] ?? 'Uncategorized',
        tvgId: _nullIfEmpty('${s['epg_channel_id'] ?? ''}'),
        num: int.tryParse('${s['num'] ?? ''}'),
      ));
    }
  }

  final vodCatNames = _catMap(a.vodCats);
  final vod = jsonDecode(a.vodStreams);
  if (vod is List) {
    for (final s in vod) {
      if (s is! Map) continue;
      final id = s['stream_id'];
      final ext = _nullIfEmpty('${s['container_extension'] ?? ''}') ?? 'mp4';
      out.add(StreamItem(
        playlistId: a.playlistId,
        kind: StreamKind.movie,
        name: '${s['name'] ?? ''}'.trim(),
        logo: _nullIfEmpty('${s['stream_icon'] ?? s['cover'] ?? ''}'),
        url: '${a.base}/movie/${a.user}/${a.pass}/$id.$ext',
        groupTitle: vodCatNames['${s['category_id']}'] ?? 'Movies',
        rating: double.tryParse('${s['rating'] ?? ''}'),
      ));
    }
  }

  return out;
}

String? _nullIfEmpty(String s) => s.trim().isEmpty ? null : s.trim();
