import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

/// Fetches English subtitles on demand when a Debrid/IPTV stream ships without
/// them embedded. Uses OpenSubtitles' legacy REST search (no API key / login
/// required — the same endpoint Kodi subtitle addons use), returning the raw
/// SubRip text so the player can attach it via `SubtitleTrack.data(...)`.
class OpenSubtitlesService {
  OpenSubtitlesService();

  static const _base = 'https://rest.opensubtitles.org/search';

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 20),
    validateStatus: (s) => s != null && s < 500,
    // OpenSubtitles requires a User-Agent; this generic one works for search.
    headers: {'User-Agent': 'Lumen v1', 'X-User-Agent': 'trailers.to-UA'},
  ));

  /// Best English SRT for a title (movie or, when season/episode given, an
  /// episode). Returns the subtitle text, or null if nothing suitable is found.
  Future<String?> englishSrt(String imdbId, {int? season, int? episode}) async {
    final id = imdbId.replaceFirst(RegExp('^tt'), '');
    if (id.isEmpty) return null;

    // The path is a set of `key-value` segments in alphabetical-ish order.
    final segments = <String>[
      if (episode != null) 'episode-$episode',
      'imdbid-$id',
      if (season != null) 'season-$season',
      'sublanguageid-eng',
    ];
    final url = '$_base/${segments.join('/')}';

    try {
      final res = await _dio.get(url);
      if (res.statusCode != 200) return null;
      final data = res.data is String ? jsonDecode(res.data) : res.data;
      if (data is! List || data.isEmpty) return null;

      // Prefer SRT format, most-downloaded first.
      final subs = data.whereType<Map>().where((m) {
        final fmt = '${m['SubFormat'] ?? ''}'.toLowerCase();
        return fmt.isEmpty || fmt == 'srt';
      }).toList()
        ..sort((a, b) {
          int cnt(Map m) =>
              int.tryParse('${m['SubDownloadsCnt'] ?? 0}') ?? 0;
          return cnt(b).compareTo(cnt(a));
        });
      if (subs.isEmpty) return null;

      final link = '${subs.first['SubDownloadLink'] ?? ''}';
      if (link.isEmpty) return null;

      // The download link is gzip-compressed SubRip.
      final gz = await _dio.get<List<int>>(link,
          options: Options(responseType: ResponseType.bytes));
      final bytes = gz.data;
      if (bytes == null || bytes.isEmpty) return null;
      final raw = GZipCodec().decode(bytes);
      // Subtitle files are often Latin-1; tolerate bad bytes rather than fail.
      final text = utf8.decode(raw, allowMalformed: true);
      return text.trim().isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }
}
