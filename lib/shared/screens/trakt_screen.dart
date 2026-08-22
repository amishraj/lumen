import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/sources/trakt_service.dart';
import '../../state/providers.dart';
import '../lumen_theme.dart';
import '../widgets/tv_text_field.dart';

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
                      const _MergeCard(),
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
        // What "no Trakt" actually means, stated up front. Without this the
        // screen only ever sold the upside of connecting and left the default
        // state — which is most people, most of the time — unexplained.
        const _NotTrackedCard(),
        const SizedBox(height: 20),
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


/// Shown when Trakt is NOT connected: what is and is not happening.
///
/// The honest version. Nothing leaves the device, everything still works
/// locally, and connecting later loses nothing — that last part is the one
/// people actually worry about, so it is said explicitly.
class _NotTrackedCard extends StatelessWidget {
  const _NotTrackedCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: LumenTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2A2E3A)),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.cloud_off_rounded, size: 20, color: Color(0xFF9AA0B0)),
            SizedBox(width: 8),
            Text('Not tracking to Trakt',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          ]),
          SizedBox(height: 10),
          Text(
            'Everything you watch is still recorded on this device — Continue '
            'Watching, resume points and watched ticks all work exactly as '
            'they do now. None of it is sent anywhere.\n\n'
            'What you lose without Trakt: history shared with your other '
            'devices and apps, and your Trakt watchlist on Home.\n\n'
            'Connect whenever you like. Nothing watched in the meantime is '
            'lost — you can upload this device\'s history to Trakt in one tap '
            'straight after connecting.',
            style: TextStyle(
                color: Color(0xFF9AA0B0), fontSize: 13, height: 1.5),
          ),
        ],
      ),
    );
  }
}

/// Shown when Trakt IS connected: the merge rules in plain language, plus the
/// one action the merge was missing — pushing history that predates the link.
class _MergeCard extends ConsumerStatefulWidget {
  const _MergeCard();

  @override
  ConsumerState<_MergeCard> createState() => _MergeCardState();
}

class _MergeCardState extends ConsumerState<_MergeCard> {
  bool _busy = false;
  String? _status;

  Future<void> _upload() async {
    setState(() {
      _busy = true;
      _status = 'Starting…';
    });
    try {
      final svc = await ref.read(traktServiceProvider.future);
      final res = await svc.uploadLocalHistory(onProgress: (stage) {
        if (mounted) setState(() => _status = stage);
      });
      if (!mounted) return;
      setState(() => _status = !res.connected
          ? 'Not connected to Trakt.'
          : res.uploaded == 0
              ? 'Trakt already had everything from this device.'
              : 'Sent ${res.uploaded} to Trakt'
                  '${res.alreadyThere > 0 ? " (${res.alreadyThere} were already there)" : ""}.');
      refreshTraktData(ref);
    } catch (_) {
      if (mounted) setState(() => _status = 'Could not reach Trakt.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
          const Row(children: [
            Icon(Icons.merge_rounded, size: 20, color: LumenTheme.accent),
            SizedBox(width: 8),
            Text('How your history is merged',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          ]),
          const SizedBox(height: 10),
          const Text(
            'Both sides are kept. Anything you watch here is sent to Trakt; '
            'anything watched on another device or app appears here. Where '
            'they disagree about the same episode, the newer change wins — '
            'except that un-ticking something here always wins until you '
            'actually rewatch it.\n\n'
            'Watched offline? It queues and goes up the next time Lumen can '
            'reach Trakt. Nothing is dropped.',
            style: TextStyle(
                color: Color(0xFF9AA0B0), fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 14),
          const Text(
            'History from before you connected is the one thing that does not '
            'travel on its own. Send it now:',
            style: TextStyle(
                color: Color(0xFF9AA0B0), fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy ? null : _upload,
            icon: _busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.upload_rounded, size: 18),
            label: Text(_busy
                ? 'Uploading…'
                : 'Upload this device\'s history to Trakt'),
          ),
          const SizedBox(height: 6),
          Text(
            _status ??
                'Skips anything Trakt already has, so it is safe to run again.',
            style: const TextStyle(color: Color(0xFF9AA0B0), fontSize: 12),
          ),
        ],
      ),
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
