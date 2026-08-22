import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// What kind of machine is this, really.
///
/// Screen size cannot answer it. A 1080p TV at density 2.0 reports 960x540dp,
/// and a shortest side of 540 reads as "phone" to any width test — which is
/// how the player's lock button and brightness rail, both gated on
/// `shortestSide < 760`, ended up on the television. `defaultTargetPlatform`
/// cannot answer it either: a TV box is plain `TargetPlatform.android`.
///
/// So the platform is asked once, at startup, over a method channel (see
/// `MainActivity.kt`), and the answer is cached for the life of the process.
/// Everything that means "hide this on a TV" reads [isTv]; everything that
/// means "this is a hand-held touch device" reads [isHandheld].
class DeviceClass {
  DeviceClass._();

  static const _channel = MethodChannel('org.lumen.lumen/device');

  /// True on Android TV / Google TV / Fire TV. False everywhere else,
  /// including before [init] has run — so a control that is *hidden* on TV
  /// never flashes into view on one.
  static bool isTv = false;

  /// A phone or tablet: a touch device you hold. This is what gates the
  /// controls that only make sense in the hand — screen lock, the brightness
  /// rail — and it is deliberately NOT a width test, so a landscape phone
  /// keeps them and a TV never gets them.
  static bool get isHandheld =>
      !isTv && (Platform.isAndroid || Platform.isIOS);

  /// Resolve the device class. Cheap (one platform call) and safe to await
  /// before the first frame; any failure leaves [isTv] false, which is the
  /// conservative answer for a phone-shaped device.
  static Future<void> init() async {
    if (!Platform.isAndroid) return;
    try {
      isTv = await _channel.invokeMethod<bool>('isTv') ?? false;
    } catch (_) {
      // Older build of the app's own activity, or the channel is missing:
      // fall back to the one signal Flutter does expose. A TV is landscape
      // and large in physical terms; this is a worse test than the platform's
      // own, which is why it is only the fallback.
      isTv = false;
    }
  }

  /// Fallback used only when the platform channel could not answer: a very
  /// wide, short viewport is far more likely to be a TV than a hand-held.
  /// Kept separate so the primary path stays honest about what it knows.
  static bool looksLikeTv(BuildContext context) {
    if (isTv) return true;
    if (!Platform.isAndroid) return false;
    final size = MediaQueryData.fromView(View.of(context)).size;
    return size.width >= 900 && size.width / size.height >= 1.6;
  }

  @visibleForTesting
  static void overrideForTest({required bool tv}) => isTv = tv;
}
