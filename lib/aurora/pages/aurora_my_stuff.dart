import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import '../aurora_focus.dart';
import '../aurora_navigation.dart';
import '../aurora_theme.dart';
import '../screens/aurora_continue.dart';
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

    final cwSplit = ref.watch(continueWatchingSplitProvider).valueOrNull;
    final continueW = cwSplit?.own;
    final cwExternal = cwSplit?.external;
    final movies =
        ref.watch(favoritesByKindProvider(StreamKind.movie)).valueOrNull;
    final shows =
        ref.watch(favoritesByKindProvider(StreamKind.series)).valueOrNull;
    final channels =
        ref.watch(favoritesByKindProvider(StreamKind.live)).valueOrNull;
    final recent = ref.watch(recentlyWatchedProvider).valueOrNull;

    final empty = (continueW?.isEmpty ?? false) &&
        (cwExternal?.isEmpty ?? true) &&
        (movies?.isEmpty ?? false) &&
        (shows?.isEmpty ?? false) &&
        (channels?.isEmpty ?? false) &&
        (recent?.isEmpty ?? false);

    return AuroraNavScrollView(
      builder: (scroll) => AuroraRowScope(
        // Row-aware Up/Down — a single column of horizontal shelves, like
        // Home. AuroraRowScope bounds the search to this page's own FocusScope
        // so it never leaks into the top nav bar's shared scope.
        child: CustomScrollView(controller: scroll, slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.fromLTRB(margin, Aurora.topPad(context) + 12, margin, 0),
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
            // Capped like Home's — the › header opens the full list.
            AuroraShelf<StreamItem>(
              title: 'Continue Watching',
              items: continueW?.take(kContinueWatchingRailLimit).toList(),
              totalCount: continueW?.length,
              onMore: (continueW != null && continueW.isNotEmpty)
                  ? () => openContinueWatching(context)
                  : null,
              rowHeight: wideW * 9 / 16 + 10,
              skeletonWidth: wideW,
              itemBuilder: (context, it, i) => AuroraWideCard(
                item: it,
                width: wideW,
                onTap: () => openAuroraItem(context, ref, it),
                onLongPress: () => dismissFromContinueWatching(ref, it),
              ),
            ),
            // Present only when Trakt attributes resume points to an outside
            // streaming service; otherwise it removes itself.
            AuroraShelf<StreamItem>(
              title: cwSplit?.externalLabel == null
                  ? 'Continue elsewhere'
                  : 'Continue on ${cwSplit!.externalLabel}',
              items: cwExternal?.take(kContinueWatchingRailLimit).toList(),
              totalCount: cwExternal?.length,
              hideWhileLoading: true,
              onMore: (cwExternal != null && cwExternal.isNotEmpty)
                  ? () => openContinueWatching(context)
                  : null,
              rowHeight: wideW * 9 / 16 + 10,
              skeletonWidth: wideW,
              itemBuilder: (context, it, i) => AuroraWideCard(
                item: it,
                width: wideW,
                onTap: () => openAuroraItem(context, ref, it),
                onLongPress: () => dismissFromContinueWatching(ref, it),
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
            SizedBox(height: Aurora.bottomPad(context)),
          ]),
        ),
    ]),
      ),
    );
  }
}
