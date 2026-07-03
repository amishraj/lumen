import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../data/sources/realdebrid_service.dart';
import '../../state/detail_bundle.dart';
import '../../state/providers.dart';
import '../../ui/title_utils.dart';
import '../aurora_navigation.dart';
import '../aurora_playback.dart';
import '../aurora_providers.dart';
import '../aurora_theme.dart';
import '../widgets/aurora_badges.dart';
import '../widgets/aurora_buttons.dart';
import '../widgets/aurora_cards.dart';
import '../widgets/aurora_image.dart';
import '../widgets/aurora_shelf.dart';

/// Movie detail — a full-bleed cinematic page. One bundled metadata fetch
/// (OMDb ∥ TMDB) so everything lands in a single update.
///
/// Playback: the primary **Play** prefers a smart Real-Debrid stream (a 1080p,
/// non-junk release, ideally subtitled), falling back to the library's IPTV
/// match. A secondary **Play on IPTV** forces the English-preferred library
/// stream. Both resolve asynchronously with an inline spinner.
class AuroraDetailScreen extends ConsumerStatefulWidget {
  const AuroraDetailScreen({super.key, required this.item});
  final StreamItem item;

  @override
  ConsumerState<AuroraDetailScreen> createState() =>
      _AuroraDetailScreenState();
}

class _AuroraDetailScreenState extends ConsumerState<AuroraDetailScreen> {
  bool _resolving = false;

  StreamItem get item => widget.item;

  Future<void> _play(PlayPreference pref, {double? resumeFraction}) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    try {
      await AuroraPlayback.play(context, ref, item,
          preference: pref, resumeFraction: resumeFraction);
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final margin = Aurora.margin(context);
    final heroH = (size.height * 0.82).clamp(430.0, 860.0);

    final bundle = ref.watch(detailBundleProvider(
        (title: item.name, isShow: item.kind == StreamKind.series)));
    final info = bundle.valueOrNull?.omdb;
    final tmdb = bundle.valueOrNull?.tmdb;
    final loading = bundle.isLoading;
    final favs = ref.watch(favoriteIdsProvider).valueOrNull ?? const <int>{};
    final isFav = item.id != null && favs.contains(item.id);
    final fraction = item.id == null
        ? null
        : ref.watch(progressFractionsProvider).valueOrNull?[item.id];
    final resumable = fraction != null && fraction >= 0.02 && fraction <= 0.97;
    final rdOn = ref.watch(rdEnabledProvider).valueOrNull ?? false;
    final recs = ref
        .watch(auroraRecsProvider(
            (title: cleanTitle(item.name).title, isShow: false)))
        .valueOrNull;

    final backdrop = tmdb?.backdrop ?? info?.poster ?? item.logo;
    final overview = info?.plot ?? tmdb?.overview;
    final title = cleanTitle(item.name).title;
    final meta = <String>[
      if (info?.year != null && info!.year!.isNotEmpty)
        info.year!
      else if (tmdb?.releaseDate != null && tmdb!.releaseDate!.length >= 4)
        tmdb.releaseDate!.substring(0, 4),
      if (info?.rated != null && info!.rated!.isNotEmpty) info.rated!,
      if (info?.runtime != null && info!.runtime!.isNotEmpty)
        info.runtime!
      else if (tmdb?.runtimeMins != null)
        '${tmdb!.runtimeMins} min',
    ];
    final genres = info?.genre?.split(',').map((s) => s.trim()).toList() ??
        tmdb?.genres ??
        const <String>[];
    final posterW = Aurora.posterWidth(context);

    return Scaffold(
      backgroundColor: Aurora.bg,
      body: CustomScrollView(slivers: [
        SliverToBoxAdapter(
          child: SizedBox(
            height: heroH,
            child: Stack(fit: StackFit.expand, children: [
              AuroraImage(
                url: backdrop,
                width: size.width,
                height: heroH,
                radius: 0,
                fallbackText: title,
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0xFF06070B), Color(0xFF06070B), Color(0x0006070B)],
                    stops: [0.0, 0.14, 0.62],
                  ),
                ),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Color(0xD906070B), Color(0x0006070B)],
                    stops: [0.0, 0.65],
                  ),
                ),
              ),
              Positioned(
                top: 18,
                left: margin - 8,
                child: SafeArea(
                  child: AuroraIconButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ),
              Positioned(
                left: margin,
                right: margin,
                bottom: 30,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (genres.isNotEmpty) Eyebrow(genres.take(3).join(' · ')),
                    const SizedBox(height: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: Text(title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: Aurora.display),
                    ),
                    const SizedBox(height: 14),
                    Row(children: [
                      if (loading)
                        const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                      else
                        RatingsStrip(info: info, fallbackRating: item.rating),
                      if (meta.isNotEmpty) ...[
                        const SizedBox(width: 14),
                        Flexible(child: MetaLine(meta)),
                      ],
                    ]),
                    if (resumable) ...[
                      const SizedBox(height: 14),
                      SizedBox(
                        width: 300,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: SizedBox(
                            height: 4,
                            child: Stack(children: [
                              Container(color: const Color(0x33FFFFFF)),
                              FractionallySizedBox(
                                widthFactor: fraction,
                                child: const DecoratedBox(
                                    decoration:
                                        BoxDecoration(gradient: Aurora.gradient)),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    Wrap(spacing: 12, runSpacing: 12, children: [
                      AuroraPillButton(
                        label: _resolving
                            ? 'Finding stream…'
                            : (resumable
                                ? 'Resume · ${(fraction * 100).round()}%'
                                : 'Play'),
                        icon: Icons.play_arrow_rounded,
                        primary: true,
                        autofocus: true,
                        onPressed: () => _play(PlayPreference.auto,
                            resumeFraction: resumable ? fraction : null),
                      ),
                      AuroraPillButton(
                        label: 'Play on IPTV',
                        icon: Icons.live_tv_rounded,
                        onPressed: () => _play(PlayPreference.iptv,
                            resumeFraction: resumable ? fraction : null),
                      ),
                      if (resumable)
                        AuroraPillButton(
                          label: 'From beginning',
                          icon: Icons.replay_rounded,
                          onPressed: () =>
                              _play(PlayPreference.auto, resumeFraction: 0),
                        ),
                      AuroraPillButton(
                        label: isFav ? 'In My List' : 'My List',
                        icon: isFav ? Icons.check_rounded : Icons.add_rounded,
                        onPressed: () => _toggleList(isFav),
                      ),
                    ]),
                    if (rdOn)
                      const Padding(
                        padding: EdgeInsets.only(top: 10),
                        child: Text(
                          'Play uses a smart Real-Debrid stream · switch sources any time in the player',
                          style: Aurora.caption,
                        ),
                      ),
                  ],
                ),
              ),
            ]),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(margin, 6, margin, 0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (overview != null)
                    Text(overview, style: Aurora.body.copyWith(fontSize: 14))
                  else if (!loading)
                    const Text('No description available.',
                        style: TextStyle(color: Aurora.textFaint)),
                  if (tmdb != null && tmdb.cast.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    const Text('Cast', style: Aurora.shelfTitle),
                    const SizedBox(height: 6),
                    Text(tmdb.cast.join(', '), style: Aurora.body),
                  ],
                ],
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: (recs == null || recs.isEmpty)
              ? const SizedBox(height: 48)
              : Padding(
                  padding: const EdgeInsets.only(bottom: 48),
                  child: AuroraShelf<StreamItem>(
                    title: 'More Like This',
                    items: recs,
                    rowHeight: posterW * 1.5 + 56,
                    skeletonWidth: posterW,
                    itemBuilder: (context, it, i) => AuroraPosterCard(
                      item: it,
                      width: posterW,
                      onTap: () => openAuroraItem(context, ref, it),
                    ),
                  ),
                ),
        ),
      ]),
    );
  }

  Future<void> _toggleList(bool isFav) async {
    if (item.id != null) {
      await setFavorite(ref, item, !isFav);
      return;
    }
    // A TMDB-catalog title that isn't matched in the library — resolve the
    // English IPTV match so My List stays library-backed, else say so.
    final messenger = ScaffoldMessenger.of(context);
    final repo = await ref.read(repositoryProvider.future);
    final pl = ref.read(activePlaylistProvider);
    if (pl?.id == null) return;
    final hits = await repo.search(
        playlistId: pl!.id!, kind: item.kind, query: cleanTitle(item.name).title);
    final match = hits.isEmpty ? null : hits.first;
    if (match?.id != null) {
      await setFavorite(ref, match!, true);
      messenger.showSnackBar(const SnackBar(
          backgroundColor: Aurora.bgRaised,
          content:
              Text('Added to My List', style: TextStyle(color: Aurora.text))));
    } else {
      messenger.showSnackBar(const SnackBar(
          backgroundColor: Aurora.bgRaised,
          content: Text('This title isn\'t in your IPTV library.',
              style: TextStyle(color: Aurora.text))));
    }
  }
}
