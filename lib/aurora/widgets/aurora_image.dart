import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../data/image_cache.dart';
import '../aurora_theme.dart';

/// Artwork with Aurora's loading/fallback treatment. Same performance rules
/// as the classic LogoImage: disk cache, width-capped decode, fade-in — the
/// discipline that lets a 40k library scroll at 60fps.
class AuroraImage extends StatelessWidget {
  const AuroraImage({
    super.key,
    required this.url,
    required this.width,
    required this.height,
    this.radius = 12,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.fallbackText,
  });

  final String? url;
  final double width;
  final double height;
  final double radius;
  final BoxFit fit;

  /// Which part of the image survives the [fit] crop. Defaults to centre;
  /// tall heroes anchor to the top so faces aren't trimmed away.
  final Alignment alignment;
  final String? fallbackText;

  @override
  Widget build(BuildContext context) {
    final fallback = _Fallback(
        width: width, height: height, radius: radius, text: fallbackText);
    final loading = _Loading(width: width, height: height, radius: radius);
    if (url == null || url!.isEmpty) return fallback;
    final media = MediaQuery.of(context);
    final dpr = media.devicePixelRatio;
    // `width` is often `double.infinity` (a fill-the-Stack banner). Rounding
    // Infinity throws — which took the whole hero subtree down with it, and is
    // exactly why the phone billboard rendered nothing in portrait while the
    // landscape hero (which passes a real width) was fine. Fall back to the
    // screen width for the decode cap in that case.
    final decodeW = width.isFinite ? width : media.size.width;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CachedNetworkImage(
        imageUrl: url!,
        cacheManager: LumenImageCache.instance,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
        // Width-only cap: keeps aspect, BoxFit crops instead of stretching.
        memCacheWidth: (decodeW * dpr).round(),
        fadeInDuration: const Duration(milliseconds: 220),
        placeholder: (_, __) => loading,
        errorWidget: (_, __, ___) => fallback,
      ),
    );
  }
}

/// The exact [ImageProvider] [AuroraImage] renders [url] with, at the decode
/// cap it would use for a card/hero [width] logical pixels wide.
///
/// Exists because warming artwork through a bare `CachedNetworkImageProvider`
/// is *worse* than not warming it at all. `memCacheWidth` compiles down to a
/// [ResizeImage] wrapper (via octo_image), and ResizeImage is a different
/// [ImageCache] key from the provider it wraps — so a precache with the raw
/// provider decoded a second, FULL-resolution copy of the image that nothing
/// ever drew, then held it live. On the home hero deck that was several MB of
/// dead pixels per backdrop, allocated at exactly the moment the app is trying
/// to paint its first frame on a memory-starved TV box.
ImageProvider auroraImageProvider(
  BuildContext context,
  String url, {
  required double width,
}) {
  final media = MediaQuery.of(context);
  final decodeW = width.isFinite ? width : media.size.width;
  return ResizeImage.resizeIfNeeded(
    (decodeW * media.devicePixelRatio).round(),
    null,
    CachedNetworkImageProvider(url, cacheManager: LumenImageCache.instance),
  );
}

/// Warm [url] into the image cache under the key [AuroraImage] will look it up
/// by, so the warm-up is actually the copy that gets drawn. No-op for a null or
/// empty url.
Future<void> precacheAuroraImage(
  BuildContext context,
  String? url, {
  required double width,
}) {
  if (url == null || url.isEmpty) return Future<void>.value();
  return precacheImage(
      auroraImageProvider(context, url, width: width), context,
      onError: (_, __) {/* a cold backdrop just loads late — never throw */});
}

/// A dark tile that *contains* a channel logo (IPTV logos are transparent
/// glyphs that must never be cropped) with a soft radial glow behind it.
class AuroraLogoTile extends StatelessWidget {
  const AuroraLogoTile({
    super.key,
    required this.url,
    required this.width,
    required this.height,
    this.radius = 12,
    this.fallbackText,
    this.borderColor,
  });

  final String? url;
  final double width;
  final double height;
  final double radius;
  final String? fallbackText;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final dpr = media.devicePixelRatio;
    final decodeW = width.isFinite ? width : media.size.width;
    return Container(
      width: width,
      height: height,
      padding: EdgeInsets.all(width * 0.11),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor ?? Aurora.hairline),
        gradient: const RadialGradient(
          center: Alignment(0, -0.4),
          radius: 1.4,
          colors: [Color(0xFF171B27), Color(0xFF0A0C12)],
        ),
      ),
      child: (url == null || url!.isEmpty)
          ? _glyph(fallbackText)
          : CachedNetworkImage(
              imageUrl: url!,
              cacheManager: LumenImageCache.instance,
              fit: BoxFit.contain,
              memCacheWidth: (decodeW * dpr).round(),
              fadeInDuration: const Duration(milliseconds: 200),
              placeholder: (_, __) => const SizedBox.expand(),
              errorWidget: (_, __, ___) => _glyph(fallbackText),
            ),
    );
  }

  Widget _glyph(String? text) => Center(
        child: Text(
          (text == null || text.trim().isEmpty)
              ? '•'
              : text.trim().characters.first.toUpperCase(),
          style: TextStyle(
            fontSize: width * 0.24,
            fontWeight: FontWeight.w800,
            foreground: Paint()
              ..shader =
                  Aurora.gradient.createShader(Rect.fromLTWH(0, 0, width, 40)),
          ),
        ),
      );
}

class _Loading extends StatelessWidget {
  const _Loading({required this.width, required this.height, required this.radius});
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFF10131C),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback(
      {required this.width,
      required this.height,
      required this.radius,
      this.text});
  final double width;
  final double height;
  final double radius;
  final String? text;

  @override
  Widget build(BuildContext context) {
    final initial = (text == null || text!.trim().isEmpty)
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
          colors: [Color(0xFF141827), Color(0xFF0B0D14)],
        ),
        border: Border.all(color: Aurora.hairline),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: Aurora.textFaint,
          fontWeight: FontWeight.w800,
          fontSize: (width * 0.3).clamp(14.0, 44.0),
        ),
      ),
    );
  }
}
