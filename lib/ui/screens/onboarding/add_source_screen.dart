import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../state/providers.dart';
import '../../theme/lumen_theme.dart';
import '../../widgets/tv_text_field.dart';

/// Add an M3U playlist or Xtream Codes account, then run the first sync with
/// live progress. This is the only "heavy" moment — everything after is instant.
class AddSourceScreen extends ConsumerStatefulWidget {
  const AddSourceScreen({super.key});

  @override
  ConsumerState<AddSourceScreen> createState() => _AddSourceScreenState();
}

class _AddSourceScreenState extends ConsumerState<AddSourceScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);

  final _nameCtl = TextEditingController();
  final _urlCtl = TextEditingController();
  final _userCtl = TextEditingController();
  final _passCtl = TextEditingController();
  final _portalCtl = TextEditingController();

  String? _status;
  bool _busy = false;

  @override
  void dispose() {
    _tab.dispose();
    _nameCtl.dispose();
    _urlCtl.dispose();
    _userCtl.dispose();
    _passCtl.dispose();
    _portalCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final isXtream = _tab.index == 1;
    final repo = await ref.read(repositoryProvider.future);

    final pl = Playlist(
      name: _nameCtl.text.trim().isEmpty
          ? (isXtream ? 'Xtream account' : 'My playlist')
          : _nameCtl.text.trim(),
      kind: isXtream ? SourceKind.xtream : SourceKind.m3u,
      url: (isXtream ? _portalCtl.text : _urlCtl.text).trim(),
      username: isXtream ? _userCtl.text.trim() : null,
      password: isXtream ? _passCtl.text.trim() : null,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    if (pl.url.isEmpty) {
      setState(() => _status =
          'Please enter a ${isXtream ? "portal URL" : "playlist URL"}.');
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Starting…';
    });

    try {
      final saved = await repo.addPlaylist(pl);
      await for (final p in repo.sync(saved)) {
        if (!mounted) return;
        setState(() => _status =
            p.written > 0 ? '${p.stage}  (${p.written} items)' : p.stage);
      }
      // Set the active source first, then refresh the list. When onboarding is
      // the root screen (first run) there's no route to pop — invalidating
      // playlistsProvider rebuilds HomeScreen into the tabbed UI. Only pop when
      // we were actually pushed (e.g. from Settings → Add source).
      ref.read(activePlaylistProvider.notifier).state =
          (await repo.playlists()).firstWhere((e) => e.id == saved.id);
      ref.invalidate(playlistsProvider);
      if (!mounted) return;
      if (Navigator.of(context).canPop()) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = 'Failed: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pushed = Navigator.of(context).canPop();
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: LumenTheme.heroGradient),
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              // Keep the form comfortably narrow on tablets / TV / desktop.
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (pushed)
                      Align(
                        alignment: Alignment.centerRight,
                        child: IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close),
                        ),
                      ),
                    // Branded header.
                    Container(
                      width: 64,
                      height: 64,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: LumenTheme.accent.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(Icons.bolt,
                          color: LumenTheme.accent, size: 34),
                    ),
                    const SizedBox(height: 16),
                    Text(pushed ? 'Add a source' : 'Welcome to Lumen',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 26, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 6),
                    const Text(
                      'Connect your IPTV provider to start watching. Your '
                      'playlist stays private on your device.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Color(0xFF9AA0B0),
                          fontSize: 13.5,
                          height: 1.4),
                    ),
                    const SizedBox(height: 22),
                    // Segmented source-type switch.
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: LumenTheme.surface,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: TabBar(
                        controller: _tab,
                        dividerColor: Colors.transparent,
                        indicatorSize: TabBarIndicatorSize.tab,
                        indicator: BoxDecoration(
                          color: LumenTheme.accent.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        labelColor: LumenTheme.accent,
                        unselectedLabelColor: const Color(0xFF8A8F9E),
                        labelStyle: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 13.5),
                        tabs: const [
                          Tab(text: 'M3U URL'),
                          Tab(text: 'Xtream Codes'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    Expanded(
                      child: TabBarView(
                        controller: _tab,
                        physics:
                            _busy ? const NeverScrollableScrollPhysics() : null,
                        children: [_m3uForm(), _xtreamForm()],
                      ),
                    ),
                    if (_status != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: LumenTheme.surface,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            if (_busy)
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            else
                              Icon(
                                  _status!.startsWith('Failed')
                                      ? Icons.error_outline
                                      : Icons.info_outline,
                                  size: 18,
                                  color: _status!.startsWith('Failed')
                                      ? LumenTheme.accentWarm
                                      : LumenTheme.accent),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(_status!,
                                  style: const TextStyle(
                                      color: Color(0xFFC7CBD6), fontSize: 13)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    SizedBox(
                      height: 52,
                      child: FilledButton(
                        onPressed: _busy ? null : _save,
                        child: Text(_busy ? 'Syncing…' : 'Add & sync'),
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

  Widget _m3uForm() => ListView(
        children: [
          _field(_nameCtl, 'Name (optional)', Icons.label_outline,
              autofocus: true),
          const SizedBox(height: 12),
          _field(_urlCtl, 'http://provider.com/get.php?...', Icons.link,
              keyboard: TextInputType.url),
          const SizedBox(height: 16),
          const _Hint(
              'Paste any M3U/M3U8 playlist URL. Lumen downloads and indexes it '
              'in the background — even 40k+ channels.'),
        ],
      );

  Widget _xtreamForm() => ListView(
        children: [
          _field(_nameCtl, 'Name (optional)', Icons.label_outline,
              autofocus: true),
          const SizedBox(height: 12),
          _field(_portalCtl, 'http://host:port', Icons.dns_outlined,
              keyboard: TextInputType.url),
          const SizedBox(height: 12),
          _field(_userCtl, 'Username', Icons.person_outline),
          const SizedBox(height: 12),
          _field(_passCtl, 'Password', Icons.lock_outline, obscure: true),
          const SizedBox(height: 16),
          const _Hint(
              'Lumen calls the Xtream player API to load live channels and '
              'movies, then builds direct play URLs.'),
        ],
      );

  // Navigable tile that opens for editing only when selected/clicked — so the
  // D-pad can always move between fields (see TvTextField).
  Widget _field(TextEditingController c, String hint, IconData icon,
      {bool obscure = false, TextInputType? keyboard, bool autofocus = false}) {
    return TvTextField(
      controller: c,
      hint: hint,
      icon: icon,
      obscure: obscure,
      keyboard: keyboard,
      autofocus: autofocus,
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: LumenTheme.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline, size: 18, color: LumenTheme.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text,
                  style: const TextStyle(
                      color: Color(0xFF9AA0B0), fontSize: 12.5, height: 1.4)),
            ),
          ],
        ),
      );
}
