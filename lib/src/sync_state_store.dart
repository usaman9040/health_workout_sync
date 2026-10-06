import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Persistent sync state. Uses [SharedPreferencesAsync] (no in-memory cache)
/// on purpose: the main isolate, the Android WorkManager isolate and the iOS
/// background engine all read and write the same keys, and the cached
/// `SharedPreferences` API would let one isolate act on another's stale
/// cursor.
class SyncStateStore {
  SyncStateStore({
    String prefix = 'health_workout_sync',
    SharedPreferencesAsync? prefs,
  }) : _p = '$prefix.',
       _prefs = prefs ?? SharedPreferencesAsync();

  final String _p;
  final SharedPreferencesAsync _prefs;

  String _k(String key) => '$_p$key';

  // ── Connection ────────────────────────────────────────────────────────────

  /// Start of the day the user connected. Nothing before it is imported, so
  /// connecting never grants retroactive credit for old history.
  Future<DateTime?> connectedAt() => _date('connectedAt');
  Future<void> setConnectedAt(DateTime? value) =>
      _setDate('connectedAt', value);

  Future<bool> isConnected() async => (await connectedAt()) != null;

  /// First connection ever — survives disconnects (analytics / "welcome
  /// back" copy).
  Future<DateTime?> firstConnectedAt() => _date('firstConnectedAt');
  Future<void> setFirstConnectedAt(DateTime value) =>
      _setDate('firstConnectedAt', value);

  /// Set by an explicit disconnect so nothing silently reconnects.
  Future<DateTime?> disconnectedAt() => _date('disconnectedAt');
  Future<void> setDisconnectedAt(DateTime? value) =>
      _setDate('disconnectedAt', value);

  // ── Cursor ────────────────────────────────────────────────────────────────

  /// Opaque cursor: HealthKit anchor (base64 archive) or Health Connect
  /// changes token.
  Future<String?> cursor() => _prefs.getString(_k('cursor'));
  Future<void> setCursor(String? value) => _setString('cursor', value);

  /// Per-workout retry counts while the cursor is held.
  Future<Map<String, int>> stallCounts() async {
    final String? raw = await _prefs.getString(_k('stallCounts'));
    if (raw == null) return <String, int>{};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>).map(
        (String k, dynamic v) => MapEntry(k, (v as num).toInt()),
      );
    } catch (_) {
      return <String, int>{};
    }
  }

  Future<void> setStallCounts(Map<String, int> counts) => counts.isEmpty
      ? _prefs.remove(_k('stallCounts'))
      : _prefs.setString(_k('stallCounts'), jsonEncode(counts));

  // ── Sweep ─────────────────────────────────────────────────────────────────

  Future<DateTime?> lastSweepAt() => _date('lastSweepAt');
  Future<void> setLastSweepAt(DateTime? value) =>
      _setDate('lastSweepAt', value);

  Future<int> recheckAttempts() async =>
      await _prefs.getInt(_k('recheckAttempts')) ?? 0;
  Future<void> setRecheckAttempts(int value) => value == 0
      ? _prefs.remove(_k('recheckAttempts'))
      : _prefs.setInt(_k('recheckAttempts'), value);

  // ── Status ────────────────────────────────────────────────────────────────

  Future<DateTime?> lastSyncAt() => _date('lastSyncAt');
  Future<void> setLastSyncAt(DateTime? value) => _setDate('lastSyncAt', value);

  /// Last time a background trigger (observer / WorkManager) actually ran.
  Future<DateTime?> lastBackgroundSyncAt() => _date('lastBackgroundSyncAt');
  Future<void> setLastBackgroundSyncAt(DateTime value) =>
      _setDate('lastBackgroundSyncAt', value);

  /// Cross-isolate lease so the foreground and a background job don't both
  /// run a pass at once. Imports are idempotent, so a lost race only costs
  /// duplicate calls — this just avoids the waste.
  Future<bool> tryAcquireLease(Duration ttl) async {
    final DateTime now = DateTime.now();
    final DateTime? until = await _date('leaseUntil');
    if (until != null && until.isAfter(now)) return false;
    await _setDate('leaseUntil', now.add(ttl));
    return true;
  }

  Future<void> releaseLease() => _prefs.remove(_k('leaseUntil'));

  // ── Testing ───────────────────────────────────────────────────────────────

  /// Import workouts this app wrote itself (normally skipped). A testing aid
  /// for writing sample workouts from the host app's debug tools.
  Future<bool> includeOwnWrites() async =>
      await _prefs.getBool(_k('includeOwnWrites')) ?? false;
  Future<void> setIncludeOwnWrites(bool value) => value
      ? _prefs.setBool(_k('includeOwnWrites'), true)
      : _prefs.remove(_k('includeOwnWrites'));

  // ── Background ────────────────────────────────────────────────────────────

  /// Android WorkManager interval, in minutes.
  Future<int?> intervalMinutes() => _prefs.getInt(_k('intervalMinutes'));
  Future<void> setIntervalMinutes(int minutes) =>
      _prefs.setInt(_k('intervalMinutes'), minutes);

  /// Raw callback handle of the host app's background setup function.
  Future<int?> backgroundSetupHandle() =>
      _prefs.getInt(_k('backgroundSetupHandle'));
  Future<void> setBackgroundSetupHandle(int handle) =>
      _prefs.setInt(_k('backgroundSetupHandle'), handle);

  /// Clears everything tied to one connection (keeps first-connected, the
  /// interval preference and the callback handle).
  Future<void> clearConnection() async {
    for (final String key in <String>[
      'connectedAt',
      'cursor',
      'stallCounts',
      'lastSweepAt',
      'recheckAttempts',
      'lastSyncAt',
      'leaseUntil',
    ]) {
      await _prefs.remove(_k(key));
    }
  }

  /// Drops the cursor and sweep throttle so the next pass re-examines the
  /// whole window. Safe because imports are idempotent.
  Future<void> resetCursor() async {
    await _prefs.remove(_k('cursor'));
    await _prefs.remove(_k('stallCounts'));
    await _prefs.remove(_k('lastSweepAt'));
    await _prefs.remove(_k('recheckAttempts'));
  }

  // ── helpers ───────────────────────────────────────────────────────────────

  Future<DateTime?> _date(String key) async {
    final int? ms = await _prefs.getInt(_k(key));
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> _setDate(String key, DateTime? value) => value == null
      ? _prefs.remove(_k(key))
      : _prefs.setInt(_k(key), value.millisecondsSinceEpoch);

  Future<void> _setString(String key, String? value) =>
      value == null ? _prefs.remove(_k(key)) : _prefs.setString(_k(key), value);
}
