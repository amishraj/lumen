import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/providers.dart';
import '../../theme/lumen_theme.dart';
import '../../widgets/nav_rail.dart';
import '../live/live_tv_screen.dart';
import '../onboarding/add_source_screen.dart';
import '../search/search_screen.dart';
import '../settings/settings_screen.dart';
import '../sports/sports_screen.dart';
import 'home_feed_screen.dart';

const int _searchTab = 3;

/// Root shell. Auto-routes to onboarding when no source exists, otherwise shows
/// the tabbed experience with a master search bar in the app bar.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _index = 0;
  final _searchCtl = TextEditingController();
  Timer? _debounce;
  DateTime? _lastBack;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtl.dispose();
    super.dispose();
  }

  /// Root back handling so a stray Back / remote-Back doesn't drop the user
  /// out of the app: first bounce to the Home tab, then require a second Back
  /// within 2s to actually exit.
  void _onBack() {
    if (_index != 0) {
      setState(() => _index = 0);
      return;
    }
    final now = DateTime.now();
    if (_lastBack == null ||
        now.difference(_lastBack!) > const Duration(seconds: 2)) {
      _lastBack = now;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(
          content: Text('Press back again to exit'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ));
      return;
    }
    // Second press within the window — let the pop through to leave the app.
    SystemNavigator.pop();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () {
      ref.read(searchQueryProvider.notifier).state = v;
    });
    if (v.trim().length >= 2 && _index != _searchTab) {
      setState(() => _index = _searchTab);
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistsProvider);

    return playlists.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(body: Center(child: Text('$e'))),
      data: (list) {
        if (list.isEmpty) return const AddSourceScreen();

        final active = ref.watch(activePlaylistProvider);
        if (active == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ref.read(activePlaylistProvider.notifier).state = list.first;
          });
        }

        const pages = [
          HomeFeedScreen(),
          LiveTvScreen(),
          SportsScreen(),
          SearchScreen(),
          SettingsScreen(),
        ];

        return PopScope(
          // We manage exit ourselves (tab bounce + press-back-twice), so never
          // let the framework pop this root route on the first Back.
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _onBack();
          },
          child: Scaffold(
            appBar: AppBar(
              titleSpacing: 16,
              title: Row(
                children: [
                  const Icon(Icons.bolt, color: LumenTheme.accent),
                  const SizedBox(width: 8),
                  Expanded(
                      child: _MasterSearchBar(
                          controller: _searchCtl, onChanged: _onSearch)),
                  const SizedBox(width: 12),
                  if (active != null)
                    Container(
                      constraints: const BoxConstraints(maxWidth: 120),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: LumenTheme.surface,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(active.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.w600)),
                    ),
                ],
              ),
            ),
            body: Row(
              children: [
                NavRail(
                  selectedIndex: _index,
                  onSelect: (i) => setState(() => _index = i),
                  items: const [
                    NavRailItem(Icons.home_outlined, Icons.home, 'Home'),
                    NavRailItem(Icons.live_tv_outlined, Icons.live_tv, 'Watch'),
                    NavRailItem(Icons.sports_soccer_outlined,
                        Icons.sports_soccer, 'Sports'),
                    NavRailItem(Icons.search, Icons.search, 'Search'),
                    NavRailItem(Icons.tune, Icons.tune, 'Sources'),
                  ],
                ),
                Expanded(child: IndexedStack(index: _index, children: pages)),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MasterSearchBar extends ConsumerWidget {
  const _MasterSearchBar({required this.controller, required this.onChanged});
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = ref.watch(searchQueryProvider);
    return SizedBox(
      height: 40,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search movies, shows & channels',
          prefixIcon: const Icon(Icons.search, size: 19),
          contentPadding: const EdgeInsets.symmetric(vertical: 0),
          suffixIcon: q.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 17),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
        ),
      ),
    );
  }
}
