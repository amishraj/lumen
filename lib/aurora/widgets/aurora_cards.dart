import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import '../../ui/title_utils.dart';
import '../aurora_focus.dart';
import '../aurora_theme.dart';
import 'aurora_badges.dart';
import 'aurora_image.dart';

/// 2:3 poster card — the default card for movies & shows. Title sits under
/// the art (IPTV libraries are full of missing/typographic posters, so a
/// naked grid would be unbrowsable). Watched/progress overlays included.
class AuroraPosterCard extends ConsumerWidget {
  const AuroraPosterCard({
    super.key,
    required this.item,
    required this.onTap,
    required this.width,
    this.autofocus = false,
    this.showSourceBadge = false,
  });

  final StreamItem item;
  final VoidCallback onTap;
  final double width;
  final bool autofocus;

  /// Mark where this entry plays from (search results): "IPTV" for library
  /// items; items without a library id play via debrid and stay unbadged.
  final bool showSourceBadge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final h = width * 1.5;
    final watched = item.id != null &&
        (ref.watch(watchedIdsProvider).valueOrNull?.contains(item.id) ?? false);
    final fraction = item.id == null
        ? null
        : ref.watch(progressFractionsProvider).valueOrNull?[item.id];
    final parts = item.kind == StreamKind.live
        ? TitleParts(item.name, null)
        : cleanTitle(item.name);

    return AuroraFocusable(
      autofocus: autofocus,
      onActivate: onTap,
      radius: 12,
      scale: 1.07,
      builder: (context, focused) => SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(children: [
              AuroraImage(
                url: item.logo,
                width: width,
                height: h,
                radius: 12,
                fallbackText: parts.title,
              ),
              if (item.kind == StreamKind.live ||
                  (showSourceBadge && item.id != null))
                const Positioned(top: 8, left: 8, child: IptvBadge()),
              // Watched and in-progress are mutually exclusive: a finished item
              // shows the check (saveProgress marks watched at ≥90%, so its
              // stored fraction would otherwise also paint a ~90% stripe —
              // never both), an unfinished one shows the progress stripe.
              if (watched)
                const SeenBadge()
              else if (fraction != null)
                ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(bottom: Radius.circular(12)),
                  child: SizedBox(
                      width: width,
                      height: h,
                      child: Stack(children: [
                        ProgressStripe(fraction: fraction),
                      ])),
                ),
            ]),
            const SizedBox(height: 7),
            Text(
              parts.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: focused ? Aurora.text : Aurora.textDim,
              ),
            ),
            if (item.rating != null && item.rating! > 0) ...[
              const SizedBox(height: 3),
              ImdbChip(item.rating!),
            ],
          ],
        ),
      ),
    );
  }
}

/// 16:9 landscape card with the title set inside on a legibility gradient —
/// used for Continue Watching, trending and editorial rows. Shows a Resume
/// affordance when the item has partial progress and holds focus.
class AuroraWideCard extends ConsumerWidget {
  const AuroraWideCard({
    super.key,
    required this.item,
    required this.onTap,
    required this.width,
    this.autofocus = false,
  });

  final StreamItem item;
  final VoidCallback onTap;
  final double width;
  final bool autofocus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final h = width * 9 / 16;
    final watched = item.id != null &&
        (ref.watch(watchedIdsProvider).valueOrNull?.contains(item.id) ?? false);
    final fraction = item.id == null
        ? null
        : ref.watch(progressFractionsProvider).valueOrNull?[item.id];
    final parts = cleanTitle(item.name);
    // A finished item never offers "Resume" — watched wins over a stale
    // ≥90% resume point (see AuroraPosterCard).
    final resumable =
        !watched && fraction != null && fraction >= 0.02 && fraction <= 0.97;

    return AuroraFocusable(
      autofocus: autofocus,
      onActivate: onTap,
      radius: 12,
      scale: 1.06,
      builder: (context, focused) => SizedBox(
        width: width,
        height: h,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(fit: StackFit.expand, children: [
            AuroraImage(
              url: item.logo,
              width: width,
              height: h,
              radius: 0,
              fallbackText: parts.title,
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xCC05060A), Colors.transparent],
                  stops: [0.0, 0.62],
                ),
              ),
            ),
            Positioned(
              left: 11,
              right: 11,
              bottom: 9,
              child: Row(children: [
                Expanded(
                  child: Text(parts.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700)),
                ),
                if (item.rating != null && item.rating! > 0) ...[
                  const SizedBox(width: 8),
                  ImdbChip(item.rating!),
                ],
              ]),
            ),
            // Resume affordance while focused.
            if (resumable)
              AnimatedOpacity(
                duration: Aurora.fast,
                opacity: focused ? 1 : 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 7),
                    decoration: BoxDecoration(
                      color: const Color(0xD9FFFFFF),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.play_arrow_rounded,
                          size: 17, color: Aurora.bg),
                      const SizedBox(width: 4),
                      Text('Resume · ${(fraction * 100).round()}%',
                          style: const TextStyle(
                              color: Aurora.bg,
                              fontSize: 12,
                              fontWeight: FontWeight.w800)),
                    ]),
                  ),
                ),
              ),
            if (item.kind == StreamKind.live)
              const Positioned(top: 8, left: 8, child: IptvBadge()),
            if (watched)
              const SeenBadge()
            else if (fraction != null)
              ProgressStripe(fraction: fraction),
          ]),
        ),
      ),
    );
  }
}

/// Live-channel card: contained logo on a dark tile, channel number + name
/// beneath. Never crops logos.
class AuroraLiveCard extends StatelessWidget {
  const AuroraLiveCard({
    super.key,
    required this.item,
    required this.onTap,
    required this.width,
    this.autofocus = false,
  });

  final StreamItem item;
  final VoidCallback onTap;
  final double width;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final h = width * 9 / 16;
    return AuroraFocusable(
      autofocus: autofocus,
      onActivate: onTap,
      radius: 12,
      scale: 1.06,
      builder: (context, focused) => SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(children: [
              AuroraLogoTile(
                url: item.logo,
                width: width,
                height: h,
                radius: 12,
                fallbackText: item.name,
                borderColor: focused ? Colors.transparent : null,
              ),
              const Positioned(top: 7, left: 7, child: IptvBadge(small: true)),
            ]),
            const SizedBox(height: 7),
            Row(children: [
              if (item.num != null) ...[
                Text('${item.num}',
                    style: const TextStyle(
                        color: Aurora.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w800)),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: focused ? Aurora.text : Aurora.textDim)),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
