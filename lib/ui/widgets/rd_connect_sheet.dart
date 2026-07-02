import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/sources/realdebrid_service.dart';
import '../../state/service_status.dart';
import '../theme/lumen_theme.dart';

/// Trakt-style "enter a code" connect flow for Real-Debrid. Shows a short
/// code, opens real-debrid.com/device in the browser, and polls until the
/// user authorizes. Resolves true when connected.
Future<bool> showRdConnectSheet(BuildContext context, WidgetRef ref) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: const Color(0xFF15171F),
    isDismissible: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => const _RdConnectSheet(),
  );
  if (ok == true) {
    ref.read(rdRevProvider.notifier).state++;
    ref.invalidate(rdEnabledProvider);
    ref.invalidate(serviceHealthProvider);
  }
  return ok == true;
}

class _RdConnectSheet extends ConsumerStatefulWidget {
  const _RdConnectSheet();

  @override
  ConsumerState<_RdConnectSheet> createState() => _RdConnectSheetState();
}

class _RdConnectSheetState extends ConsumerState<_RdConnectSheet> {
  RdDeviceCode? _code;
  String? _error;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _polling = false;
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final svc = await ref.read(realDebridServiceProvider.future);
      final code = await svc.requestDeviceCode();
      if (!mounted) return;
      setState(() {
        _code = code;
        _polling = true;
      });
      // Kodi-style: open the activation page for the user.
      final uri = Uri.tryParse(code.verificationUrl);
      if (uri != null) {
        unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
      }
      _poll(svc, code);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _poll(RealDebridService svc, RdDeviceCode code) async {
    final deadline = DateTime.now().add(Duration(seconds: code.expiresInSecs));
    while (_polling && mounted && DateTime.now().isBefore(deadline)) {
      await Future.delayed(Duration(seconds: code.intervalSecs));
      if (!mounted || !_polling) return;
      try {
        if (await svc.pollDeviceAuth(code.deviceCode)) {
          if (mounted) Navigator.of(context).pop(true);
          return;
        }
      } catch (_) {/* transient — keep polling until the deadline */}
    }
    if (mounted && _polling) {
      setState(() {
        _polling = false;
        _error = 'The code expired — try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(children: [
              Icon(Icons.cloud_outlined, color: Color(0xFF35C759), size: 22),
              SizedBox(width: 10),
              Text('Connect Real-Debrid',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 8),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Color(0xFF9AA0B0)))
            else if (code == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                    child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2))),
              )
            else ...[
              Text('Go to ${code.verificationUrl} and enter:',
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: Color(0xFF9AA0B0), fontSize: 13)),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: () =>
                    Clipboard.setData(ClipboardData(text: code.userCode)),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: LumenTheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: LumenTheme.accent.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    code.userCode,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 5,
                        color: LumenTheme.accent),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text('Tap the code to copy · waiting for authorization…',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF6B7080), fontSize: 11.5)),
            ],
            const SizedBox(height: 14),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}
