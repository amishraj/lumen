import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import '../theme/lumen_theme.dart';
import '../title_utils.dart';
import 'focusable_item.dart';
import 'imdb_badge.dart';
import 'logo_image.dart';

/// A Netflix-style tile used in horizontal home rows. Two shapes:
/// - portrait 2:3 poster (default)
/// - [wide]: 16:9 landscape card with a gradient + title overlay that
///   *expands* when hovered (mouse) or focused (remote/D-pad).
///
/// Kept deliberately lightweight — fixed size, const children, downscaled
/// cached art — so long rows fling at 60fps.
class PosterCard extends ConsumerStatefulWidget {
  const PosterCard({
    super.key,
    required this.item,
    required this.onTap,
    this.width = 124,
    this.wide = false,
    this.live = false,
  });

  final StreamItem item;
  final VoidCallback onTap;
  final double width;
  final bool wide;
  final bool live; // live-TV styled card (channel logo + name, not a poster)

  @override
  ConsumerState<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends ConsumerState<PosterCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final watched = item.id != null &&
        (ref.watch(watchedIdsProvider).valueOrNull?.contains(item.id) ?? false);
    final fraction = item.id == null
        ? null
        : ref.watch(progressFractionsProvider).valueOrNull?[item.id];

    if (widget.live) return _buildLive();
    if (widget.wide) return _buildWide(watched, fraction);

    // Live channels look better square; movies/series as 2:3 posters.
    final isPoster = item.kind != StreamKind.live;
    final height = isPoster ? widget.width * 1.5 : widget.width;

    return FocusableItem(
      onActivate: widget.onTap,
      builder: (context, focused) => MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedScale(
          scale: _hover ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          child: SizedBox(
            width: widget.width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    LogoImage(
                      url: item.logo,
                      size: widget.width,
                      height: height,
                      radius: 14,
                      fallbackText: item.name,
                    ),
                    if (watched) const _SeenBadge(),
                    if (fraction != null) _ProgressStripe(fraction: fraction),
                  ],
                ),
                const SizedBox(height: 6),
                _TitleLine(item: item, light: false),
                if (item.rating != null && item.rating! > 0) ...[
                  const SizedBox(height: 2),
                  ImdbBadge(rating: item.rating!),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 16:9 landscape card, title overlaid on a bottom gradient, expands on
  /// hover/focus like modern streaming apps.
  Widget _buildWide(bool watched, double? fraction) {
    final item = widget.item;
    final w = widget.width * 1.9; // 16:9-ish footprint for the same row height
    final h = w * 9 / 16;

    return FocusableItem(
      onActivate: widget.onTap,
      borderRadius: 16,
      builder: (context, focused) => MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedScale(
          scale: (_hover || focused) ? 1.08 : 1.0,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: SizedBox(
            width: w,
            height: h,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  LogoImage(
                    url: item.logo,
                    size: w,
                    height: h,
                    radius: 0,
                    fallbackText: item.name,
                  ),
                  // Legibility gradient behind the title.
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Color(0xCC000000), Colors.transparent],
                        stops: [0.0, 0.55],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 10,
                    right: 10,
                    bottom: 8,
                    child: Row(
                      children: [
                        Expanded(child: _TitleLine(item: item, light: true)),
                        if (item.rating != null && item.rating! > 0) ...[
                          const SizedBox(width: 6),
                          ImdbBadge(rating: item.rating!),
                        ],
                      ],
                    ),
                  ),
                  if (watched) const _SeenBadge(),
                  if (fraction != null) _ProgressStripe(fraction: fraction),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Live-TV card: a 16:9 dark tile with the channel's own logo centered
  /// (contained, not cropped — IPTV logos are transparent glyphs) and the
  /// channel name + number below. Distinct from movie/show posters.
  Widget _buildLive() {
    final item = widget.item;
    final w = widget.width * 1.55;
    final h = w * 9 / 16;
    return FocusableItem(
      onActivate: widget.onTap,
      borderRadius: 14,
      builder: (context, focused) => MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedScale(
          scale: (_hover || focused) ? 1.06 : 1.0,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: SizedBox(
            width: w,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: w,
                  height: h,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF1C1F29), Color(0xFF0F1116)],
                    ),
                    border: Border.all(
                        color: focused
                            ? LumenTheme.accent
                            : const Color(0xFF2A2E3A),
                        width: focused ? 2 : 1),
                  ),
                  padding: const EdgeInsets.all(14),
                  child: (item.logo != null && item.logo!.isNotEmpty)
                      ? Image.network(item.logo!,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => _liveGlyph(item.name))
                      : _liveGlyph(item.name),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (item.num != null) ...[
                      Text('${item.num}',
                          style: const TextStyle(
                              color: LumenTheme.accent,
                              fontSize: 11,
                              fontWeight: FontWeight.w800)),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _liveGlyph(String name) => Center(
        child: Text(
          name.trim().isEmpty
              ? '•'
              : name.trim().characters.first.toUpperCase(),
          style: const TextStyle(
              color: LumenTheme.accent,
              fontSize: 34,
              fontWeight: FontWeight.w800),
        ),
      );
}

/// Thin resume-progress bar along the bottom edge of the artwork — the
/// familiar streaming-app cue for partially watched content.
class _ProgressStripe extends StatelessWidget {
  const _ProgressStripe({required this.fraction});
  final double fraction;

  @override
  Widget build(BuildContext context) {
    // Skip barely-started and effectively-finished content.
    if (fraction < 0.02 || fraction > 0.97) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
        child: SizedBox(
          height: 4,
          child: Row(
            children: [
              Expanded(
                flex: (fraction * 1000).round(),
                child: const ColoredBox(color: LumenTheme.accent),
              ),
              Expanded(
                flex: ((1 - fraction) * 1000).round(),
                child: const ColoredBox(color: Color(0x66000000)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SeenBadge extends StatelessWidget {
  const _SeenBadge();
  @override
  Widget build(BuildContext context) => Positioned(
        top: 6,
        right: 6,
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: const BoxDecoration(
            color: LumenTheme.accent,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.check, size: 13, color: Color(0xFF0A0B0F)),
        ),
      );
}

/// Cleaned title with an optional small language chip ("EN"). Live channels
/// keep their raw provider names — cleanup is for movies/shows only.
class _TitleLine extends StatelessWidget {
  const _TitleLine({required this.item, required this.light});
  final StreamItem item;
  final bool light;

  @override
  Widget build(BuildContext context) {
    final isVod = item.kind != StreamKind.live;
    final parts = isVod ? cleanTitle(item.name) : TitleParts(item.name, null);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (parts.lang != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: LumenTheme.accent.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(parts.lang!,
                style: const TextStyle(
                    color: LumenTheme.accent,
                    fontSize: 9,
                    fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 5),
        ],
        Flexible(
          child: Text(
            parts.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: light ? Colors.white : null,
                fontSize: 12.5,
                fontWeight: light ? FontWeight.w700 : FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
