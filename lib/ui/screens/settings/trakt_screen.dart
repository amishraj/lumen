import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/sources/trakt_service.dart';
import '../../../state/providers.dart';
import '../../theme/lumen_theme.dart';
import '../../widgets/tv_text_field.dart';

/// Connect a Trakt account via the OAuth device flow.
class TraktScreen extends ConsumerStatefulWidget {
  const TraktScreen({super.key});

  @override
  ConsumerState<TraktScreen> createState() => _TraktScreenState();
}

class _TraktScreenState extends ConsumerState<TraktScreen> {
  final _idCtl = TextEditingController();
  final _secretCtl = TextEditingController();
  TraktDeviceCode? _code;
  String? _status;
  bool _polling = false;
  bool _embedded = false;

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  Future<void> _prefill() async {
    final svc = await ref.read(traktServiceProvider.future);
    final id = await svc.getClientIdForUi();
    if (!mounted) return;
    setState(() => _embedded = svc.hasEmbeddedCredentials);
    if (id != null && !_embedded) _idCtl.text = id;
  }

  @override
  void dispose() {
    _idCtl.dispose();
    _secretCtl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final svc = await ref.read(traktServiceProvider.future);
    if (!_embedded) {
      await svc.saveCredentials(_idCtl.text, _secretCtl.text);
    }
    try {
      final code = await svc.requestDeviceCode();
      setState(() {
        _code = code;
        _status = 'Enter the code at ${code.verificationUrl}';
        _polling = true;
      });
      // Kodi-style: pop the activation page straight into the browser.
      final uri = Uri.tryParse(code.verificationUrl);
      if (uri != null) {
        unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
      }
      _poll(svc, code);
    } catch (e) {
      setState(() => _status = '$e');
    }
  }

  Future<void> _poll(TraktService svc, TraktDeviceCode code) async {
    final deadline = DateTime.now().add(Duration(seconds: code.expiresInSecs));
    while (_polling && mounted && DateTime.now().isBefore(deadline)) {
      await Future.delayed(Duration(seconds: code.intervalSecs));
      if (!mounted || !_polling) return;
      try {
        final ok = await svc.pollToken(code.deviceCode);
        if (ok) {
          // Home data is session-cached — refresh everything Trakt-backed so
          // the home screen reflects the new account immediately.
          refreshTraktData(ref);
          if (mounted) {
            setState(() {
              _polling = false;
              _code = null;
              _status = 'Connected!';
            });
          }
          return;
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _polling = false;
            _status = '$e';
          });
        }
        return;
      }
    }
    if (mounted) setState(() => _polling = false);
  }

  @override
  Widget build(BuildContext context) {
    final connected = ref.watch(traktConnectedProvider);
    final username = ref.watch(traktUsernameProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Trakt')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          connected.maybeWhen(
            data: (isOn) => isOn
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _ConnectedCard(
                        username: username.valueOrNull,
                        onDisconnect: () async {
                          final svc =
                              await ref.read(traktServiceProvider.future);
                          await svc.disconnect();
                          refreshTraktData(ref);
                        },
                      ),
                      const SizedBox(height: 16),
                      const _DiagnosticsPanel(),
                    ],
                  )
                : _setupForm(),
            orElse: () => const Center(child: CircularProgressIndicator()),
          ),
        ],
      ),
    );
  }

  Widget _setupForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Connect Trakt',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(
          _embedded
              ? 'Tap Connect — we\'ll open trakt.tv/activate in your browser. '
                  'Enter the code shown here and you\'re done.'
              : 'Create a free API app at trakt.tv/oauth/applications (redirect '
                  'URI: urn:ietf:wg:oauth:2.0:oob), then paste its Client ID & '
                  'Secret below.',
          style: const TextStyle(
              color: Color(0xFF9AA0B0), fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 16),
        if (!_embedded) ...[
          TvTextField(
              controller: _idCtl, hint: 'Trakt Client ID', icon: Icons.key),
          const SizedBox(height: 12),
          TvTextField(
              controller: _secretCtl,
              hint: 'Trakt Client Secret',
              icon: Icons.lock_outline,
              obscure: true),
          const SizedBox(height: 18),
        ],
        if (_code != null) _DeviceCodeCard(code: _code!),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(children: [
              if (_polling)
                const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              if (_polling) const SizedBox(width: 8),
              Expanded(
                  child: Text(_status!,
                      style: const TextStyle(color: Color(0xFF9AA0B0)))),
            ]),
          ),
        FilledButton.icon(
          onPressed: _polling ? null : _connect,
          icon: Icon(_polling ? Icons.hourglass_top : Icons.link),
          label: Text(
              _polling ? 'Waiting for authorization…' : 'Connect with Trakt'),
        ),
      ],
    );
  }
}

/// Live "is my account actually linked & serving data?" check. Runs each
/// endpoint the home screen relies on and shows the real status + counts, so an
/// empty home screen can be told apart from an auth failure.
class _DiagnosticsPanel extends ConsumerStatefulWidget {
  const _DiagnosticsPanel();

  @override
  ConsumerState<_DiagnosticsPanel> createState() => _DiagnosticsPanelState();
}

class _DiagnosticsPanelState extends ConsumerState<_DiagnosticsPanel> {
  List<TraktCheck>? _results;
  bool _running = false;

  Future<void> _run() async {
    setState(() => _running = true);
    final svc = await ref.read(traktServiceProvider.future);
    final res = await svc.diagnostics();
    if (!mounted) return;
    setState(() {
      _results = res;
      _running = false;
    });
    // A fresh check may have refreshed the token / username — refresh the UI
    // and the home rows so anything that was blank repopulates.
    refreshTraktData(ref);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: LumenTheme.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            const Icon(Icons.health_and_safety_outlined,
                color: LumenTheme.accent, size: 20),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Sanity check',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            ),
            TextButton(
              onPressed: _running ? null : _run,
              child: Text(_running ? 'Checking…' : 'Run'),
            ),
          ]),
          const Text(
            'Verifies the account link and that each Trakt list actually '
            'returns data.',
            style: TextStyle(color: Color(0xFF9AA0B0), fontSize: 12.5),
          ),
          if (_results != null) ...[
            const SizedBox(height: 12),
            for (final c in _results!) _CheckRow(check: c),
          ],
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.check});
  final TraktCheck check;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      if (check.count != null) '${check.count} items',
      if (check.status != null) 'HTTP ${check.status}',
      if (check.detail != null) check.detail!,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(check.ok ? Icons.check_circle : Icons.error_outline,
              size: 18,
              color:
                  check.ok ? const Color(0xFF35C759) : const Color(0xFFED1C24)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(check.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13.5)),
                if (parts.isNotEmpty)
                  Text(parts.join(' · '),
                      style: const TextStyle(
                          color: Color(0xFF9AA0B0), fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceCodeCard extends StatelessWidget {
  const _DeviceCodeCard({required this.code});
  final TraktDeviceCode code;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: LumenTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: LumenTheme.accent.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          Text('Go to ${code.verificationUrl}',
              style: const TextStyle(color: Color(0xFF9AA0B0), fontSize: 13)),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => Clipboard.setData(ClipboardData(text: code.userCode)),
            child: Text(
              code.userCode,
              style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 4,
                  color: LumenTheme.accent),
            ),
          ),
          const SizedBox(height: 6),
          const Text('Tap the code to copy',
              style: TextStyle(color: Color(0xFF6B7080), fontSize: 11)),
        ],
      ),
    );
  }
}

class _ConnectedCard extends StatelessWidget {
  const _ConnectedCard({required this.username, required this.onDisconnect});
  final String? username;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: LumenTheme.surface,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(children: [
            const Icon(Icons.check_circle, color: Color(0xFFED1C24), size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Trakt connected',
                      style:
                          TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  if (username != null)
                    Text('@$username',
                        style: const TextStyle(color: Color(0xFF9AA0B0))),
                ],
              ),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        const Text(
          'Your Trakt watchlist now appears on Home, and finished movies are '
          'scrobbled to Trakt automatically.',
          style: TextStyle(color: Color(0xFF9AA0B0), fontSize: 13, height: 1.4),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: onDisconnect,
          icon: const Icon(Icons.logout),
          label: const Text('Disconnect'),
        ),
      ],
    );
  }
}
