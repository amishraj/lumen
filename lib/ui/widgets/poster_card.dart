import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import '../theme/lumen_theme.dart';
import 'focusable_item.dart';
import 'logo_image.dart';

/// A Netflix-style poster tile used in horizontal home rows. Lightweight: fixed
/// size, const children, downscaled cached art. Shows a "seen" check for items
/// watched locally or on Trakt.
class PosterCard extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    // Live channels look better square; movies/series as 2:3 posters.
    final isPoster = item.kind != StreamKind.live;
    final height = isPoster ? width * 1.5 : width;
    final watched = item.id != null &&
        (ref.watch(watchedIdsProvider).valueOrNull?.contains(item.id) ?? false);

    return FocusableItem(
      onActivate: onTap,
      builder: (context, focused) => SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                LogoImage(
                  url: item.logo,
                  size: width,
                  height: height,
                  radius: 14,
                  fallbackText: item.name,
                ),
                if (watched)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: const BoxDecoration(
                        color: LumenTheme.accent,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.check,
                          size: 13, color: Color(0xFF0A0B0F)),
                    ),
                  ),
              ],
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
