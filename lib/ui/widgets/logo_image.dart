import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../theme/lumen_theme.dart';

/// Channel/movie artwork. Disk-cached and decoded at a capped resolution so a
/// 40k-channel grid never blows the image cache. Only visible tiles fetch.
class LogoImage extends StatelessWidget {
  const LogoImage({
    super.key,
    required this.url,
    this.size = 56,
    this.radius = 12,
    this.fallbackText,
  });

  final String? url;
  final double size;
  final double radius;
  final String? fallbackText;

  @override
  Widget build(BuildContext context) {
    final placeholder = _Fallback(size: size, radius: radius, text: fallbackText);
    if (url == null || url!.isEmpty) return placeholder;

    final dpr = MediaQuery.of(context).devicePixelRatio;
    final cachePx = (size * dpr).round();

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CachedNetworkImage(
        imageUrl: url!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // Cap decoded size — the killer optimisation for huge libraries.
        memCacheWidth: cachePx,
        memCacheHeight: cachePx,
        fadeInDuration: const Duration(milliseconds: 180),
        placeholder: (_, __) => placeholder,
        errorWidget: (_, __, ___) => placeholder,
      ),
    );
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({required this.size, required this.radius, this.text});
  final double size;
  final double radius;
  final String? text;

  @override
  Widget build(BuildContext context) {
    final initials = (text == null || text!.trim().isEmpty)
        ? '•'
        : text!.trim().characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [LumenTheme.surfaceHi, Color(0xFF222634)],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(
          color: LumenTheme.accent,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.34,
        ),
      ),
    );
  }
}
