import 'package:flutter/material.dart';

import '../aurora_focus.dart';
import '../aurora_theme.dart';

/// A titled horizontal rail. The backbone of Home / My Stuff / Search.
///
/// Pass [items] as:
/// - null   → skeleton placeholders (still loading), or nothing at all when
///            [hideWhileLoading] is set
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
    this.hideWhileLoading = false,
    this.onMore,
    this.totalCount,
  });

  final String title;
  final List<T>? items;
  final Widget Function(BuildContext context, T item, int index) itemBuilder;

  /// Fixed height of the scrolling row (cards must fit inside it).
  final double rowHeight;
  final Widget? leading;
  final double skeletonWidth;
  final double spacing;

  /// When set, the header becomes a control: "Title ›", opening a full page
  /// for rows that are a capped window onto something longer.
  final VoidCallback? onMore;

  /// The size of that longer list, when the rail is showing only a slice of
  /// it. Falls back to the rendered item count.
  final int? totalCount;

  /// Secondary rows (IPTV-derived: Live Now, library samples) collapse to
  /// nothing while loading instead of holding skeleton space — the page is for
  /// the content that's ready, and these simply appear when they are.
  final bool hideWhileLoading;

  @override
  Widget build(BuildContext context) {
    final list = items;
    if (list != null && list.isEmpty) return const SizedBox.shrink();
    if (list == null && hideWhileLoading) return const SizedBox.shrink();
    final margin = Aurora.margin(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(margin, 26, margin, 12),
          child: _Header(
            title: title,
            leading: leading,
            count: list?.length == null
                ? null
                : (totalCount ?? list!.length),
            onMore: onMore,
          ),
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

/// A shelf title, optionally a control. Plain text when the rail is the whole
/// story; a focusable "Title ›" when there's a fuller page behind it.
class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.leading,
    required this.count,
    required this.onMore,
  });
  final String title;
  final Widget? leading;
  final int? count;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    Widget row(bool focused) => Row(mainAxisSize: MainAxisSize.min, children: [
          if (leading != null) ...[leading!, const SizedBox(width: 8)],
          Flexible(
            child: Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: focused
                    ? Aurora.shelfTitle.copyWith(color: Aurora.bg)
                    : Aurora.shelfTitle),
          ),
          if (onMore != null)
            Icon(Icons.chevron_right_rounded,
                size: 20, color: focused ? Aurora.bg : Aurora.textDim),
          if (count != null) ...[
            const SizedBox(width: 8),
            Text('$count',
                style: focused
                    ? Aurora.caption.copyWith(color: const Color(0x99060708))
                    : Aurora.caption),
          ],
        ]);

    if (onMore == null) return row(false);
    return Align(
      alignment: Alignment.centerLeft,
      // Pulled back by its own padding so the title still sits on the page
      // gutter, exactly level with every non-interactive shelf title.
      child: Transform.translate(
        offset: const Offset(-10, 0),
        child: AuroraFocusable(
          ring: false,
          scale: 1.0,
          radius: 12,
          centerOnFocus: false,
          onActivate: onMore!,
          builder: (context, focused) => AnimatedContainer(
            duration: Aurora.fast,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: focused ? Colors.white : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: row(focused),
          ),
        ),
      ),
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
