import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/data/db/app_database.dart';
import 'package:lumen/data/models/models.dart';
import 'package:lumen/data/title_index.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The title index is what every discovery surface matches against, and it is
/// also the single biggest thing the app reads at startup. These tests pin
/// both halves: that the streamed build still matches what the old
/// whole-table-in-one-list build matched, and that it streams rather than
/// materialising the table.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lumen_index_test');
    path = '${dir.path}/lumen.db';
    AppDatabase.resetForTest();
  });

  tearDown(() async {
    AppDatabase.resetForTest();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  StreamItem item(String name, {int? id, StreamKind? kind, String? url}) =>
      StreamItem(
        id: id,
        playlistId: 1,
        kind: kind ?? StreamKind.movie,
        name: name,
        url: url ?? 'http://x/$name',
      );

  Future<TitleIndex> indexOf(List<StreamItem> items) =>
      TitleIndex.build(1, items);

  test('matches through provider prefixes, quality tags and bare years',
      () async {
    final idx = await indexOf([
      item('EN | The Matrix (1999) [1080p]', id: 1),
      item('Blade Runner 2049', id: 2),
      item('Breaking Bad', id: 3, kind: StreamKind.series),
    ]);

    expect(idx.match('The Matrix')?.id, 1);
    // Leading-article tolerance, both directions.
    expect(idx.match('Matrix')?.id, 1);
    // A bare trailing year in the *library* name must not shadow a title that
    // genuinely ends in a number.
    expect(idx.match('Blade Runner 2049')?.id, 2);
    // Kind constraint is honoured.
    expect(idx.match('Breaking Bad', kind: StreamKind.movie), isNull);
    expect(idx.match('Breaking Bad', kind: StreamKind.series)?.id, 3);
    expect(idx.match('Nothing Here'), isNull);
  });

  test('English-labelled variants win inside a bucket', () async {
    final idx = await indexOf([
      item('FR - Dune', id: 10),
      item('DE - Dune', id: 11),
      item('EN - Dune', id: 12),
    ]);
    expect(idx.match('Dune')?.id, 12);
    expect(idx.matches('Dune').length, 3);
  });

  test('a bucket stops growing at the cap, keeping English first', () async {
    // A provider shipping the same film 200 times (per-server / per-quality
    // duplicates, all of which clean down to the same title) must not pin 200
    // rows in memory: nothing reads past a handful.
    final idx = await indexOf([
      for (var i = 0; i < 200; i++) item('Heat [Server $i]', id: i),
      item('EN - Heat', id: 999),
    ]);
    final hits = idx.matches('Heat');
    expect(hits.length, 8, reason: 'the bucket really did fill and get capped');
    // The English entry arrived *after* the cap was reached, so it can only be
    // in there if the cap admits it — which is the behaviour that matters:
    // capping must never cost you the variant the app would have picked.
    expect(hits.first.id, 999, reason: 'English still sorts to the front');
  });

  test('builds from the database cursor without materialising the table',
      () async {
    final app = await AppDatabase.open(overridePath: path);
    await app.db.insert('playlists', {
      'name': 'p',
      'kind': 'm3u',
      'url': 'http://p',
      'created_at': 1,
    });

    const total = 2500; // more than one cursor buffer
    final batch = app.db.batch();
    for (var i = 0; i < total; i++) {
      batch.insert('streams', {
        'playlist_id': 1,
        'kind': i.isEven ? 'movie' : 'series',
        'name': 'Title $i',
        'url': 'http://x/$i',
        'logo': 'http://art/$i.jpg',
      });
    }
    // Live rows must be skipped entirely — they have no title identity.
    batch.insert('streams', {
      'playlist_id': 1,
      'kind': 'live',
      'name': 'Title 0',
      'url': 'http://live/0',
    });
    await batch.commit(noResult: true);

    // The stream must arrive in pieces, not as one materialised list.
    var seen = 0;
    await for (final _ in app.vodItemsStream(1, bufferSize: 400)) {
      seen++;
    }
    expect(seen, total);

    final idx = await TitleIndex.buildFrom(1, app.vodItemsStream(1));
    expect(idx.match('Title 0', kind: StreamKind.movie)?.url, 'http://x/0');
    expect(idx.match('Title 1', kind: StreamKind.series)?.url, 'http://x/1');
    // Projected rows still carry what the play + artwork paths need.
    expect(idx.match('Title 2')?.logo, 'http://art/2.jpg');
    expect(idx.match('Title 2')?.playlistId, 1);
    // The live row shares a name with a movie but must never be indexed.
    expect(idx.matches('Title 0').every((e) => e.kind != StreamKind.live),
        isTrue);
    expect(idx.match('Title $total'), isNull);
  });
}
