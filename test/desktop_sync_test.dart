// Desktop sync (data/desktop_sync.dart): only changed days are sent, a day
// the store doesn't confirm is retried, and nothing runs without an address.
//
// End-to-end check against cracked-whoop's store on a real export (personal
// data never enters the repo):
//   DESKTOP_SYNC_DB=<export.db> DESKTOP_SYNC_OUT=<bundles.json> \
//     flutter test test/desktop_sync_test.dart
// then feed bundles.json to cracked-whoop tests/test_whoop_store.py.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openstrap_edge/data/desktop_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Map<String, Object?> _day(String date, double tst) => {
      'date': date,
      'source': 'band',
      'algo_version': 121,
      'finalized': true,
      'payload': {'x': tst},
      'metrics': {'tst_min': tst},
      'naps': [],
      'workouts': [],
    };

http.Client _store(List<List> posted, {bool confirmAll = true}) => MockClient((req) async {
      expect(req.url.path, '/whoop/api/days');
      final body = jsonDecode(req.body) as Map;
      expect(body['format'], 'whoop-day-1');
      final days = body['days'] as List;
      posted.add(days);
      return http.Response(
          jsonEncode({'stored': confirmAll ? days.length : days.length - 1, 'unchanged': 0}), 200);
    });

void main() {
  sqfliteFfiInit();

  final dbPath = Platform.environment['DESKTOP_SYNC_DB'];
  final outPath = Platform.environment['DESKTOP_SYNC_OUT'];
  test('dump bundles from a real export', () async {
    final db = await databaseFactoryFfi.openDatabase(dbPath!,
        options: OpenDatabaseOptions(readOnly: true));
    final days = await buildDayBundles(db);
    await db.close();
    expect(days, isNotEmpty);
    File(outPath!).writeAsStringSync(jsonEncode(
        {'format': kDayBundleFormat, 'timezone': 'Europe/Oslo', 'days': days}));
  }, skip: dbPath == null || outPath == null ? 'no real export given' : false);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    resetDesktopSyncThrottle();
  });

  test('on by default; off once the address is cleared', () async {
    expect(await desktopSyncEndpoint(), kDefaultDesktopSyncEndpoint);
    await setDesktopSyncEndpoint('');
    expect(await desktopSyncEndpoint(), isNull);
    expect(await syncToDesktop(force: true, days: () async => [_day('2026-11-10', 400)]), isNull);
  });

  test('rejects a non-https address', () async {
    expect(() => setDesktopSyncEndpoint('http://x.test/whoop'), throwsFormatException);
  });

  test('sends only changed days', () async {
    await setDesktopSyncEndpoint('https://desk.test/whoop/');
    final posted = <List>[];
    final client = _store(posted);
    var data = [_day('2026-11-10', 400), _day('2026-11-11', 410)];
    expect((await syncToDesktop(force: true, client: client, days: () async => data))!.sent, 2);
    expect((await syncToDesktop(force: true, client: client, days: () async => data))!.sent, 0);
    data = [_day('2026-11-10', 400), _day('2026-11-11', 420), _day('2026-11-12', 380)];
    expect((await syncToDesktop(force: true, client: client, days: () async => data))!.sent, 2);
    expect(posted.last.map((e) => e['date']), ['2026-11-11', '2026-11-12']);
  });

  test('an unconfirmed day is retried next time', () async {
    await setDesktopSyncEndpoint('https://desk.test/whoop');
    final data = [_day('2026-11-10', 400)];
    final r = await syncToDesktop(force: true, client: _store([], confirmAll: false), days: () async => data);
    expect(r!.ok, isFalse);
    expect(await desktopSyncLastResult(), contains('failed'));
    expect((await syncToDesktop(force: true, client: _store([]), days: () async => data))!.sent, 1);
  });

  test('throttles unforced syncs', () async {
    await setDesktopSyncEndpoint('https://desk.test/whoop');
    expect(await syncToDesktop(client: _store([]), days: () async => []), isNotNull);
    expect(await syncToDesktop(client: _store([]), days: () async => []), isNull);
  });

  test('batches cap days per request', () {
    final b = desktopSyncBatches([for (var i = 0; i < 25; i++) (_day('d$i', 1), 'x')]);
    expect(b.map((x) => x.length), [10, 10, 5]);
  });
}
