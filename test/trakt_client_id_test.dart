import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/data/db/app_database.dart';
import 'package:lumen/data/repositories/library_repository.dart';
import 'package:lumen/data/sources/trakt_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The bug this pins is invisible from the outside and cost the whole Trakt
/// integration: connecting goes through the Worker, which holds the rotated
/// credentials, so the access token belongs to *that* Trakt app — while every
/// read sent the embedded client id, which is committed to a public repo and no
/// longer valid. Trakt answers a token/key mismatch with a bare `403 Forbidden`,
/// which the app then fed to jsonDecode. Hence "Trakt connected" alongside a
/// sanity check where every single list failed.
///
/// The invariant: the key we read with must be the one that minted the token,
/// unless the user has deliberately supplied their own.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory dir;
  late LibraryRepository repo;
  late TraktService svc;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lumen_trakt_test');
    AppDatabase.resetForTest();
    final db = await AppDatabase.open(overridePath: '${dir.path}/lumen.db');
    repo = LibraryRepository(db);
    svc = TraktService(repo);
  });

  tearDown(() async {
    AppDatabase.resetForTest();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('falls back to the embedded id when nothing else is known', () async {
    expect(await svc.getClientIdForUi(), isNotEmpty);
    expect(svc.hasEmbeddedCredentials, isTrue);
  });

  test('the server id beats the embedded one', () async {
    await repo.setSetting('trakt_server_client_id', 'server-key');
    expect(await svc.getClientIdForUi(), 'server-key');
  });

  test('the user\'s own credentials beat everything', () async {
    await repo.setSetting('trakt_server_client_id', 'server-key');
    await repo.setSetting('trakt_client_id', 'my-own-key');
    expect(await svc.getClientIdForUi(), 'my-own-key');
  });

  test('an empty stored value does not shadow the fallback', () async {
    await repo.setSetting('trakt_client_id', '');
    await repo.setSetting('trakt_server_client_id', '');
    expect(await svc.getClientIdForUi(), isNotEmpty,
        reason: 'blank settings must fall through, not resolve to ""');
  });

  group('failure descriptions', () {
    Response res(int status, String body) =>
        Response(requestOptions: RequestOptions(path: '/'),
            statusCode: status, data: body);

    test('an HTML 403 is named as the edge block it is', () {
      final msg = TraktService.describeFailure(res(403, '<!DOCTYPE html>...'));
      expect(msg.toLowerCase(), contains('cloudflare'));
    });

    test('a plain 403 points at the API key', () {
      final msg = TraktService.describeFailure(res(403, 'Forbidden'));
      expect(msg.toLowerCase(), contains('api key'));
    });

    test('rate limiting says so instead of showing a status code', () {
      expect(TraktService.describeFailure(res(429, 'error code: 1015'))
          .toLowerCase(), contains('rate limited'));
    });

    test('an empty body is described, never parsed', () {
      // This is the exact shape that surfaced as
      // "FormatException: Unexpected end of input (at character 1)".
      final msg = TraktService.describeFailure(res(500, ''));
      expect(msg, contains('empty response body'));
    });
  });
}
