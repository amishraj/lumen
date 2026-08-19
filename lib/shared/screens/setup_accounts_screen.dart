import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/sources/realdebrid_service.dart';
import '../../data/sources/tmdb_service.dart';
import '../../data/sources/trakt_service.dart';
import '../../state/providers.dart';
import '../lumen_theme.dart';
import '../widgets/focusable_item.dart';
import '../widgets/rd_connect_sheet.dart';
import '../widgets/tv_text_field.dart';
import 'trakt_screen.dart';

/// Optional start-time step: connect Trakt and Real-Debrid, and paste a TMDB
/// key — so a brand-new user can light up cross-device progress and rich
/// artwork before they ever reach the home screen. Everything here is optional
/// (a prominent Skip/Done), and reachable later from Settings.
///
/// Keyboard-safe by construction: the whole body is a top-anchored
/// [SingleChildScrollView], so the one text field (the TMDB key) auto-scrolls
/// clear of the TV's on-screen keyboard instead of hiding behind it.
class SetupAccountsScreen extends ConsumerStatefulWidget {
  const SetupAccountsScreen({super.key});

  @override
  ConsumerState<SetupAccountsScreen> createState() =>
      _SetupAccountsScreenState();
}

class _SetupAccountsScreenState extends ConsumerState<SetupAccountsScreen> {
  final _tmdbCtl = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _prefillTmdb();
  }

  Future<void> _prefillTmdb() async {
    final svc = await ref.read(tmdbServiceProvider.future);
    final key = await svc.key();
    if (mounted && key != null && key.isNotEmpty) _tmdbCtl.text = key;
  }

  @override
  void dispose() {
    _tmdbCtl.dispose();
    super.dispose();
  }

  Future<void> _connectTrakt() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const TraktScreen()),
    );
    if (mounted) refreshTraktData(ref);
  }

  Future<void> _connectRd() async {
    final ok = await showRdConnectSheet(context, ref);
    if (ok && mounted) ref.read(rdRevProvider.notifier).state++;
  }

  Future<void> _finish() async {
    setState(() => _busy = true);
    final key = _tmdbCtl.text.trim();
    if (key.isNotEmpty) {
      final svc = await ref.read(tmdbServiceProvider.future);
      await svc.saveKey(key);
      ref.read(tmdbKeyRevProvider.notifier).state++;
      ref.invalidate(tmdbEnabledProvider);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final traktOn = ref.watch(traktConnectedProvider).valueOrNull ?? false;
    final rdOn = ref.watch(rdEnabledProvider).valueOrNull ?? false;

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: LumenTheme.heroGradient),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: SingleChildScrollView(
                // Top-anchored + generous bottom pad so the TMDB field never
                // sits behind the on-screen keyboard.
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 260),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _busy ? null : _finish,
                        child: const Text('Skip'),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text('Connect your accounts',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 6),
                    const Text(
                      'All optional — you can set these up any time in Settings.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Color(0xFF9AA0B0), fontSize: 13.5, height: 1.4),
                    ),
                    const SizedBox(height: 22),
                    _AccountTile(
                      autofocus: true,
                      icon: Icons.sync_rounded,
                      connected: traktOn,
                      title: traktOn ? 'Trakt connected' : 'Connect Trakt',
                      subtitle:
                          'Sync watch progress, watchlist and history across '
                          'your devices.',
                      onTap: _connectTrakt,
                    ),
                    const SizedBox(height: 12),
                    _AccountTile(
                      icon: Icons.cloud_outlined,
                      connected: rdOn,
                      title:
                          rdOn ? 'Real-Debrid connected' : 'Connect Real-Debrid',
                      subtitle:
                          'Stream high-quality sources for anything not in your '
                          'playlist.',
                      onTap: _connectRd,
                    ),
                    const SizedBox(height: 22),
                    const Text('TMDB API key',
                        style: TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    const Text(
                      'Adds posters, backdrops and discovery rows. Get a free '
                      'key at themoviedb.org → Settings → API.',
                      style: TextStyle(
                          color: Color(0xFF9AA0B0), fontSize: 12.5, height: 1.4),
                    ),
                    const SizedBox(height: 10),
                    TvTextField(
                      controller: _tmdbCtl,
                      hint: 'Paste TMDB key (optional)',
                      icon: Icons.vpn_key_rounded,
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      height: 52,
                      child: FilledButton(
                        onPressed: _busy ? null : _finish,
                        child: Text(_busy ? 'Saving…' : 'Done'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.icon,
    required this.connected,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.autofocus = false,
  });

  final IconData icon;
  final bool connected;
  final String title;
  final String subtitle;
  final Future<void> Function() onTap;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return FocusableItem(
      borderRadius: 14,
      autofocus: autofocus,
      onActivate: onTap,
      builder: (context, focused) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: LumenTheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: focused ? LumenTheme.accent : const Color(0xFF2A2E3A)),
        ),
        child: Row(children: [
          Icon(connected ? Icons.check_circle : icon,
              size: 22,
              color: connected
                  ? const Color(0xFF35C759)
                  : const Color(0xFF9AA0B0)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 14.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(
                        color: Color(0xFF8A8F9E), fontSize: 12, height: 1.3)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right, size: 18, color: Color(0xFF6B7080)),
        ]),
      ),
    );
  }
}
