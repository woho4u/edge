// Downloadable sleep model (cracked-whoop fork).
//
// The app ships with a sleep model built in (openstrap_analytics' embedded
// whoopsleep weights). A newer model of the same architecture can be
// published without rebuilding the app:
//
//   manifest  https://github.com/woho4u/edge/releases/download/whoopsleep-model/manifest.json
//             {"name": "v9_...", "format": "whoopsleep-dart-1",
//              "url": "https://.../v9_....bin", "sha256": "<hex>", "bytes": N}
//
// [checkForWhoopSleepModelUpdate] (on app foreground, at most daily) fetches
// the manifest, downloads a model it doesn't have, checks its size and
// SHA-256, makes the analytics code load it and stage a synthetic night
// (`whoopSleepSelfTest`), and only then swaps it into place. The caller then
// re-analyzes stored days.
//
// Every isolate that stages sleep calls [armWhoopSleepModel] first (from
// `calendarDays`): it hands the installed file to the analytics package when
// the file changed, and falls back to the built-in model when there is none
// or it is refused. The model lives at a path every isolate can compute on
// its own (iOS: the app container's Library/Application Support), so nothing
// has to be threaded through the many isolate entry points.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:openstrap_analytics/onehz.dart' as ana;

const String kWhoopSleepManifestUrl =
    'https://github.com/woho4u/edge/releases/download/whoopsleep-model/manifest.json';

/// How often the manifest is fetched at most.
const Duration kWhoopSleepCheckEvery = Duration(hours: 24);

/// Hard cap on a model download (the v8 model is ~5.8 MB).
const int kWhoopSleepMaxBytes = 64 << 20;

/// Directory holding the installed model, or null where downloaded models
/// are not supported (the built-in model is used). Computable on any
/// isolate.
String? whoopSleepModelDir() {
  if (debugWhoopSleepModelDir != null) return debugWhoopSleepModelDir;
  if (!Platform.isIOS) return null;
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) return null;
  return '$home/Library/Application Support/whoopsleep';
}

@visibleForTesting
String? debugWhoopSleepModelDir;

/// What is installed: the model's name, SHA-256 and when it was installed.
/// Null when the built-in model is in use.
typedef WhoopSleepInstalled = ({String name, String sha256, int installedMs});

File? _file(String name) {
  final dir = whoopSleepModelDir();
  return dir == null ? null : File('$dir/$name');
}

Map<String, dynamic> _readState() {
  try {
    final f = _file('state.json');
    if (f == null || !f.existsSync()) return {};
    return (jsonDecode(f.readAsStringSync()) as Map).cast<String, dynamic>();
  } catch (_) {
    return {};
  }
}

void _writeState(Map<String, dynamic> state) {
  final f = _file('state.json');
  if (f == null) return;
  f.parent.createSync(recursive: true);
  final tmp = File('${f.path}.tmp')..writeAsStringSync(jsonEncode(state));
  tmp.renameSync(f.path);
}

/// The installed model, or null when the built-in one is used.
WhoopSleepInstalled? installedWhoopSleepModel() {
  final s = _readState();
  final name = s['name'], sha = s['sha256'], at = s['installed_ms'];
  final model = _file('model.bin');
  if (name is! String || sha is! String || model == null) return null;
  if (!model.existsSync()) return null;
  return (name: name, sha256: sha, installedMs: (at as num?)?.toInt() ?? 0);
}

/// Name of the model sleep is staged with, for display. Reads only the
/// install record (no model decode), so it is safe on the UI thread.
String whoopSleepModelLabel() =>
    installedWhoopSleepModel()?.name ??
    '${ana.kWhoopSleepModelName} (built in)';

String? _armedStamp;

/// Make this isolate stage sleep with the installed model, if there is one
/// and it changed since the last call; otherwise with the built-in model.
/// Cheap when nothing changed (one stat). Never throws.
void armWhoopSleepModel() {
  try {
    final f = _file('model.bin');
    final st = f?.statSync();
    if (f == null || st == null || st.type == FileSystemEntityType.notFound) {
      if (_armedStamp != null) {
        ana.useWhoopSleepModel(null);
        _armedStamp = null;
      }
      return;
    }
    final stamp = '${st.modified.microsecondsSinceEpoch}:${st.size}';
    if (stamp == _armedStamp) return;
    _armedStamp = stamp;
    final err = ana.useWhoopSleepModel(f.readAsBytesSync(), key: stamp);
    if (err != null) {
      debugPrint('[sleep-model] installed model refused, using built-in: $err');
    }
  } catch (e) {
    debugPrint('[sleep-model] arm failed, using built-in: $e');
  }
}

/// Outcome of one update check.
enum WhoopSleepUpdate { notDue, unsupported, upToDate, installed, failed }

/// Fetch the manifest (unless checked within [kWhoopSleepCheckEvery] and not
/// [force]) and install a newer model. [installed] means the caller should
/// re-analyze stored days.
Future<WhoopSleepUpdate> checkForWhoopSleepModelUpdate({
  bool force = false,
  http.Client? client,
  String manifestUrl = kWhoopSleepManifestUrl,
  DateTime Function() now = DateTime.now,
}) async {
  if (whoopSleepModelDir() == null) return WhoopSleepUpdate.unsupported;
  final state = _readState();
  final checked = (state['checked_ms'] as num?)?.toInt() ?? 0;
  final nowMs = now().millisecondsSinceEpoch;
  if (!force &&
      nowMs - checked >= 0 &&
      nowMs - checked < kWhoopSleepCheckEvery.inMilliseconds) {
    return WhoopSleepUpdate.notDue;
  }
  final c = client ?? http.Client();
  try {
    final res = await c
        .get(Uri.parse(manifestUrl))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw HttpException('manifest HTTP ${res.statusCode}');
    }
    final m = (jsonDecode(res.body) as Map).cast<String, dynamic>();
    final name = m['name'] as String;
    final format = m['format'] as String;
    final url = m['url'] as String;
    final sha = (m['sha256'] as String).toLowerCase();
    final size = (m['bytes'] as num).toInt();
    _writeState({...state, 'checked_ms': nowMs});

    if (format != ana.kWhoopSleepBlobFormat) {
      // A model for a newer architecture: this build can't run it.
      debugPrint('[sleep-model] $name needs format $format; app update needed');
      return WhoopSleepUpdate.upToDate;
    }
    final have = installedWhoopSleepModel();
    if (have?.sha256 == sha) return WhoopSleepUpdate.upToDate;
    if (have == null && name == ana.kWhoopSleepModelName) {
      return WhoopSleepUpdate.upToDate; // the built-in model is the latest
    }
    if (size <= 0 || size > kWhoopSleepMaxBytes) {
      throw FormatException('model size $size');
    }

    final bin = await c.get(Uri.parse(url)).timeout(const Duration(minutes: 3));
    if (bin.statusCode != 200) {
      throw HttpException('model HTTP ${bin.statusCode}');
    }
    final bytes = bin.bodyBytes;
    if (bytes.length != size) {
      throw FormatException('model is ${bytes.length} bytes, expected $size');
    }
    if (sha256.convert(bytes).toString() != sha) {
      throw const FormatException('model checksum mismatch');
    }
    final err = await Isolate.run(
      () => ana.whoopSleepSelfTest(Uint8List.fromList(bytes)),
    );
    if (err != null) throw FormatException('model self-test: $err');

    final dest = _file('model.bin')!;
    dest.parent.createSync(recursive: true);
    final tmp = File('${dest.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(dest.path);
    _writeState({
      ..._readState(),
      'name': name,
      'sha256': sha,
      'installed_ms': nowMs,
    });
    armWhoopSleepModel();
    debugPrint('[sleep-model] installed $name');
    return WhoopSleepUpdate.installed;
  } catch (e) {
    debugPrint('[sleep-model] update check failed: $e');
    return WhoopSleepUpdate.failed;
  } finally {
    if (client == null) c.close();
  }
}

/// Remove the installed model; sleep is staged with the built-in one again.
/// Returns true when something was removed (the caller re-analyzes).
bool removeInstalledWhoopSleepModel() {
  final f = _file('model.bin');
  if (f == null || !f.existsSync()) return false;
  f.deleteSync();
  final s = _readState()
    ..remove('name')
    ..remove('sha256')
    ..remove('installed_ms');
  _writeState(s);
  armWhoopSleepModel();
  return true;
}
