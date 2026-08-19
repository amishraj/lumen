import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../data/sources/omdb_service.dart';
import '../../data/sources/realdebrid_service.dart';
import '../../data/sources/tmdb_service.dart';
import '../../state/providers.dart';
import '../../state/sync_providers.dart';
import '../../state/service_status.dart';
import '../../shared/screens/add_source_screen.dart';
import '../../shared/screens/trakt_screen.dart';
import '../../shared/widgets/rd_connect_sheet.dart';
import '../../shared/widgets/tv_text_field.dart';
import '../aurora_focus.dart';
import '../../main.dart' show bootFirstFrameMs;
import '../aurora_theme.dart';
import '../screens/aurora_account.dart';
import '../widgets/aurora_buttons.dart';
import '../widgets/aurora_shelf.dart';
import '../widgets/aurora_up_to_nav.dart';

/// Aurora settings. Account/key *flows* (add source, Trakt device auth,
/// Real-Debrid connect) reuse the proven 1.0 screens — same data, same vault —
/// so both experiences stay perfectly in sync.
class AuroraSettingsPage extends ConsumerWidget {
  const AuroraSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final margin = Aurora.margin(context);
    final playlists = ref.watch(playlistsProvider);
    final active = ref.watch(activePlaylistProvider);
    final health = ref.watch(serviceHealthProvider).valueOrNull;

    return AuroraNavScrollView(
      builder: (scroll) => AuroraRowScope(
        child: ListView(
      controller: scroll,
      padding: EdgeInsets.fromLTRB(margin, Aurora.topPad(context) + 12, margin,
          Aurora.bottomPad(context)),
      children: [
        Text('Settings', style: Aurora.display.copyWith(fontSize: 30)),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AuroraSectionHeader('Account'),
              _AccountRow(),
              const AuroraSectionHeader('Sources'),
              playlists.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))),
                ),
                error: (e, _) => Text('$e'),
                data: (list) => Column(children: [
                  for (final pl in list)
                    _SourceRow(pl: pl, isActive: active?.id == pl.id),
                ]),
              ),
              const SizedBox(height: 6),
              AuroraListRow(
                icon: Icons.add_rounded,
                title: 'Add source',
                subtitle: 'M3U playlist or Xtream Codes account',
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AddSourceScreen())),
              ),
              const AuroraSectionHeader('Integrations'),
              AuroraListRow(
                icon: Icons.check_circle,
                iconColor: const Color(0xFFED1C24),
                title: 'Trakt',
                subtitle: _healthLine(
                    health, 'Trakt', 'Sync watch history, resume & watchlist'),
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TraktScreen())),
              ),
              AuroraListRow(
                icon: Icons.movie_filter_rounded,
                iconColor: const Color(0xFF01B4E4),
                title: 'Metadata (TMDB)',
                subtitle: _healthLine(health, 'TMDB',
                    'Backdrops, synopses, trending & genre rows'),
                onTap: () => _editKey(
                  context,
                  ref,
                  title: 'TMDB API key',
                  help:
                      'Free key from themoviedb.org/settings/api — enables richer art, '
                      'overviews, cast and the Trending/Popular/genre rows. '
                      'A v3 key or v4 read token both work.',
                  read: () async =>
                      (await ref.read(tmdbServiceProvider.future)).key(),
                  save: (v) async {
                    final svc = await ref.read(tmdbServiceProvider.future);
                    await svc.saveKey(v);
                    ref.read(tmdbKeyRevProvider.notifier).state++;
                    ref.invalidate(tmdbEnabledProvider);
                    ref.invalidate(serviceHealthProvider);
                  },
                ),
              ),
              AuroraListRow(
                icon: Icons.star_rounded,
                iconColor: const Color(0xFFF5C518),
                title: 'Ratings (OMDb)',
                subtitle: _healthLine(health, 'OMDb (ratings)',
                    'IMDb, Rotten Tomatoes & Metacritic scores'),
                onTap: () => _editKey(
                  context,
                  ref,
                  title: 'OMDb API key',
                  help:
                      'Free key from omdbapi.com/apikey.aspx — enables IMDb, Rotten '
                      'Tomatoes and Metacritic ratings.',
                  read: () async =>
                      (await ref.read(omdbServiceProvider.future)).key(),
                  save: (v) async {
                    final svc = await ref.read(omdbServiceProvider.future);
                    await svc.saveKey(v);
                    ref.invalidate(serviceHealthProvider);
                  },
                ),
              ),
              Consumer(builder: (context, ref, _) {
                final on = ref.watch(rdEnabledProvider).valueOrNull ?? false;
                return AuroraListRow(
                  icon: Icons.cloud_outlined,
                  iconColor: const Color(0xFF35C759),
                  title: 'Real-Debrid',
                  subtitle: on
                      ? 'Enabled — pick IPTV or Debrid per title'
                      : 'Connect to unlock premium streams',
                  trailing: Switch(
                    value: on,
                    activeThumbColor: Aurora.accent,
                    onChanged: (v) async {
                      final svc =
                          await ref.read(realDebridServiceProvider.future);
                      if (v && ((await svc.token())?.isEmpty ?? true)) {
                        if (context.mounted) {
                          await showRdConnectSheet(context, ref);
                        }
                        return;
                      }
                      await svc.setEnabled(v);
                      ref.read(rdRevProvider.notifier).state++;
                      ref.invalidate(rdEnabledProvider);
                      ref.invalidate(serviceHealthProvider);
                    },
                  ),
                  // Always the code-based device flow (enter a code at
                  // real-debrid.com/device) — never a raw token paste.
                  onTap: () => showRdConnectSheet(context, ref),
                );
              }),
              Consumer(builder: (context, ref, _) {
                final on =
                    ref.watch(seekPreviewsProvider).valueOrNull ?? false;
                Future<void> toggle() async {
                  final repo = await ref.read(repositoryProvider.future);
                  await repo.setSetting('seek_previews', on ? null : '1');
                  ref.read(seekPreviewsRevProvider.notifier).state++;
                  ref.invalidate(seekPreviewsProvider);
                }

                return AuroraListRow(
                  icon: Icons.view_carousel_outlined,
                  iconColor: const Color(0xFF9AA0B0),
                  title: 'Seek preview thumbnails',
                  subtitle: on
                      ? 'On — filmstrip previews while seeking (more CPU)'
                      : 'Off — smoother playback, best for TV boxes',
                  trailing: Switch(
                    value: on,
                    activeThumbColor: Aurora.accent,
                    onChanged: (_) => toggle(),
                  ),
                  onTap: toggle,
                );
              }),
              const AuroraSectionHeader('About'),
              AuroraListRow(
                icon: Icons.bolt_rounded,
                iconColor: Aurora.accent,
                title: 'Lumen $kLumenVersion · Aurora',
                subtitle:
                    'The 1.1 experience. Lumen plays only the playlists you provide.',
                trailing: const SizedBox.shrink(),
                onTap: () {},
              ),
            ],
          ),
        ),
      ],
    ),
    ),
    );
  }

  String _healthLine(
      List<ServiceHealth>? health, String name, String fallback) {
    final h = health?.where((e) => e.name == name).toList();
    if (h == null || h.isEmpty) return fallback;
    switch (h.first.level) {
      case HealthLevel.ok:
        return 'Connected · $fallback';
      case HealthLevel.error:
        return 'Problem: ${h.first.detail}';
      case HealthLevel.off:
        return fallback;
    }
  }

  Future<void> _editKey(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String help,
    required Future<String?> Function() read,
    required Future<void> Function(String) save,
    bool obscure = false,
  }) async {
    final ctl = TextEditingController(text: await read() ?? '');
    if (!context.mounted) return;
    // A full-screen, top-anchored, SCROLLABLE entry — not a centered dialog.
    // On a TV the leanback keyboard docks over the lower/centre of the screen
    // and would hide a centred AlertDialog field; keeping the field high and
    // inside a scrollable (with TvTextField's tile→field pattern) means the
    // user can always see what they're typing.
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _KeyEntryScreen(
        title: title,
        help: help,
        controller: ctl,
        obscure: obscure,
        onSave: save,
      ),
    ));
    ctl.dispose();
  }
}

/// Keyboard-safe key/token entry for the 10-foot UI: title + help at the top,
/// the field just below (well clear of the docked on-screen keyboard), inside a
/// scrollable so it auto-scrolls into view if anything would cover it.
class _KeyEntryScreen extends StatelessWidget {
  const _KeyEntryScreen({
    required this.title,
    required this.help,
    required this.controller,
    required this.obscure,
    required this.onSave,
  });

  final String title;
  final String help;
  final TextEditingController controller;
  final bool obscure;
  final Future<void> Function(String) onSave;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aurora.bg,
      appBar: AppBar(
        backgroundColor: Aurora.bg,
        title: Text(title),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              // Big bottom pad + the field's own scrollPadding keep it above the
              // keyboard even on short screens.
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 260),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(help,
                      style: const TextStyle(
                          fontSize: 13.5, color: Aurora.textDim, height: 1.4)),
                  const SizedBox(height: 18),
                  TvTextField(
                    controller: controller,
                    hint: 'Paste key here',
                    icon: Icons.vpn_key_rounded,
                    obscure: obscure,
                    autofocus: true,
                  ),
                  const SizedBox(height: 22),
                  SizedBox(
                    height: 54,
                    child: FilledButton(
                      onPressed: () async {
                        await onSave(controller.text);
                        if (context.mounted) Navigator.pop(context);
                      },
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceRow extends ConsumerWidget {
  const _SourceRow({required this.pl, required this.isActive});
  final Playlist pl;
  final bool isActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncControllerProvider);
    final syncing = sync.running && sync.playlistId == pl.id;

    return AuroraListRow(
      icon: pl.kind == SourceKind.xtream ? Icons.dns_rounded : Icons.link_rounded,
      iconColor: isActive ? Aurora.accent : null,
      title: pl.name,
      subtitle: syncing
          ? (sync.stage ?? 'Refreshing…')
          : '${pl.streamCount} items${isActive ? ' · active' : ''}',
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (syncing)
          const Padding(
            padding: EdgeInsets.only(right: 10),
            child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else ...[
          AuroraIconButton(
            icon: Icons.refresh_rounded,
            size: 16,
            tooltip: 'Re-sync now',
            // Manual tap forces a real re-index (Duration.zero bypasses the
            // once-a-day guard that silently no-op'd this button) and the row
            // above reacts instantly to the controller's running state.
            onPressed: () => ref
                .read(syncControllerProvider.notifier)
                .resync(pl, minInterval: Duration.zero),
          ),
          const SizedBox(width: 6),
          AuroraIconButton(
            icon: Icons.delete_outline_rounded,
            size: 16,
            tooltip: 'Remove source',
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text('Remove ${pl.name}?'),
                  content: const Text(
                      'This deletes the source and its library from this device.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Remove')),
                  ],
                ),
              );
              if (confirmed != true) return;
              final repo = await ref.read(repositoryProvider.future);
              await repo.removePlaylist(pl.id!);
              if (isActive) {
                ref.read(activePlaylistProvider.notifier).state = null;
              }
              ref.invalidate(playlistsProvider);
            },
          ),
        ],
        if (isActive)
          const Padding(
            padding: EdgeInsets.only(left: 8),
            child:
                Icon(Icons.check_circle_rounded, color: Aurora.accent, size: 19),
          ),
      ]),
      onTap: () {
        if (!isActive) {
          ref.read(activePlaylistProvider.notifier).state = pl;
        }
      },
    );
  }
}


/// Settings row for the Lumen account — sign in to sync, or account status.
class _AccountRow extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signedIn = ref.watch(lumenSignedInProvider).valueOrNull ?? false;
    final email = ref.watch(lumenEmailProvider).valueOrNull;
    return AuroraListRow(
      icon: signedIn ? Icons.verified_user_rounded : Icons.person_rounded,
      iconColor: signedIn ? Aurora.accent : null,
      title: signedIn ? (email ?? 'Signed in') : 'Sign in to sync',
      subtitle: signedIn
          ? 'Progress, favorites, sources and keys sync everywhere.'
              '${bootFirstFrameMs != null ? '  ·  boot ${bootFirstFrameMs}ms' : ''}'
          : 'One account, every device — progress, sources and keys follow you.',
      onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AuroraAccountScreen())),
    );
  }
}
