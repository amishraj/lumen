import 'package:flutter/material.dart';

import '../../data/sources/omdb_service.dart';
import '../aurora_theme.dart';

/// Small uppercase eyebrow ("TRENDING THIS WEEK") above hero titles.
class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 2.4,
        color: Aurora.accent,
      ),
    );
  }
}

/// "2023 · R · 1h 58m · Sci-Fi" — one quiet dot-separated metadata line.
class MetaLine extends StatelessWidget {
  const MetaLine(this.parts, {super.key, this.fontSize = 13});
  final List<String> parts;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final visible = parts.where((p) => p.trim().isNotEmpty).toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return Text(
      visible.join('   ·   '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: fontSize,
        fontWeight: FontWeight.w500,
        color: Aurora.textDim,
        letterSpacing: 0.2,
      ),
    );
  }
}

/// IMDb-branded rating chip.
class ImdbChip extends StatelessWidget {
  const ImdbChip(this.rating, {super.key, this.large = false});
  final double rating;
  final bool large;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        padding: EdgeInsets.symmetric(horizontal: large ? 6 : 4.5, vertical: 1.5),
        decoration: BoxDecoration(
          color: const Color(0xFFF5C518),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text('IMDb',
            style: TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.w900,
                fontSize: large ? 10.5 : 8.5,
                letterSpacing: -0.2)),
      ),
      const SizedBox(width: 5),
      Text(rating.toStringAsFixed(1),
          style: TextStyle(
              color: Aurora.text,
              fontSize: large ? 13 : 11.5,
              fontWeight: FontWeight.w700)),
    ]);
  }
}

/// Full ratings strip from OMDb (IMDb / Rotten Tomatoes / Metacritic),
/// rendered as quiet glass chips so they sit calmly over artwork.
class RatingsStrip extends StatelessWidget {
  const RatingsStrip({super.key, required this.info, this.fallbackRating});
  final OmdbInfo? info;
  final double? fallbackRating;

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[];
    final i = info;
    if (i?.imdb != null) {
      chips.add(ImdbChip(double.tryParse(i!.imdb!) ?? 0, large: true));
    } else if (fallbackRating != null && fallbackRating! > 0) {
      chips.add(ImdbChip(fallbackRating!, large: true));
    }
    if (i?.rotten != null) {
      chips.add(_glass('🍅 ${i!.rotten!}'));
    }
    if (i?.metacritic != null) {
      chips.add(_glass('MC ${i!.metacritic!.split('/').first}'));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 14,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: chips,
    );
  }

  Widget _glass(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Aurora.glass,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Aurora.hairline),
        ),
        child: Text(label,
            style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: Aurora.text)),
      );
}

/// The red LIVE pill.
class LiveBadge extends StatelessWidget {
  const LiveBadge({super.key, this.small = false});
  final bool small;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: small ? 7 : 9, vertical: small ? 2.5 : 3.5),
      decoration: BoxDecoration(
        color: Aurora.live,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: small ? 5 : 6,
          height: small ? 5 : 6,
          decoration: const BoxDecoration(
              color: Colors.white, shape: BoxShape.circle),
        ),
        SizedBox(width: small ? 4 : 5),
        Text('LIVE',
            style: TextStyle(
                color: Colors.white,
                fontSize: small ? 9.5 : 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8)),
      ]),
    );
  }
}

/// "IPTV" tag for live-channel listings, so a channel is never mistaken for a
/// VOD movie/show when it turns up in mixed rails (search, favorites, results).
/// Quiet glass pill with a broadcast glyph — distinct from the red LIVE badge,
/// which means "airing now"; this simply marks the *kind*.
class IptvBadge extends StatelessWidget {
  const IptvBadge({super.key, this.small = false});
  final bool small;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: small ? 5 : 6.5, vertical: small ? 2 : 3),
      decoration: BoxDecoration(
        color: const Color(0xCC06070B),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: Aurora.hairline),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.podcasts_rounded,
            size: small ? 9 : 10.5, color: Aurora.accent),
        SizedBox(width: small ? 3 : 4),
        Text('IPTV',
            style: TextStyle(
                color: Aurora.text,
                fontSize: small ? 8.5 : 9.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6)),
      ]),
    );
  }
}

/// Thin watch-progress bar along a card's bottom edge.
class ProgressStripe extends StatelessWidget {
  const ProgressStripe({super.key, required this.fraction, this.height = 4});
  final double fraction;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (fraction < 0.02 || fraction > 0.97) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        height: height,
        color: const Color(0x66000000),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: fraction.clamp(0.0, 1.0),
          child: const DecoratedBox(
              decoration: BoxDecoration(gradient: Aurora.gradient)),
        ),
      ),
    );
  }
}

/// Check-mark "seen" marker on watched artwork.
class SeenBadge extends StatelessWidget {
  const SeenBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 8,
      right: 8,
      child: Container(
        padding: const EdgeInsets.all(3.5),
        decoration: const BoxDecoration(
          color: Color(0xE6FFFFFF),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.check_rounded, size: 12, color: Aurora.bg),
      ),
    );
  }
}
