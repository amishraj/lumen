import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../models/models.dart';
import '../repositories/library_repository.dart';

/// One scheduled/live game from the guide.
class SportEvent {
  const SportEvent({
    required this.sport,
    required this.league,
    required this.name,
    required this.homeNames,
    required this.awayNames,
    required this.startMs,
    required this.state,
    this.detail,
  });

  /// Bucket the Sports page groups by ('Soccer', 'Basketball', …).
  final String sport;

  /// Display league ('FIFA World Cup', 'NBA', …).
  final String league;

  /// 'Argentina vs France' — display title.
  final String name;

  /// Every name ESPN gives a team (display / short / abbreviation), longest
  /// first — the channel matcher tries them in order.
  final List<String> homeNames;
  final List<String> awayNames;
  final int startMs;

  /// 'pre' (upcoming today) | 'in' (LIVE) | 'post' (finished).
  final String state;

  /// Status line from the feed ('HT', 'Q3 4:12', '7:30 PM EDT').
  final String? detail;

  bool get live => state == 'in';

  Map<String, Object?> toJson() => {
        'sport': sport,
        'league': league,
        'name': name,
        'home': homeNames,
        'away': awayNames,
        'start': startMs,
        'state': state,
        'detail': detail,
      };

  factory SportEvent.fromJson(Map<String, Object?> j) => SportEvent(
        sport: '${j['sport']}',
        league: '${j['league']}',
        name: '${j['name']}',
        homeNames: [...(j['home'] as List? ?? const []).map((e) => '$e')],
        awayNames: [...(j['away'] as List? ?? const []).map((e) => '$e')],
        startMs: (j['start'] as num?)?.toInt() ?? 0,
        state: '${j['state']}',
        detail: j['detail'] as String?,
      );
}

/// Today's real fixtures per sport, from ESPN's public (keyless) scoreboard
/// JSON — the same feed espn.com renders, stable for years and reliable. One
/// GET per league, all in parallel, cached in app_settings for 10 minutes so
/// tab-hopping never refetches but LIVE state stays honest.
class SportsGuideService {
  SportsGuideService(this._repo);
  final LibraryRepository _repo;

  static const _api = 'https://site.api.espn.com/apis/site/v2/sports';
  static const _cacheKey = 'sports:guide:v1';
  static const _ttl = Duration(minutes: 10);

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 8),
    validateStatus: (s) => s != null && s < 500,
  ));

  /// (sport bucket, display league, ESPN path). Buckets match the channel
  /// rails below the guide so the page reads as one taxonomy.
  static const leagues = <(String, String, String)>[
    ('Soccer', 'FIFA World Cup', 'soccer/fifa.world'),
    ('Soccer', 'Premier League', 'soccer/eng.1'),
    ('Soccer', 'Champions League', 'soccer/uefa.champions'),
    ('Soccer', 'La Liga', 'soccer/esp.1'),
    ('Soccer', 'MLS', 'soccer/usa.1'),
    ('Basketball', 'NBA', 'basketball/nba'),
    ('American Football', 'NFL', 'football/nfl'),
    ('Ice Hockey', 'NHL', 'hockey/nhl'),
    ('Baseball', 'MLB', 'baseball/mlb'),
    ('Combat', 'UFC', 'mma/ufc'),
  ];

  Future<List<SportEvent>> todaysEvents() async {
    // Fresh-enough cache wins — the page must not refetch on every visit.
    final raw = await _repo.getSetting(_cacheKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final wrap = jsonDecode(raw) as Map<String, dynamic>;
        final at = wrap['at'] as int? ?? 0;
        if (DateTime.now().millisecondsSinceEpoch - at <
            _ttl.inMilliseconds) {
          return [
            for (final e in wrap['v'] as List)
              SportEvent.fromJson(Map<String, Object?>.from(e as Map)),
          ];
        }
      } catch (_) {/* corrupt — refetch */}
    }

    final results = await Future.wait([
      for (final (sport, league, path) in leagues)
        _leagueEvents(sport, league, path),
    ]);
    final events = [for (final r in results) ...r];
    if (events.isNotEmpty || raw == null) {
      try {
        await _repo.setSetting(
            _cacheKey,
            jsonEncode({
              'at': DateTime.now().millisecondsSinceEpoch,
              'v': [for (final e in events) e.toJson()],
            }));
      } catch (_) {/* non-fatal */}
    }
    if (events.isEmpty && raw != null) {
      // Offline: last snapshot beats an empty page.
      try {
        final wrap = jsonDecode(raw) as Map<String, dynamic>;
        return [
          for (final e in wrap['v'] as List)
            SportEvent.fromJson(Map<String, Object?>.from(e as Map)),
        ];
      } catch (_) {/* fall through */}
    }
    return events;
  }

  Future<List<SportEvent>> _leagueEvents(
      String sport, String league, String path) async {
    try {
      final res = await _dio.get('$_api/$path/scoreboard');
      if (res.statusCode != 200) return const [];
      final data = res.data is String ? jsonDecode(res.data) : res.data;
      final events = data is Map ? data['events'] : null;
      if (events is! List) return const [];
      final out = <SportEvent>[];
      for (final e in events) {
        if (e is! Map) continue;
        final status = e['status'];
        final type = status is Map ? status['type'] : null;
        final state = type is Map ? '${type['state'] ?? 'pre'}' : 'pre';
        final detail = type is Map ? type['shortDetail'] as String? : null;
        final comps = e['competitions'];
        final comp = comps is List && comps.isNotEmpty ? comps.first : null;
        final competitors = comp is Map ? comp['competitors'] : null;
        List<String> namesOf(String side) {
          if (competitors is! List) return const [];
          for (final c in competitors) {
            if (c is! Map || '${c['homeAway']}' != side) continue;
            final team = c['team'];
            if (team is! Map) return const [];
            return [
              for (final k in ['displayName', 'shortDisplayName', 'abbreviation'])
                if (team[k] is String && '${team[k]}'.trim().isNotEmpty)
                  '${team[k]}'.trim(),
            ];
          }
          return const [];
        }

        final home = namesOf('home');
        final away = namesOf('away');
        if (home.isEmpty || away.isEmpty) continue;
        final start =
            DateTime.tryParse('${e['date'] ?? ''}')?.millisecondsSinceEpoch ??
                0;
        out.add(SportEvent(
          sport: sport,
          league: league,
          name: '${away.first} vs ${home.first}',
          homeNames: home,
          awayNames: away,
          startMs: start,
          state: state,
          detail: detail,
        ));
      }
      return out;
    } catch (_) {
      return const []; // one league down never empties the guide
    }
  }

  /// IPTV channels likely to carry [ev], best first. Channel naming is chaos
  /// ('ARG vs FRA', 'Argentina v France | 20:00', 'beIN 1: WC Final'), so we
  /// probe several FTS queries (both-team, each single team + vs-style
  /// names) and rank: both teams in the name > one team in a 'vs'-named event
  /// channel. All memory/index-free DB queries — a handful, bounded.
  Future<List<StreamItem>> candidateStreams(
      int playlistId, SportEvent ev) async {
    String norm(String s) =>
        s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
    bool containsTeam(String channel, List<String> names) {
      final c = ' ${norm(channel)} ';
      for (final n in names) {
        final t = norm(n).trim();
        if (t.length >= 3 && c.contains(' $t ')) return true;
        // Also tolerate concatenated forms ('ManUtd') for short names.
        if (t.length >= 3 &&
            c.replaceAll(' ', '').contains(t.replaceAll(' ', ''))) {
          return true;
        }
      }
      return false;
    }

    final queries = <String>{
      '${ev.awayNames.first} ${ev.homeNames.first}',
      if (ev.awayNames.length > 1 && ev.homeNames.length > 1)
        '${ev.awayNames[1]} ${ev.homeNames[1]}',
      ev.awayNames.first,
      ev.homeNames.first,
      if (ev.awayNames.length > 1) ev.awayNames[1],
      if (ev.homeNames.length > 1) ev.homeNames[1],
    };
    final seen = <int>{};
    final both = <StreamItem>[];
    final single = <StreamItem>[];
    for (final q in queries) {
      List<StreamItem> hits;
      try {
        hits = await _repo.search(
            playlistId: playlistId,
            kind: StreamKind.live,
            query: q,
            limit: 40);
      } catch (_) {
        continue;
      }
      for (final h in hits) {
        if (h.id == null || !seen.add(h.id!)) continue;
        final hasHome = containsTeam(h.name, ev.homeNames);
        final hasAway = containsTeam(h.name, ev.awayNames);
        if (hasHome && hasAway) {
          both.add(h);
        } else if ((hasHome || hasAway) &&
            RegExp(r'\bvs?\b|\bv\b', caseSensitive: false)
                .hasMatch(h.name)) {
          single.add(h);
        }
      }
      if (both.length >= 6) break; // plenty — stop probing
    }
    return [...both, ...single.take(6)];
  }
}

final sportsGuideServiceProvider =
    FutureProvider<SportsGuideService>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  return SportsGuideService(repo);
});

/// Today's games grouped by sport, LIVE first then by start time, finished
/// games last. autoDispose: leaving and re-entering the tab re-checks the
/// 10-minute cache so LIVE badges stay honest without polling.
final sportsGuideProvider = FutureProvider.autoDispose<
    List<(String, List<SportEvent>)>>((ref) async {
  final svc = await ref.watch(sportsGuideServiceProvider.future);
  final events = await svc.todaysEvents();
  int rank(SportEvent e) => e.live ? 0 : (e.state == 'pre' ? 1 : 2);
  final bySport = <String, List<SportEvent>>{};
  for (final e in events) {
    (bySport[e.sport] ??= []).add(e);
  }
  for (final list in bySport.values) {
    list.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      return a.startMs.compareTo(b.startMs);
    });
  }
  final order = [for (final (sport, _, _) in SportsGuideService.leagues) sport];
  final seen = <String>{};
  return [
    for (final sport in order)
      if (seen.add(sport) && (bySport[sport]?.isNotEmpty ?? false))
        (sport, bySport[sport]!),
  ];
});
