// The compact battery reading shared by Home, the devices list and Profile.
// Charging used to be a 13 px icon swap in the same muted ink; the label now
// spells the state out so a glance cannot miss it.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/battery_reading.dart';

void main() {
  test('draining shows the level alone', () {
    expect(batteryReadingLabel(78, charging: false), '78%');
  });

  test('charging names the state beside the level', () {
    expect(batteryReadingLabel(78, charging: true), 'Charging · 78%');
  });

  test('the level still rounds the way the chip always did', () {
    expect(batteryReadingLabel(78.6, charging: false), '79%');
  });
}
