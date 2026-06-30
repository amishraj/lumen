import 'package:flutter/material.dart';

import '../../data/models/models.dart';
import '../theme/lumen_theme.dart';
import 'logo_image.dart';

/// A Netflix-style poster tile used in horizontal home rows. Lightweight: fixed
/// size, const children, downscaled cached art.
class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.item,
    required this.onTap,
    this.width = 124,
  });

  final StreamItem item;
  final VoidCallback onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    // Live channels look better square; movies/series as 2:3 posters.
    final isPoster = item.kind != StreamKind.live;
    final height = isPoster ? width * 1.5 : width;

    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LogoImage(
              url: item.logo,
              size: width,
              height: height,
              radius: 14,
              fallbackText: item.name,
            ),
            const SizedBox(height: 6),
            Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
            if (item.rating != null && item.rating! > 0)
              Row(children: [
                const Icon(Icons.star_rounded, size: 12, color: LumenTheme.accentWarm),
                const SizedBox(width: 2),
                Text(item.rating!.toStringAsFixed(1),
                    style: const TextStyle(fontSize: 11, color: Color(0xFF9AA0B0))),
              ]),
          ],
        ),
      ),
    );
  }
}
