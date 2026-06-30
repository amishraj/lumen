import 'package:flutter/material.dart';

import '../../data/sources/omdb_service.dart';

/// IMDb / Rotten Tomatoes / Metacritic badges from OMDb, styled like the
/// source brands. Renders nothing until metadata resolves.
class RatingBadges extends StatelessWidget {
  const RatingBadges({super.key, required this.info});
  final OmdbInfo? info;

  @override
  Widget build(BuildContext context) {
    final i = info;
    if (i == null) return const SizedBox.shrink();
    final badges = <Widget>[];
    if (i.imdb != null) {
      badges.add(_badge(const Color(0xFFF5C518), 'IMDb', i.imdb!, Colors.black));
    }
    if (i.rotten != null) {
      badges.add(_badge(const Color(0xFFFA320A), '🍅', i.rotten!, Colors.white));
    }
    if (i.metacritic != null) {
      badges.add(_badge(const Color(0xFF00CE7A), 'MC', i.metacritic!.split('/').first, Colors.black));
    }
    if (badges.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 8, runSpacing: 8, children: badges);
  }

  Widget _badge(Color bg, String label, String value, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 11)),
          const SizedBox(width: 5),
          Text(value,
              style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 12)),
        ],
      ),
    );
  }
}
