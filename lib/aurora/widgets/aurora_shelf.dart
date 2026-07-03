import 'package:flutter/material.dart';

import '../aurora_theme.dart';

/// A titled horizontal rail. The backbone of Home / My Stuff / Search.
///
/// Pass [items] as:
/// - null   → skeleton placeholders (still loading)
/// - empty  → the shelf removes itself entirely
/// - data   → a virtualized horizontal list built via [itemBuilder]
class AuroraShelf<T> extends StatelessWidget {
  const AuroraShelf({
    super.key,
    required this.title,
    required this.items,
    required this.itemBuilder,
    required this.rowHeight,
    this.leading,
    this.skeletonWidth = 148,
    this.spacing = 14,
  });

  final String title;
  final List<T>? items;
  final Widget Function(BuildContext context, T item, int index) itemBuilder;

  /// Fixed height of the scrolling row (cards must fit inside it).
  final double rowHeight;
  final Widget? leading;
  final double skeletonWidth;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final list = items;
    if (list != null && list.isEmpty) return const SizedBox.shrink();
    final margin = Aurora.margin(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 26, margin, 12),
          child: Row(children: [
            if (leading != null) ...[leading!, const SizedBox(width: 8)],
            Text(title, style: Aurora.shelfTitle),
            if (list != null) ...[
              const SizedBox(width: 10),
              Text('${list.length}', style: Aurora.caption),
            ],
          ]),
        ),
        SizedBox(
          height: rowHeight,
          child: list == null
              ? _Skeleton(
                  margin: margin, width: skeletonWidth, spacing: spacing)
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  clipBehavior: Clip.none, // focus lift must not be clipped
                  padding:
                      EdgeInsets.symmetric(horizontal: margin, vertical: 4),
                  itemCount: list.length,
                  separatorBuilder: (_, __) => SizedBox(width: spacing),
                  itemBuilder: (context, i) =>
                      itemBuilder(context, list[i], i),
                ),
        ),
      ],
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton(
      {required this.margin, required this.width, required this.spacing});
  final double margin;
  final double width;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.symmetric(horizontal: margin, vertical: 4),
      itemCount: 8,
      separatorBuilder: (_, __) => SizedBox(width: spacing),
      itemBuilder: (_, __) => Container(
        width: width,
        decoration: BoxDecoration(
          color: const Color(0xFF10131C),
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}

/// Section header used on pages that aren't shelf-based.
class AuroraSectionHeader extends StatelessWidget {
  const AuroraSectionHeader(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 26, bottom: 10),
      child: Row(children: [
        Expanded(child: Text(title, style: Aurora.shelfTitle)),
        if (trailing != null) trailing!,
      ]),
    );
  }
}
