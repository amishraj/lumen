import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/sources/trakt_service.dart';
import '../../state/providers.dart';
import '../../state/service_status.dart';
import '../theme/lumen_theme.dart';

/// Compact API-health indicator for the app bar. A dot turns amber when a
/// configured service (Trakt / TMDB / OMDb) is failing; tapping opens the
/// status sheet with a retry.
class ServiceHealthChip extends ConsumerWidget {
  const ServiceHealthChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasError = ref.watch(anyServiceErrorProvider);
    return IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: 'Service status',
      onPressed: () => showServiceStatusSheet(context),
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.monitor_heart_outlined, size: 22),
          Positioned(
            right: -1,
            top: -1,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color:
                    hasError ? LumenTheme.accentWarm : const Color(0xFF35C759),
                shape: BoxShape.circle,
                border: Border.all(color: LumenTheme.surface, width: 1.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet listing each external service's live health with a Retry that
/// re-probes and refreshes the home data. Shared by the top bar and Sources.
void showServiceStatusSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF15171F),
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => const ServiceStatusList(),
  );
}

/// The reusable health list (also embedded in the Sources screen).
class ServiceStatusList extends ConsumerWidget {
  const ServiceStatusList({super.key, this.padding});
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(serviceHealthProvider);
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(20, 16, 12, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Service status',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              ),
              TextButton.icon(
                onPressed: () {
                  ref.invalidate(serviceHealthProvider);
                  // Also refresh home data that depends on these services.
                  ref.invalidate(featuredProvider);
                  ref.invalidate(traktWatchlistProvider);
                  ref.invalidate(traktListsProvider);
                },
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          health.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))),
            ),
            error: (e, _) =>
                Text('$e', style: const TextStyle(color: Color(0xFF9AA0B0))),
            data: (list) =>
                Column(children: [for (final h in list) _HealthRow(h: h)]),
          ),
        ],
      ),
    );
  }
}

class _HealthRow extends StatelessWidget {
  const _HealthRow({required this.h});
  final ServiceHealth h;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (h.level) {
      HealthLevel.ok => (Icons.check_circle, const Color(0xFF35C759)),
      HealthLevel.error => (Icons.error_outline, LumenTheme.accentWarm),
      HealthLevel.off => (Icons.remove_circle_outline, const Color(0xFF6B7080)),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(h.name,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Text(h.detail,
              style: const TextStyle(color: Color(0xFF9AA0B0), fontSize: 12.5)),
        ],
      ),
    );
  }
}
