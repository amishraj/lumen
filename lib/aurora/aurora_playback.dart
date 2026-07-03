import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/models.dart';
import '../data/repositories/library_repository.dart';
import '../data/sources/realdebrid_service.dart';
import '../state/providers.dart';
import '../ui/title_utils.dart';
import 'aurora_theme.dart';
import 'player/aurora_player.dart';

/// How a title should be played.
enum PlayPreference {
  /// Smart default: a good Real-Debrid stream when available, else the IPTV
  /// match — what the primary "Play" button does.
  auto,

  /// Force the user's own IPTV stream (the "Play on IPTV" button).
  iptv,
}

/// Central movie/one-off playback resolver for Aurora.
///
/// Default ("Play") prefers a smart Real-Debrid stream — a 1080p, non-junk
/// release, ideally the compact one with subtitles — and quietly falls back to
/// the matched IPTV stream if Debrid is off or has nothing cached. "Play on
/// IPTV" forces the library's English-preferred match.
///
/// Series episodes and live channels don't route through here (they carry a
/// concrete IPTV url already); they open the player directly.
class AuroraPlayback {
  AuroraPlayback._();

  /// Choose the best cached Debrid stream. The service already caps at 1080p,
  /// drops CAM/TS/screener/3D, and sorts best-quality-then-smallest-file; here
  /// we nudge toward a 1080p pick that advertises subtitles.
  static RdStream? bestStream(List<RdStream> streams) {
    if (streams.isEmpty) return null;
    bool hasSubs(RdStream s) {
      final l = s.label.toLowerCase();
      return l.contains('sub') || l.contains('.srt') || l.contains('multi');
    }

    final hd = streams.where((s) => s.quality == '1080p').toList();
    final pool = hd.isNotEmpty ? hd : streams;
    // Prefer a subtitled release among the top few compact picks; otherwise
    // the first (already the smallest good-quality file).
    for (final s in pool.take(6)) {
      if (hasSubs(s)) return s;
    }
    return pool.first;
  }

  /// The library's English-preferred IPTV stream for [title], if the user's
  /// source carries it. Returns the item's own url when it already is one.
  static Future<String?> iptvUrlFor(
    WidgetRef ref,
    StreamItem item,
  ) async {
    // A real library item (has an id + a non-sentinel url) already is IPTV.
    if (item.id != null && item.url.isNotEmpty && !item.url.startsWith('tmdb:')) {
      return item.url;
    }
    final repo = await ref.read(repositoryProvider.future);
    final pl = ref.read(activePlaylistProvider);
    if (pl?.id == null) return null;
    final kind = item.kind == StreamKind.series
        ? StreamKind.series
        : StreamKind.movie;
    final hits = await repo.search(
        playlistId: pl!.id!, kind: kind, query: cleanTitle(item.name).title);
    return LibraryRepository.preferEnglish(hits)?.url;
  }

  /// Resolve and open the player for a movie/one-off title.
  static Future<void> play(
    BuildContext context,
    WidgetRef ref,
    StreamItem item, {
    PlayPreference preference = PlayPreference.auto,
    double? resumeFraction,
  }) async {
    final title = cleanTitle(item.name).title;
    final iptvUrl = await iptvUrlFor(ref, item);

    String? playUrl;
    var viaDebrid = false;

    if (preference == PlayPreference.auto) {
      final rdOn = await ref.read(rdEnabledProvider.future);
      if (rdOn) {
        try {
          final imdb = await imdbIdForTitle(ref, title,
              isShow: item.kind == StreamKind.series);
          if (imdb != null) {
            final svc = await ref.read(realDebridServiceProvider.future);
            final best = bestStream(await svc.streams(imdb));
            if (best != null) {
              playUrl = best.url;
              viaDebrid = true;
            }
          }
        } catch (_) {/* fall back to IPTV below */}
      }
    }

    playUrl ??= iptvUrl ?? (item.url.startsWith('tmdb:') ? null : item.url);

    if (!context.mounted) return;
    if (playUrl == null || playUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: Aurora.bgRaised,
        content: Text(
          preference == PlayPreference.iptv
              ? '"$title" isn\'t in your IPTV library.'
              : 'No stream found for "$title".',
          style: const TextStyle(color: Aurora.text),
        ),
      ));
      return;
    }

    if (viaDebrid && iptvUrl == null) {
      // Debrid-only title (not in the library) — fine, just no IPTV fallback.
    }

    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AuroraPlayerScreen(
        item: item.copyWith(url: playUrl),
        resumeFraction: resumeFraction,
        playContext: AuroraPlayContext(
          title: title,
          isShow: item.kind == StreamKind.series,
          iptvUrl: iptvUrl,
        ),
      ),
    ));
  }
}
