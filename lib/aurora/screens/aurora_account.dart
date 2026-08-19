import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/widgets/tv_text_field.dart';
import '../../state/providers.dart';
import '../../state/sync_providers.dart';
import '../aurora_theme.dart';
import '../widgets/aurora_buttons.dart';
import '../widgets/aurora_shelf.dart';

/// The Lumen account screen: sign in (email/password or TV pairing code),
/// and once signed in — devices, pair-a-TV, sync now, sign out.
class AuroraAccountScreen extends ConsumerStatefulWidget {
  const AuroraAccountScreen({super.key});

  @override
  ConsumerState<AuroraAccountScreen> createState() =>
      _AuroraAccountScreenState();
}

class _AuroraAccountScreenState extends ConsumerState<AuroraAccountScreen> {
  final _server = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _pairCode = TextEditingController();

  bool _busy = false;
  String? _status;
  // TV pairing state (this device showing a code).
  String? _showingCode;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    () async {
      final auth = await ref.read(authServiceProvider.future);
      final base = await auth.apiBase();
      if (base != null && mounted) _server.text = base;
    }();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _server.dispose();
    _email.dispose();
    _password.dispose();
    _pairCode.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    final deviceLabel = 'Lumen ${Theme.of(context).platform.name}';
    try {
      final auth = await ref.read(authServiceProvider.future);
      final res = await auth.login(
          _server.text, _email.text, _password.text, deviceLabel);
      if (!res.ok) {
        setState(() => _status = res.detail);
        return;
      }
      ref.read(lumenAccountRevProvider.notifier).state++;
      await _firstSyncPolicy();
    } catch (e) {
      setState(() => _status = 'Could not reach the server.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The moment trust gets dented if handled silently: both sides may have
  /// data. Merge is safe and right nearly always; the other two exist so
  /// "I signed in and it ate my progress" can never happen silently.
  Future<void> _firstSyncPolicy() async {
    final sync = await ref.read(syncServiceProvider.future);
    final hasLocal = await sync.hasLocalData();
    if (!mounted) return;
    var choice = 'merge';
    if (hasLocal) {
      choice = await showDialog<String>(
            context: context,
            builder: (context) => AlertDialog(
              backgroundColor: Aurora.bgRaised,
              title: const Text('This device already has data'),
              content: const Text(
                  'Merge keeps everything from both this device and your '
                  'account (newest wins per title).\n\n'
                  '“Use my account” archives local data first, then replaces '
                  'it.\n“Upload this device” makes this device the account.',
                  style: TextStyle(color: Aurora.textDim, height: 1.4)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, 'account'),
                    child: const Text('Use my account')),
                TextButton(
                    onPressed: () => Navigator.pop(context, 'upload'),
                    child: const Text('Upload this device')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, 'merge'),
                    child: const Text('Merge (recommended)')),
              ],
            ),
          ) ??
          'merge';
    }
    setState(() => _status = 'Syncing…');
    switch (choice) {
      case 'account':
        await sync.replaceLocalWithAccount();
      case 'upload':
        await sync.uploadThisDevice();
      default:
        await sync.seedOutboxFromLocal();
        await sync.pushPull();
    }
    if (!mounted) return;
    ref.read(lumenAccountRevProvider.notifier).state++;
    ref.invalidate(playlistsProvider);
    unawaited(runSync(ref));
    setState(() => _status = 'Synced.');
  }

  Future<void> _startPairing() async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final auth = await ref.read(authServiceProvider.future);
      final started =
          await auth.pairStart(_server.text, 'Lumen TV');
      if (started == null) {
        setState(() => _status = 'Could not reach the server.');
        return;
      }
      setState(() => _showingCode = started.userCode);
      _pollTimer = Timer.periodic(const Duration(seconds: 5), (t) async {
        try {
          final done = await auth.pairPoll(started.deviceCode);
          if (done) {
            t.cancel();
            if (mounted) {
              setState(() => _showingCode = null);
              ref.read(lumenAccountRevProvider.notifier).state++;
              await _firstSyncPolicy();
            }
          }
        } catch (_) {
          t.cancel();
          if (mounted) {
            setState(() {
              _showingCode = null;
              _status = 'Code expired — try again.';
            });
          }
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approveTv() async {
    final auth = await ref.read(authServiceProvider.future);
    final ok = await auth.pairApprove(_pairCode.text.trim());
    setState(() =>
        _status = ok ? 'TV signed in.' : 'Code not found or expired.');
    if (ok) _pairCode.clear();
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = ref.watch(lumenSignedInProvider).valueOrNull ?? false;
    return Scaffold(
      backgroundColor: Aurora.bg,
      appBar: AppBar(backgroundColor: Aurora.bg, title: const Text('Lumen Account')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 260),
              child:
                  signedIn ? _signedInView() : _signInView(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _signInView() {
    if (_showingCode != null) {
      return Column(children: [
        const SizedBox(height: 40),
        const Text('On a signed-in phone, open\nAccount → “Pair a TV” and enter:',
            textAlign: TextAlign.center,
            style: TextStyle(color: Aurora.textDim, height: 1.5)),
        const SizedBox(height: 24),
        Text(_showingCode!,
            style: Aurora.display.copyWith(fontSize: 56, letterSpacing: 8)),
        const SizedBox(height: 24),
        const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(height: 24),
        TextButton(
            onPressed: () {
              _pollTimer?.cancel();
              setState(() => _showingCode = null);
            },
            child: const Text('Cancel')),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text(
          'One account, every device: your sources, keys, progress and '
          'favorites follow you. Ask the owner for credentials.',
          style: TextStyle(color: Aurora.textDim, height: 1.4)),
      const SizedBox(height: 20),
      TvTextField(
          controller: _server,
          hint: 'https://lumen-api.you.workers.dev',
          icon: Icons.dns_rounded),
      const SizedBox(height: 12),
      TvTextField(
          controller: _email, hint: 'Email', icon: Icons.person_rounded),
      const SizedBox(height: 12),
      TvTextField(
          controller: _password,
          hint: 'Password',
          icon: Icons.password_rounded,
          obscure: true),
      const SizedBox(height: 20),
      SizedBox(
        height: 54,
        child: FilledButton(
          onPressed: _busy ? null : _signIn,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Sign in'),
        ),
      ),
      const SizedBox(height: 10),
      OutlinedButton(
        onPressed: _busy ? null : _startPairing,
        child: const Text('Show a pairing code instead (TV)'),
      ),
      if (_status != null) ...[
        const SizedBox(height: 14),
        Text(_status!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Aurora.textDim)),
      ],
    ]);
  }

  Widget _signedInView() {
    final email = ref.watch(lumenEmailProvider).valueOrNull ?? '';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AuroraListRow(
        icon: Icons.verified_user_rounded,
        iconColor: Aurora.accent,
        title: email.isEmpty ? 'Signed in' : email,
        subtitle: 'Progress, favorites, sources and keys sync to this account.',
        onTap: () {},
      ),
      const AuroraSectionHeader('Sync'),
      AuroraListRow(
        icon: Icons.sync_rounded,
        title: 'Sync now',
        subtitle: _status,
        onTap: () async {
          setState(() => _status = 'Syncing…');
          await runSync(ref);
          if (mounted) setState(() => _status = 'Done.');
        },
      ),
      const AuroraSectionHeader('Pair a TV'),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Text(
            'On the TV, choose “Show a pairing code”, then enter it here.',
            style: TextStyle(color: Aurora.textDim, fontSize: 13)),
      ),
      Row(children: [
        Expanded(
            child: TvTextField(
                controller: _pairCode,
                hint: '6-digit code',
                icon: Icons.tv_rounded)),
        const SizedBox(width: 10),
        FilledButton(onPressed: _approveTv, child: const Text('Approve')),
      ]),
      const AuroraSectionHeader('Devices'),
      _DevicesList(onRevoked: () => setState(() {})),
      const AuroraSectionHeader('Session'),
      AuroraListRow(
        icon: Icons.logout_rounded,
        title: 'Sign out',
        subtitle:
            'This device keeps its local library and progress; it just stops syncing.',
        onTap: () async {
          final auth = await ref.read(authServiceProvider.future);
          await auth.signOut();
          ref.read(lumenAccountRevProvider.notifier).state++;
          if (mounted) setState(() => _status = null);
        },
      ),
      if (_status != null) ...[
        const SizedBox(height: 10),
        Text(_status!, style: const TextStyle(color: Aurora.textDim)),
      ],
    ]);
  }
}

class _DevicesList extends ConsumerWidget {
  const _DevicesList({required this.onRevoked});
  final VoidCallback onRevoked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<Map<String, Object?>?>(
      future: ref
          .read(authServiceProvider.future)
          .then((a) => a.me()),
      builder: (context, snap) {
        final devices = (snap.data?['devices'] as List?) ?? const [];
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
                child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        if (devices.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(8),
            child: Text('No devices listed (offline?).',
                style: TextStyle(color: Aurora.textDim, fontSize: 13)),
          );
        }
        return Column(children: [
          for (final d in devices)
            AuroraListRow(
              icon: switch ('${(d as Map)['platform']}') {
                'android' => Icons.tv_rounded,
                'ios' => Icons.phone_iphone_rounded,
                'macos' => Icons.laptop_mac_rounded,
                _ => Icons.devices_rounded,
              },
              title: '${d['label'] ?? 'Device'}',
              subtitle: (d['last_seen'] is num)
                  ? 'Last seen ${_ago((d['last_seen'] as num).toInt())}'
                  : null,
              onTap: () {},
              trailing: TextButton(
                onPressed: () async {
                  final auth = await ref.read(authServiceProvider.future);
                  await auth.revokeDevice('${d['id']}');
                  onRevoked();
                },
                child: const Text('Revoke'),
              ),
            ),
        ]);
      },
    );
  }

  static String _ago(int ms) {
    final d = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inMinutes < 2) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }
}
