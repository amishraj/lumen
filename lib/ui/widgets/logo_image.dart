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
    double? height,
    this.radius = 12,
    this.fallbackText,
  }) : height = height ?? size;

  final String? url;
  final double size; // width
  final double height;
  final double radius;
  final String? fallbackText;

  @override
  Widget build(BuildContext context) {
    final placeholder =
        _Fallback(width: size, height: height, radius: radius, text: fallbackText);
    if (url == null || url!.isEmpty) return placeholder;

    final dpr = MediaQuery.of(context).devicePixelRatio;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CachedNetworkImage(
        imageUrl: url!,
        width: size,
        height: height,
        fit: BoxFit.cover,
        // Cap decoded size — the killer optimisation for huge libraries.
        memCacheWidth: (size * dpr).round(),
        memCacheHeight: (height * dpr).round(),
        fadeInDuration: const Duration(milliseconds: 180),
        placeholder: (_, __) => placeholder,
        errorWidget: (_, __, ___) => placeholder,
      ),
    );
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback(
      {required this.width, required this.height, required this.radius, this.text});
  final double width;
  final double height;
  final double radius;
  final String? text;

  @override
  Widget build(BuildContext context) {
    final initials = (text == null || text!.trim().isEmpty)
        ? '•'
        : text!.trim().characters.first.toUpperCase();
    return Container(
      width: width,
      height: height,
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
          fontSize: width * 0.34,
        ),
      ),
    );
  }
}
