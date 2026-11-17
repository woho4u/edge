// The band's compact battery reading, shared by Home's status line, the
// devices list and Profile.
//
// Charging used to be a 13 px icon swap between `battery` and
// `batteryCharging`, in the same muted ink — easy to miss at a glance. While
// the band is on the charger the reading now says the word too, in the same
// charging blue the battery widget already uses.
//
// The word comes from `devicesCharging`, the one string the app already
// translates for this state; the band detail row has used it for longer.

import '../l10n/app_localizations.dart';

/// "78%" normally, "Charging · 78%" while the band is on the charger.
String batteryReadingLabel(
  double pct, {
  required bool charging,
  AppLocalizations? l,
}) {
  final value = '${pct.round()}%';
  if (!charging) return value;
  return '${l?.devicesCharging ?? 'Charging'} · $value';
}
