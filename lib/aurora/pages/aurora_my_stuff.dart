import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import '../aurora_navigation.dart';
import '../aurora_theme.dart';
import '../widgets/aurora_cards.dart';
import '../widgets/aurora_shelf.dart';
import '../widgets/aurora_up_to_nav.dart';

/// Everything that's *yours*: in-progress, favorites by type, recent history.
class AuroraMyStuffPage extends ConsumerWidget {
  const AuroraMyStuffPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final margin = Aurora.margin(context);
    final posterW = Aurora.posterWidth(context);
    final wideW = Aurora.wideWidth(context);
    final liveW = wideW * 0.82;

    final continueW = ref.watch(continueWatchingProvider).valueOrNull;
    final movies =
        ref.watch(favoritesByKindProvider(StreamKind.movie)).valueOrNull;
    final shows =
        ref.watch(favoritesByKindProvider(StreamKind.series)).valueOrNull;
    final channels =
        ref.watch(favoritesByKindProvider(StreamKind.live)).valueOrNull;
    final recent = ref.watch(recentlyWatchedProvider).valueOrNull;

    final empty = (continueW?.isEmpty ?? false) &&
        (movies?.isEmpty ?? false) &&
        (shows?.isEmpty ?? false) &&
        (channels?.isEmpty ?? false) &&
        (recent?.isEmpty ?? false);

    return AuroraNavScrollView(
      builder: (scroll) => CustomScrollView(controller: scroll, slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(margin, 92, margin, 0),
          child:
              Text('My Stuff', style: Aurora.display.copyWith(fontSize: 30)),
        ),
      ),
      if (empty)
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text(
              'Nothing saved yet.\nAdd titles to My List, or just start watching.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Aurora.textFaint, height: 1.6),
            ),
          ),
        )
      else
        SliverList(
          delegate: SliverChildListDelegate.fixed([
            AuroraShelf<StreamItem>(
              title: 'Continue Watching',
              items: continueW,
              rowHeight: wideW * 9 / 16 + 10,
              skeletonWidth: wideW,
              itemBuilder: (context, it, i) => AuroraWideCard(
                item: it,
                width: wideW,
                onTap: () => openAuroraItem(context, ref, it),
              ),
            ),
            AuroraShelf<StreamItem>(
              title: 'My Movies',
              items: movies,
              rowHeight: posterW * 1.5 + 56,
              skeletonWidth: posterW,
              itemBuilder: (context, it, i) => AuroraPosterCard(
                item: it,
                width: posterW,
                onTap: () => openAuroraItem(context, ref, it),
              ),
            ),
            AuroraShelf<StreamItem>(
              title: 'My Shows',
              items: shows,
              rowHeight: posterW * 1.5 + 56,
              skeletonWidth: posterW,
              itemBuilder: (context, it, i) => AuroraPosterCard(
                item: it,
                width: posterW,
                onTap: () => openAuroraItem(context, ref, it),
              ),
            ),
            AuroraShelf<StreamItem>(
              title: 'My Channels',
              items: channels,
              rowHeight: liveW * 9 / 16 + 40,
              skeletonWidth: liveW,
              itemBuilder: (context, it, i) => AuroraLiveCard(
                item: it,
                width: liveW,
                onTap: () => openAuroraItem(context, ref, it,
                    liveQueue: channels),
              ),
            ),
            AuroraShelf<StreamItem>(
              title: 'Recently Watched',
              items: recent,
              rowHeight: wideW * 9 / 16 + 10,
              skeletonWidth: wideW,
              itemBuilder: (context, it, i) => AuroraWideCard(
                item: it,
                width: wideW,
                onTap: () => openAuroraItem(context, ref, it),
              ),
            ),
            const SizedBox(height: 72),
          ]),
        ),
    ]),
    );
  }
}
