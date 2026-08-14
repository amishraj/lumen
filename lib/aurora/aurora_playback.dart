import 'dart:async';

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
    // The IPTV lookup (local DB) and the debrid-enabled read are independent —
    // run them together instead of serially before the scrape.
    final iptvFuture = iptvUrlFor(ref, item);
    final rdOnFuture = preference == PlayPreference.auto
        ? ref.read(rdEnabledProvider.future).catchError((Object _) => false)
        : Future.value(false);

    String? playUrl;
    var viaDebrid = false;
    var fromRemembered = false;

    if (await rdOnFuture) {
      // The link that played LAST time plays again — instantly, no scrape.
      // (If it died since, the player re-resolves and repairs the memory.)
      try {
        final repo = await ref.read(repositoryProvider.future);
        final choice =
            await repo.db.getStreamChoice(movieProgressKey(title));
        if (choice != null && choice.url.isNotEmpty) {
          playUrl = choice.url;
          viaDebrid = true;
          fromRemembered = true;
        }
      } catch (_) {/* fall through to a fresh resolve */}

      if (playUrl == null) {
        try {
          final imdb = await imdbIdForTitle(ref, title,
              isShow: item.kind == StreamKind.series);
          if (imdb != null) {
            final svc = await ref.read(realDebridServiceProvider.future);
            // Bounded: a slow Torrentio must not pin "Finding stream…"
            // for Dio's full 15s+30s — fall back to IPTV instead.
            final best =
                await svc.bestStream(imdb).timeout(const Duration(seconds: 12));
            if (best != null) {
              playUrl = best.url;
              viaDebrid = true;
              // Remember the pick — the next play of this title skips the
              // scrape entirely and starts on this exact link.
              final repo = await ref.read(repositoryProvider.future);
              unawaited(repo.db.saveStreamChoice(
                  movieProgressKey(title), best.url,
                  label: best.label, quality: best.quality));
            }
          }
        } catch (_) {/* fall back to IPTV below */}
      }
    }
    final iptvUrl = await iptvFuture;

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

    // Not awaited — the caller (Detail's Play button) awaits play() itself and
    // uses that to gate a brief "resolving" spinner, which must clear as soon
    // as the player opens, not stay up for the whole runtime. The refresh
    // below is chained onto the route's own future instead, so it fires the
    // moment the player is popped (mirrors openAuroraItem's series/live
    // refresh) — otherwise the watched checkmark on posters/cards only
    // updated once the Detail screen *also* closed, not right after playback.
    final route = Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AuroraPlayerScreen(
        item: item.copyWith(url: playUrl),
        resumeFraction: resumeFraction,
        playContext: AuroraPlayContext(
          title: title,
          isShow: item.kind == StreamKind.series,
          iptvUrl: iptvUrl,
          rememberedUrl: fromRemembered,
        ),
      ),
    ));
    route.then((_) {
      try {
        ref.invalidate(continueWatchingProvider);
        ref.invalidate(recentlyWatchedProvider);
        ref.invalidate(watchedIdsProvider);
        ref.invalidate(progressFractionsProvider);
      } catch (_) {/* screen disposed — nothing to refresh */}
    });
  }
}
