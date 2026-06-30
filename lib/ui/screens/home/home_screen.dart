import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/providers.dart';
import '../../theme/lumen_theme.dart';
import '../live/live_tv_screen.dart';
import '../onboarding/add_source_screen.dart';
import '../search/search_screen.dart';
import '../settings/settings_screen.dart';

/// Root shell. Auto-routes to onboarding when no source exists, otherwise shows
/// the tabbed experience (Live, Search, Settings).
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistsProvider);

    return playlists.when(
      loading: () => const Scaffold(
          body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text('$e'))),
      data: (list) {
        if (list.isEmpty) return const AddSourceScreen();

        // Default the active source to the first if none chosen.
        final active = ref.watch(activePlaylistProvider);
        if (active == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ref.read(activePlaylistProvider.notifier).state = list.first;
          });
        }

        final pages = [
          const LiveTvScreen(),
          const SearchScreen(),
          const SettingsScreen(),
        ];

        return Scaffold(
          appBar: AppBar(
            titleSpacing: 16,
            title: Row(
              children: [
                const Icon(Icons.bolt, color: LumenTheme.accent),
                const SizedBox(width: 6),
                const Text('Lumen'),
                const Spacer(),
                if (active != null)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: LumenTheme.surface,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(active.name,
                        style: const TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w600)),
                  ),
              ],
            ),
          ),
          body: IndexedStack(index: _index, children: pages),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.live_tv_outlined),
                  selectedIcon: Icon(Icons.live_tv),
                  label: 'Watch'),
              NavigationDestination(
                  icon: Icon(Icons.search), label: 'Search'),
              NavigationDestination(
                  icon: Icon(Icons.tune), label: 'Sources'),
            ],
          ),
        );
      },
    );
  }
}
