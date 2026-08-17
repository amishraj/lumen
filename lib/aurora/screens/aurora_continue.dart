import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../state/providers.dart';
import '../aurora_navigation.dart';
import '../aurora_theme.dart';
import '../widgets/aurora_buttons.dart';
import '../widgets/aurora_cards.dart';

/// The full Continue Watching list — everything the rails cap away.
///
/// Home and My Stuff show the [kContinueWatchingRailLimit] most recent
/// entries, which is all a horizontal rail can usefully carry. This page is
/// what the "Continue Watching ›" header opens: the whole list as a grid,
/// with anything Trakt attributes to an outside streaming service kept in its
/// own section rather than mixed into your own viewing.
class AuroraContinueScreen extends ConsumerWidget {
  const AuroraContinueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final margin = Aurora.margin(context);
    final split = ref.watch(continueWatchingSplitProvider).valueOrNull;

    return Scaffold(
      backgroundColor: Aurora.bg,
      body: LayoutBuilder(builder: (context, box) {
        const gap = 18.0;
        final avail = box.maxWidth - margin * 2;
        // Wide 16:9 cards, same as the rails — this is a "pick up where you
        // left off" surface, so the still frame matters more than the poster.
        final cols = (avail / 260).floor().clamp(2, 6);
        final cellW = (avail - (cols - 1) * gap) / cols;
        final cellH = cellW * 9 / 16 + 12;

        SliverGrid grid(List<StreamItem> items) => SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                crossAxisSpacing: gap,
                mainAxisSpacing: 20,
                mainAxisExtent: cellH,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => AuroraWideCard(
                  item: items[i],
                  width: cellW,
                  autofocus: i == 0,
                  onTap: () => openAuroraItem(context, ref, items[i]),
                  onLongPress: () =>
                      dismissFromContinueWatching(ref, items[i]),
                ),
                childCount: items.length,
              ),
            );

        return CustomScrollView(slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                  margin, Aurora.topPad(context) - 20, margin, 6),
              child: SafeArea(
                bottom: false,
                child: Row(children: [
                  AuroraIconButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('Continue Watching',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Aurora.display.copyWith(
                            fontSize: Aurora.isCompact(context) ? 24 : 30)),
                  ),
                ]),
              ),
            ),
          ),
          if (split == null)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else if (split.own.isEmpty && split.external.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text('Nothing in progress.',
                    style: TextStyle(color: Aurora.textFaint)),
              ),
            )
          else ...[
            SliverPadding(
              padding: EdgeInsets.fromLTRB(margin, 10, margin, 0),
              sliver: grid(split.own),
            ),
            if (split.external.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(margin, 34, margin, 4),
                  child: _ExternalHeading(label: split.externalLabel),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(margin, 10, margin, 0),
                sliver: grid(split.external),
              ),
            ],
          ],
          SliverToBoxAdapter(
            child: SizedBox(height: Aurora.bottomPad(context)),
          ),
        ]);
      }),
    );
  }
}

/// Section heading for resume points synced in from another service.
class _ExternalHeading extends StatelessWidget {
  const _ExternalHeading({required this.label});
  final String? label;

  @override
  Widget build(BuildContext context) {
    final name = (label == null || label!.trim().isEmpty) ? null : label!.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: Aurora.glass,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Aurora.hairline),
            ),
            child: Text((name ?? 'SYNCED').toUpperCase(),
                style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                    color: Aurora.textDim)),
          ),
          const SizedBox(width: 10),
          Text(name == null ? 'Continue elsewhere' : 'Continue on $name',
              style: Aurora.shelfTitle),
        ]),
        const SizedBox(height: 4),
        const Text(
          'Synced from your Trakt connections — not played in Lumen.',
          style: Aurora.caption,
        ),
      ],
    );
  }
}

/// Opens the full Continue Watching page.
void openContinueWatching(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => const AuroraContinueScreen(),
  ));
}
