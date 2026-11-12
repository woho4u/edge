// Downloadable sleep model (compute/whoopsleep_model_store.dart): a published
// model is downloaded, verified and installed once; a bad download is never
// installed; the built-in model stays in use until something valid lands.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openstrap_edge/compute/whoopsleep_model_store.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_analytics/src/onehz/sleep/whoopsleep/whoopsleep_weights.g.dart';

const _manifest = 'https://example.test/manifest.json';
const _bin = 'https://example.test/model.bin';

/// The built-in model re-labelled [name] (header rewritten, data kept).
Uint8List _renamed(String name) {
  final bytes = Uint8List.fromList(base64.decode(kWhoopSleepWeightsB64.join()));
  final hlen = ByteData.sublistView(bytes, 4, 8).getUint32(0, Endian.little);
  final header = utf8.decode(bytes.sublist(8, 8 + hlen));
  final hb = utf8.encode(
    header.replaceFirst(
      '"model":"${ana.kWhoopSleepModelName}"',
      '"model":"$name"',
    ),
  );
  final pad = (8 - (8 + hb.length) % 8) % 8;
  final origPad = (8 - (8 + hlen) % 8) % 8;
  final hdr = [...hb, ...List.filled(pad, 0x20)];
  return (BytesBuilder()
        ..add(bytes.sublist(0, 4))
        ..add(
          (ByteData(
            4,
          )..setUint32(0, hdr.length, Endian.little)).buffer.asUint8List(),
        )
        ..add(hdr)
        ..add(bytes.sublist(8 + hlen + origPad)))
      .toBytes();
}

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('wsmodel');
    debugWhoopSleepModelDir = dir.path;
  });
  tearDown(() {
    removeInstalledWhoopSleepModel();
    debugWhoopSleepModelDir = null;
    armWhoopSleepModel();
    dir.deleteSync(recursive: true);
  });

  MockClient server(Uint8List model, {String? sha, String name = 'v9_test'}) {
    var downloads = 0;
    final c = MockClient((req) async {
      if (req.url.toString() == _manifest) {
        return http.Response(
          jsonEncode({
            'name': name,
            'format': ana.kWhoopSleepBlobFormat,
            'url': _bin,
            'sha256': sha ?? sha256.convert(model).toString(),
            'bytes': model.length,
          }),
          200,
        );
      }
      if (req.url.toString() == _bin) {
        downloads++;
        return http.Response.bytes(model, 200);
      }
      return http.Response('', 404);
    });
    _downloads[c] = () => downloads;
    return c;
  }

  test('installs a published model once, then is up to date', () async {
    expect(whoopSleepModelLabel(), contains('(built in)'));
    final model = _renamed('v9_test');
    final c = server(model);
    expect(
      await checkForWhoopSleepModelUpdate(client: c, manifestUrl: _manifest),
      WhoopSleepUpdate.installed,
    );
    expect(installedWhoopSleepModel()?.name, 'v9_test');
    expect(whoopSleepModelLabel(), 'v9_test');
    expect(ana.whoopSleepActiveModelName(), 'v9_test');
    // Within a day: not even the manifest is fetched.
    expect(
      await checkForWhoopSleepModelUpdate(client: c, manifestUrl: _manifest),
      WhoopSleepUpdate.notDue,
    );
    expect(
      await checkForWhoopSleepModelUpdate(
        client: c,
        manifestUrl: _manifest,
        force: true,
      ),
      WhoopSleepUpdate.upToDate,
    );
    expect(_downloads[c]!(), 1);
    // Back to built-in.
    expect(removeInstalledWhoopSleepModel(), isTrue);
    expect(ana.whoopSleepActiveModelName(), ana.kWhoopSleepModelName);
  });

  test('the built-in model being the latest downloads nothing', () async {
    final c = server(
      _renamed(ana.kWhoopSleepModelName),
      name: ana.kWhoopSleepModelName,
    );
    expect(
      await checkForWhoopSleepModelUpdate(client: c, manifestUrl: _manifest),
      WhoopSleepUpdate.upToDate,
    );
    expect(_downloads[c]!(), 0);
    expect(installedWhoopSleepModel(), isNull);
  });

  test('a corrupt or broken download is never installed', () async {
    final model = _renamed('v9_test');
    // Checksum mismatch.
    expect(
      await checkForWhoopSleepModelUpdate(
        client: server(model, sha: '0' * 64),
        manifestUrl: _manifest,
      ),
      WhoopSleepUpdate.failed,
    );
    // Right checksum, but not a runnable model.
    final junk = Uint8List.fromList(List.filled(4096, 7));
    expect(
      await checkForWhoopSleepModelUpdate(
        client: server(junk),
        manifestUrl: _manifest,
        force: true,
      ),
      WhoopSleepUpdate.failed,
    );
    expect(installedWhoopSleepModel(), isNull);
    expect(File('${dir.path}/model.bin').existsSync(), isFalse);
    expect(ana.whoopSleepActiveModelName(), ana.kWhoopSleepModelName);
  });
}

final _downloads = Expando<int Function()>();
