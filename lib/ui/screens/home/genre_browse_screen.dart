import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/sources/tmdb_service.dart';
import '../../navigation.dart';
import '../../widgets/poster_card.dart';

/// A full-screen grid of the user's library titles that fall in a TMDB genre.
class GenreBrowseScreen extends ConsumerWidget {
  const GenreBrowseScreen({super.key, required this.genre});
  final TmdbGenre genre;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(tmdbGenreRowProvider(genre.id));
    return Scaffold(
      appBar: AppBar(title: Text(genre.name)),
      body: items.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) {
          if (list.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('Nothing from this genre is in your library yet.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF9AA0B0))),
              ),
            );
          }
          return GridView.builder(
            clipBehavior: Clip.none,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 140,
              mainAxisExtent: 242,
              crossAxisSpacing: 16,
              mainAxisSpacing: 14,
            ),
            itemCount: list.length,
            itemBuilder: (context, i) => PosterCard(
              item: list[i],
              width: 120,
              onTap: () => openItem(context, ref, list[i]),
            ),
          );
        },
      ),
    );
  }
}
