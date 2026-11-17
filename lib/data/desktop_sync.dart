// Desktop sync (cracked-whoop fork).
//
// After every derive pass and on foreground, the app POSTs each analysed day
// that changed since the last successful send to a day store on the user's
// own computer (cracked-whoop scripts/whoop_store.py, reached over Tailscale).
// Other tools (Normy, ...) read from that store, so adding or reshaping a
// consumer never needs an app build.
//
// One bundle per day, format 'whoop-day-1' (documented in whoop_store.py):
// the app's full computed day result (decoded, plain JSON), every daily
// scalar, confirmed naps and saved non-private workouts. Raw sensor samples
// never leave the phone. On by default, sending to the owner's desktop
// ([kDefaultDesktopSyncEndpoint]); Profile > Data > Desktop sync changes the
// address or, with an empty one, turns it off.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import 'db.dart';
import 'series_codec.dart';

const String kDayBundleFormat = 'whoop-day-1';

/// Where days go until the user sets another address (their own desktop,
/// reachable only inside their tailnet).
const String kDefaultDesktopSyncEndpoint = 'https://foundry.taile44e58.ts.net/whoop';

const int _maxDays = 10;
const int _maxBytes = 4 * 1024 * 1024;
const String _kEndpoint = 'desktop_sync_endpoint';
const String _kSent = 'desktop_sync_sent';
const String _kLast = 'desktop_sync_last_result';

String _two(int v) => v.toString().padLeft(2, '0');

String _localDate(num ts) {
  final t = DateTime.fromMillisecondsSinceEpoch((ts * 1000).floor());
  return '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)}';
}

/// Every analysed band day on or after [since], as day bundles.
///
/// The same day selection as the laptop exporter: the (date, algo_version)
/// stamp in metric_series_version picks the day_result row; partial, skipped
/// and cloud-imported days are left out.
Future<List<Map<String, Object?>>> buildDayBundles(DatabaseExecutor db,
    {String since = '0000-01-01'}) async {
  final days = <String, Map<String, Object?>>{};
  for (final r in await db.rawQuery('''
      SELECT v.date, v.algo_version, d.finalized, d.payload_json
      FROM metric_series_version v
      JOIN day_result d ON d.day_id = v.date AND d.algo_version = v.algo_version
      WHERE v.date >= ? AND v.source = 'band'
        AND d.partial = 0 AND d.skipped = 0 AND d.imported = 0
      ORDER BY v.date''', [since])) {
    final date = r['date'] as String;
    final payload = SeriesCodec.decodePayloadJson(r['payload_json']);
    if (payload == null) throw FormatException('$date: unreadable day payload');
    days[date] = {
      'date': date,
      'source': 'band',
      'algo_version': r['algo_version'],
      'finalized': r['finalized'] == 1,
      'payload': payload,
      'metrics': <String, Object?>{},
      'naps': <Map<String, Object?>>[],
      'workouts': <Map<String, Object?>>[],
    };
  }
  for (final r in await db.rawQuery(
      'SELECT date, key, value FROM metric_series WHERE date >= ? ORDER BY date, key',
      [since])) {
    final v = r['value'];
    if (v is num && v.isFinite) {
      (days[r['date']]?['metrics'] as Map?)?[r['key'] as String] = v;
    }
  }
  for (final r in await db.rawQuery(
      'SELECT day_id, start_ts, end_ts FROM sleep_nap WHERE day_id >= ? ORDER BY start_ts',
      [since])) {
    (days[r['day_id']]?['naps'] as List?)
        ?.add({'start': r['start_ts'], 'end': r['end_ts']});
  }
  for (final r in await db.rawQuery('''
      SELECT s.start_ts, s.end_ts, s.type,
             CASE WHEN m.session_id IS NULL THEN s.avg_hr END AS avg_hr,
             CASE WHEN m.session_id IS NULL THEN s.max_hr END AS max_hr
      FROM sessions s LEFT JOIN session_score_mask m ON m.session_id = s.id
      WHERE s.private = 0 AND s.end_ts IS NOT NULL AND s.end_ts_fabricated = 0
        AND s.end_ts > s.start_ts AND s.status != 'discarded'
      ORDER BY s.start_ts''')) {
    (days[_localDate(r['start_ts'] as num)]?['workouts'] as List?)?.add({
      'start': r['start_ts'],
      'end': r['end_ts'],
      'kind': r['type'],
      'avg_hr': r['avg_hr'],
      'max_hr': r['max_hr'],
    });
  }
  return days.values.toList();
}

/// Requests of at most [_maxDays] days and about [_maxBytes] bytes
/// (a single larger day goes alone).
List<List<(Map<String, Object?>, String)>> desktopSyncBatches(
    List<(Map<String, Object?>, String)> days) {
  final out = <List<(Map<String, Object?>, String)>>[];
  var batch = <(Map<String, Object?>, String)>[];
  var bytes = 0;
  for (final d in days) {
    final n = d.$2.length;
    if (batch.isNotEmpty && (batch.length == _maxDays || bytes + n > _maxBytes)) {
      out.add(batch);
      batch = [];
      bytes = 0;
    }
    batch.add(d);
    bytes += n;
  }
  if (batch.isNotEmpty) out.add(batch);
  return out;
}

/// Outcome of one sync, for the settings row.
class DesktopSyncResult {
  final int sent, stored, unchanged;
  final String? error;
  const DesktopSyncResult({this.sent = 0, this.stored = 0, this.unchanged = 0, this.error});
  bool get ok => error == null;
}

/// The store's base address; null when the user turned syncing off.
Future<String?> desktopSyncEndpoint() async {
  final v = (await SharedPreferences.getInstance()).getString(_kEndpoint)?.trim();
  if (v == null) return kDefaultDesktopSyncEndpoint; // never set
  return v.isEmpty ? null : v;
}

/// Set the address; null/empty turns syncing off. Any change forgets what was
/// sent, so a new store receives every day.
Future<void> setDesktopSyncEndpoint(String? url) async {
  final prefs = await SharedPreferences.getInstance();
  var v = url?.trim() ?? '';
  while (v.endsWith('/')) {
    v = v.substring(0, v.length - 1);
  }
  if (v.isEmpty) {
    await prefs.setString(_kEndpoint, ''); // off (absent means the default)
  } else {
    final uri = Uri.tryParse(v);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw const FormatException('the address must start with https://');
    }
    await prefs.setString(_kEndpoint, v);
  }
  await prefs.remove(_kSent);
  await prefs.remove(_kLast);
}

/// One line about the last sync ("" before the first one).
Future<String> desktopSyncLastResult() async =>
    (await SharedPreferences.getInstance()).getString(_kLast) ?? '';

Future<void>? _inFlight;
DateTime? _lastAttempt;

/// Send every day the store hasn't confirmed yet. No address → no-op.
/// Unforced syncs run at most every 2 minutes; never throws.
Future<DesktopSyncResult?> syncToDesktop({
  bool force = false,
  @visibleForTesting http.Client? client,
  @visibleForTesting Future<List<Map<String, Object?>>> Function()? days,
}) async {
  final SharedPreferences prefs;
  final String? endpoint;
  try {
    prefs = await SharedPreferences.getInstance();
    endpoint = await desktopSyncEndpoint();
  } catch (e) {
    return DesktopSyncResult(error: '$e');
  }
  if (endpoint == null) return null;
  final now = DateTime.now();
  if (!force && _lastAttempt != null && now.difference(_lastAttempt!) < const Duration(minutes: 2)) {
    return null;
  }
  while (_inFlight != null) {
    await _inFlight;
  }
  _lastAttempt = now;
  final done = Completer<void>();
  _inFlight = done.future;
  final c = client ?? http.Client();
  DesktopSyncResult result;
  try {
    var tz = 'Europe/Oslo';
    try {
      tz = await FlutterTimezone.getLocalTimezone();
    } catch (_) {}
    final all = await (days?.call() ?? LocalDb.withReadExecutor((db) => buildDayBundles(db)));
    final sent = Map<String, String>.from(jsonDecode(prefs.getString(_kSent) ?? '{}') as Map);
    final pending = <(Map<String, Object?>, String)>[];
    for (final d in all) {
      final text = jsonEncode(d);
      final hash = sha256.convert(utf8.encode(text)).toString();
      if (sent[d['date']] != hash) pending.add((d, hash));
    }
    var stored = 0, unchanged = 0;
    for (final batch in desktopSyncBatches([
      for (final (d, h) in pending) (d, h)
    ])) {
      final resp = await c
          .post(Uri.parse('$endpoint/api/days'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'format': kDayBundleFormat,
                'timezone': tz,
                'days': [for (final (d, _) in batch) d],
              }))
          .timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) {
        throw StateError('the desktop answered HTTP ${resp.statusCode}');
      }
      final body = jsonDecode(resp.body) as Map;
      final s = body['stored'], u = body['unchanged'];
      if (s is! int || u is! int || s < 0 || u < 0 || s + u != batch.length) {
        throw StateError('the desktop did not confirm every day: ${resp.body}');
      }
      stored += s;
      unchanged += u;
      for (final (d, h) in batch) {
        sent[d['date'] as String] = h;
      }
      await prefs.setString(_kSent, jsonEncode(sent));
    }
    result = DesktopSyncResult(sent: pending.length, stored: stored, unchanged: unchanged);
    if (pending.isNotEmpty || (prefs.getString(_kLast) ?? '').isEmpty) {
      await prefs.setString(_kLast, '${_stamp(now)}: sent ${pending.length} day(s)');
    }
  } catch (e) {
    result = DesktopSyncResult(error: '$e');
    await prefs.setString(_kLast, '${_stamp(now)}: failed, will retry ($e)');
  } finally {
    if (client == null) c.close();
    _inFlight = null;
    done.complete();
  }
  return result;
}

String _stamp(DateTime t) => '${_two(t.day)}.${_two(t.month)} ${_two(t.hour)}:${_two(t.minute)}';

@visibleForTesting
void resetDesktopSyncThrottle() => _lastAttempt = null;
