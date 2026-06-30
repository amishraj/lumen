import '../models/models.dart';

/// Argument bundle for the isolate entrypoint (compute requires one argument).
class M3uParseArgs {
  final int playlistId;
  final String content;
  const M3uParseArgs(this.playlistId, this.content);
}

final _attrRe = RegExp(r'([\w-]+)="([^"]*)"');
final _vodExtRe = RegExp(r'\.(mp4|mkv|avi|mov|m4v)(\?|$)', caseSensitive: false);

/// Top-level so it can run in a background isolate via `compute`.
/// Parses a full M3U/M3U8 body into stream items without blocking the UI.
List<StreamItem> parseM3u(M3uParseArgs args) {
  final out = <StreamItem>[];
  final lines = args.content.split('\n');

  String? name;
  String? logo;
  String? group;
  String? tvgId;
  int? num;

  for (var raw in lines) {
    final line = raw.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#EXTINF')) {
      // #EXTINF:-1 tvg-id="x" tvg-logo="y" group-title="z",Channel Name
      final commaIdx = line.lastIndexOf(',');
      name = commaIdx >= 0 ? line.substring(commaIdx + 1).trim() : null;

      logo = null;
      group = null;
      tvgId = null;
      num = null;
      for (final m in _attrRe.allMatches(line)) {
        final key = m.group(1)!.toLowerCase();
        final val = m.group(2)!;
        switch (key) {
          case 'tvg-logo':
            logo = val;
            break;
          case 'group-title':
            group = val;
            break;
          case 'tvg-id':
            tvgId = val;
            break;
          case 'tvg-chno':
          case 'channel-number':
            num = int.tryParse(val);
            break;
          case 'tvg-name':
            name ??= val;
            break;
        }
      }
    } else if (line.startsWith('#EXTGRP:')) {
      group = line.substring(8).trim();
    } else if (line.startsWith('#')) {
      // ignore other directives (#EXTM3U, #EXTVLCOPT, etc.)
      continue;
    } else {
      // A URL line completes the current entry.
      final url = line;
      final g = (group ?? '').toLowerCase();
      StreamKind kind = StreamKind.live;
      if (_vodExtRe.hasMatch(url)) {
        kind = g.contains('seri') ? StreamKind.series : StreamKind.movie;
      } else if (g.contains('movie') || g.contains('vod')) {
        kind = StreamKind.movie;
      } else if (g.contains('seri')) {
        kind = StreamKind.series;
      }

      out.add(StreamItem(
        playlistId: args.playlistId,
        kind: kind,
        name: (name == null || name.isEmpty) ? url : name,
        logo: logo,
        url: url,
        groupTitle: (group == null || group.isEmpty) ? 'Uncategorized' : group,
        tvgId: tvgId,
        num: num,
      ));

      name = null;
      logo = null;
      group = null;
      tvgId = null;
      num = null;
    }
  }
  return out;
}
