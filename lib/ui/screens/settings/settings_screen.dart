import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/models.dart';
import '../../../data/sources/trakt_service.dart';
import '../../../state/providers.dart';
import '../../theme/lumen_theme.dart';
import '../home/home_customize_screen.dart';
import '../onboarding/add_source_screen.dart';
import 'trakt_screen.dart';

/// Manage sources: switch active playlist, re-sync, or remove.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistsProvider);
    final active = ref.watch(activePlaylistProvider);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Sources',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          playlists.when(
            data: (list) => Column(
              children: [
                for (final pl in list)
                  _SourceCard(
                    pl: pl,
                    isActive: active?.id == pl.id,
                    onActivate: () =>
                        ref.read(activePlaylistProvider.notifier).state = pl,
                    onResync: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final repo = await ref.read(repositoryProvider.future);
                      messenger.showSnackBar(
                          SnackBar(content: Text('Re-syncing ${pl.name}…')));
                      await for (final _ in repo.sync(pl)) {}
                      ref.invalidate(playlistsProvider);
                      messenger.showSnackBar(
                          SnackBar(content: Text('${pl.name} updated.')));
                    },
                    onDelete: () async {
                      final repo = await ref.read(repositoryProvider.future);
                      await repo.removePlaylist(pl.id!);
                      if (active?.id == pl.id) {
                        ref.read(activePlaylistProvider.notifier).state = null;
                      }
                      ref.invalidate(playlistsProvider);
                    },
                  ),
              ],
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Text('$e'),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AddSourceScreen()),
            ),
            icon: const Icon(Icons.add),
            label: const Text('Add source'),
          ),
          const SizedBox(height: 28),
          const Text('Personalize',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.tune, color: LumenTheme.accent),
              title: const Text('Customize Home'),
              subtitle: const Text('Choose & reorder home rows'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const HomeCustomizeScreen())),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.check_circle, color: Color(0xFFED1C24)),
              title: const Text('Trakt'),
              subtitle: Consumer(builder: (context, ref, _) {
                final connected = ref.watch(traktConnectedProvider).valueOrNull;
                return Text(connected == true ? 'Connected' : 'Not connected');
              }),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const TraktScreen())),
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.pl,
    required this.isActive,
    required this.onActivate,
    required this.onResync,
    required this.onDelete,
  });
  final Playlist pl;
  final bool isActive;
  final VoidCallback onActivate;
  final VoidCallback onResync;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(pl.kind == SourceKind.xtream ? Icons.dns : Icons.link,
                color: isActive ? LumenTheme.accent : const Color(0xFF8A8F9E)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(pl.name,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text('${pl.streamCount} items',
                      style: const TextStyle(
                          color: Color(0xFF8A8F9E), fontSize: 12)),
                ],
              ),
            ),
            if (isActive)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Icon(Icons.check_circle, color: LumenTheme.accent, size: 20),
              )
            else
              TextButton(onPressed: onActivate, child: const Text('Use')),
            IconButton(
                onPressed: onResync, icon: const Icon(Icons.refresh, size: 20)),
            IconButton(
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline, size: 20)),
          ],
        ),
      ),
    );
  }
}
