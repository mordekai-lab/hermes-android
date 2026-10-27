import 'dart:async';
import 'dart:convert';

import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// image_picker has one process-wide lost-result cache on Android. A picker
/// opened for a clarification must never recover into a normal chat draft.
abstract final class ImagePickerRecoveryGuard {
  static const pendingClarifyKey = 'clarify_image_picker_owner.v1';
  static Future<void>? _tail;
  static String? _activePicker;

  static Future<T> _serialized<T>(Future<T> Function() action) async {
    final previous = _tail;
    final done = Completer<void>();
    final tail = done.future;
    _tail = tail;
    try {
      if (previous != null) await previous;
      return await action();
    } finally {
      done.complete();
      if (identical(_tail, tail)) _tail = null;
    }
  }

  static Future<T> pickForClarification<T>({
    required String owner,
    required Future<T> Function() pick,
  }) async {
    if (_activePicker != null) {
      throw StateError('An image picker is already open');
    }
    final token = const Uuid().v4();
    final marker = jsonEncode({
      'purpose': 'clarify',
      'owner': owner,
      'token': token,
    });
    _activePicker = token;
    try {
      await _serialized(() async {
        final prefs = await SharedPreferences.getInstance();
        if (!await prefs.setString(pendingClarifyKey, marker)) {
          throw StateError('Unable to record the image picker owner');
        }
      });
      return await pick();
    } finally {
      try {
        await _serialized(() async {
          final prefs = await SharedPreferences.getInstance();
          if (prefs.getString(pendingClarifyKey) == marker &&
              !await prefs.remove(pendingClarifyKey)) {
            throw StateError('Unable to clear the image picker owner');
          }
        });
      } finally {
        if (_activePicker == token) _activePicker = null;
      }
    }
  }

  /// Returns null for a clarification-origin lost result (including a stale
  /// marker with no result). Do not restore its request heuristically: a cold
  /// process cannot prove that exact question/connection is still current.
  /// Keep the marker until a populated result is retrieved: Android copies
  /// content-provider images asynchronously, so an empty cache is not proof
  /// that its old picker has finished producing a result.
  static Future<LostDataResponse?> recoverForComposer(
    Future<LostDataResponse> Function() retrieve,
  ) => _serialized(() async {
    if (_activePicker != null) return null;
    final prefs = await SharedPreferences.getInstance();
    final marker = prefs.getString(pendingClarifyKey);
    final response = await retrieve();
    if (marker == null) return response;
    if (response.isEmpty) return null;
    if (prefs.getString(pendingClarifyKey) == marker &&
        !await prefs.remove(pendingClarifyKey)) {
      throw StateError('Unable to clear the recovered image picker owner');
    }
    // Only discard plugin-owned results. Do not delete arbitrary picker paths
    // that could name the user's original photo; normal OS cache eviction is
    // safer. No attachment preparation or upload occurs for these files.
    return null;
  });
}
