import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/models.dart';
import '../../data/sources/sports_guide.dart';
import '../../state/providers.dart';
import '../aurora_focus.dart';
import '../aurora_providers.dart';
import '../aurora_theme.dart';
import '../player/aurora_player.dart';
import '../widgets/aurora_badges.dart';
import '../widgets/aurora_cards.dart';
import '../widgets/aurora_panel.dart';
import '../widgets/aurora_shelf.dart';
import '../widgets/aurora_up_to_nav.dart';

/// Sports hub. Top: today's REAL fixtures per sport (live guide from ESPN's
/// public scoreboards) — tap a game and Lumen finds the matching IPTV event
/// channel and plays it. Below: the source's own event channels grouped by
/// sport, as before.
class AuroraSportsPage extends ConsumerWidget {
  const AuroraSportsPage({super.key});

  Future<void> _playEvent(
      BuildContext context, WidgetRef ref, SportEvent ev) async {
    final pl = ref.read(activePlaylistProvider);
    if (pl?.id == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final svc = await ref.read(sportsGuideServiceProvider.future);
    final candidates = await svc.candidateStreams(pl!.id!, ev);
    if (!context.mounted) return;
    if (candidates.isEmpty) {
      messenger.showSnackBar(SnackBar(
        backgroundColor: Aurora.bgRaised,
        content: Text('No stream found for "${ev.name}" in your source yet.',
            style: const TextStyle(color: Aurora.text)),
      ));
      return;
    }
    if (candidates.length == 1) {
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AuroraPlayerScreen(item: candidates.first)));
      return;
    }
    // Several plausible feeds — let the user pick (D-pad friendly rows).
    final picked = await showDialog<StreamItem>(
      context: context,
      barrierColor: const Color(0xCC000000),
      builder: (dialogContext) => Dialog(
        backgroundColor: Aurora.bgRaised,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 480),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 8),
              child: Row(children: [
                const Icon(Icons.live_tv_rounded,
                    size: 18, color: Aurora.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(ev.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: Aurora.text)),
                ),
              ]),
            ),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final (i, c) in candidates.indexed)
                  AuroraOptionRow(
                    label: c.name,
                    sublabel: c.groupTitle,
                    selected: false,
                    autofocus: i == 0,
                    onSelect: () => Navigator.of(dialogContext).pop(c),
                  ),
              ]),
            ),
            const SizedBox(height: 10),
          ]),
        ),
      ),
    );
    if (picked != null && context.mounted) {
      final at = candidates.indexOf(picked);
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AuroraPlayerScreen(
          item: picked,
          queue: candidates,
          startIndex: at < 0 ? 0 : at,
        ),
      ));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final guide = ref.watch(sportsGuideProvider).valueOrNull;
    final buckets = ref.watch(auroraSportsProvider).valueOrNull;
    final margin = Aurora.margin(context);
    final w = Aurora.wideWidth(context) * 0.82;
    final rowH = w * 9 / 16 + 40;
    const eventH = 148.0;

    if (buckets == null && guide == null) {
      return const Center(
          child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2)));
    }

    return AuroraNavScrollView(
      builder: (scroll) => AuroraRowScope(
        child: CustomScrollView(controller: scroll, slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(margin, 92, margin, 0),
            child:
                Text('Sports', style: Aurora.display.copyWith(fontSize: 30)),
          ),
        ),
        // ---- Today's games (real fixtures) ----
        if (guide != null && guide.isNotEmpty)
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final (sport, events) = guide[i];
                return AuroraShelf<SportEvent>(
                  title: 'Today · $sport',
                  items: events,
                  rowHeight: eventH + 8,
                  skeletonWidth: 260,
                  itemBuilder: (context, ev, j) => _EventCard(
                    event: ev,
                    height: eventH,
                    onTap: () => _playEvent(context, ref, ev),
                  ),
                );
              },
              childCount: guide.length,
            ),
          )
        else if (guide == null)
          SliverToBoxAdapter(
            child: AuroraShelf<SportEvent>(
              title: 'Today',
              items: null, // guide still loading — skeletons
              rowHeight: eventH + 8,
              skeletonWidth: 260,
              itemBuilder: (context, ev, j) => const SizedBox.shrink(),
            ),
          ),
        // ---- The source's own event channels, as before ----
        if (buckets != null && buckets.isEmpty && (guide?.isEmpty ?? true))
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text('No live events found in your source.',
                  style: TextStyle(color: Aurora.textFaint)),
            ),
          )
        else if (buckets != null)
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final (name, items) = buckets[i];
                return AuroraShelf(
                  title: name,
                  items: items,
                  rowHeight: rowH,
                  skeletonWidth: w,
                  itemBuilder: (context, it, j) => AuroraLiveCard(
                    item: it,
                    width: w,
                    onTap: () =>
                        Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => AuroraPlayerScreen(
                        item: it,
                        queue: items,
                        startIndex: j,
                      ),
                    )),
                  ),
                );
              },
              childCount: buckets.length,
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 72)),
      ]),
      ),
    );
  }
}

/// One fixture: league eyebrow, matchup, LIVE badge or local start time.
class _EventCard extends StatelessWidget {
  const _EventCard({
    required this.event,
    required this.height,
    required this.onTap,
  });

  final SportEvent event;
  final double height;
  final VoidCallback onTap;

  String _startLabel(BuildContext context) {
    if (event.startMs <= 0) return event.detail ?? '';
    final dt =
        DateTime.fromMillisecondsSinceEpoch(event.startMs).toLocal();
    final tod = TimeOfDay.fromDateTime(dt);
    return tod.format(context);
  }

  @override
  Widget build(BuildContext context) {
    final finished = event.state == 'post';
    return AuroraFocusable(
      radius: 14,
      scale: 1.05,
      onActivate: onTap,
      builder: (context, focused) => Opacity(
        opacity: finished ? 0.55 : 1,
        child: Container(
          width: 260,
          height: height,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: focused ? Aurora.glassHi : Aurora.glass,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: event.live && !focused
                    ? const Color(0x66FF4D4D)
                    : Aurora.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Text(event.league.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.6,
                          color: Aurora.accent)),
                ),
                if (event.live) const LiveBadge(small: true),
              ]),
              const Spacer(),
              Text(event.awayNames.first,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w800,
                      color: Aurora.text)),
              const SizedBox(height: 2),
              Text('vs ${event.homeNames.first}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: Aurora.textDim)),
              const Spacer(),
              Row(children: [
                Icon(
                    event.live
                        ? Icons.play_circle_fill_rounded
                        : (finished
                            ? Icons.check_circle_outline_rounded
                            : Icons.schedule_rounded),
                    size: 13,
                    color: event.live ? Aurora.live : Aurora.textFaint),
                const SizedBox(width: 5),
                Text(
                    event.live
                        ? (event.detail ?? 'Live now')
                        : finished
                            ? (event.detail ?? 'Finished')
                            : _startLabel(context),
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color:
                            event.live ? Aurora.live : Aurora.textFaint)),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
