import 'package:flutter/material.dart';

import '../../data/models/models.dart';
import '../theme/lumen_theme.dart';
import 'focusable_item.dart';
import 'logo_image.dart';

/// A single row in the channel/movie list. Deliberately lightweight — const
/// where possible and no per-frame work — so 60fps holds while flinging.
class ChannelTile extends StatelessWidget {
  const ChannelTile({
    super.key,
    required this.item,
    required this.onTap,
    this.onFavorite,
    this.isFavorite = false,
    this.nowTitle,
  });

  final StreamItem item;
  final VoidCallback onTap;
  final VoidCallback? onFavorite;
  final bool isFavorite;
  final String? nowTitle;

  @override
  Widget build(BuildContext context) {
    return FocusableItem(
      onActivate: onTap,
      borderRadius: 16,
      builder: (context, focused) => Material(
        color: focused ? LumenTheme.surfaceHi : Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              LogoImage(url: item.logo, size: 52, fallbackText: item.name),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                    if (nowTitle != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        nowTitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFF9AA0B0),
                          fontSize: 12.5,
                        ),
                      ),
                    ] else if (item.num != null) ...[
                      const SizedBox(height: 3),
                      Text('#${item.num}',
                          style: const TextStyle(
                              color: Color(0xFF6B7080), fontSize: 12)),
                    ],
                  ],
                ),
              ),
              if (onFavorite != null)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    isFavorite ? Icons.favorite : Icons.favorite_border,
                    color: isFavorite ? LumenTheme.accentWarm : const Color(0xFF6B7080),
                    size: 20,
                  ),
                  onPressed: onFavorite,
                ),
              const Icon(Icons.play_circle_fill,
                  color: LumenTheme.accent, size: 26),
            ],
          ),
          ),
        ),
      ),
    );
  }
}
