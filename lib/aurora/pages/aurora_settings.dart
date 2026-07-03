import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../data/sources/omdb_service.dart';
import '../../data/sources/realdebrid_service.dart';
import '../../data/sources/tmdb_service.dart';
import '../../state/experience.dart';
import '../../state/providers.dart';
import '../../state/service_status.dart';
import '../../ui/screens/onboarding/add_source_screen.dart';
import '../../ui/screens/settings/trakt_screen.dart';
import '../../ui/widgets/rd_connect_sheet.dart';
import '../aurora_theme.dart';
import '../widgets/aurora_buttons.dart';
import '../widgets/aurora_shelf.dart';

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

    return ListView(
      padding: EdgeInsets.fromLTRB(margin, 92, margin, 64),
      children: [
        Text('Settings', style: Aurora.display.copyWith(fontSize: 30)),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AuroraSectionHeader('Experience'),
              AuroraListRow(
                icon: Icons.swap_horiz_rounded,
                iconColor: Aurora.accent,
                title: 'Switch to the classic experience',
                subtitle:
                    'Go back to the 1.0 interface. Your sources, list and progress '
                    'carry over — switch back here any time.',
                onTap: () async {
                  await setUiExperience(ref, kExperienceClassic);
                },
              ),
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
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(help,
                style:
                    const TextStyle(fontSize: 12.5, color: Aurora.textDim)),
            const SizedBox(height: 14),
            TextField(
              controller: ctl,
              obscureText: obscure,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(hintText: 'Paste key here'),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              await save(ctl.text);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
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
            onPressed: () =>
                ref.read(syncControllerProvider.notifier).resync(pl),
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
