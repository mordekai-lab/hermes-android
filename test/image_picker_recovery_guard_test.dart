import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/image_picker_recovery_guard.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const key = ImagePickerRecoveryGuard.pendingClarifyKey;
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'persist purpose and exact owner before opening native picker',
    () async {
      final result = await ImagePickerRecoveryGuard.pickForClarification(
        owner: 'connection/session/request::q1',
        pick: () async {
          final prefs = await SharedPreferences.getInstance();
          final marker = jsonDecode(prefs.getString(key)!) as Map;
          expect(marker['purpose'], 'clarify');
          expect(marker['owner'], 'connection/session/request::q1');
          expect(marker['token'], isNotEmpty);
          return 'picked';
        },
      );
      expect(result, 'picked');
      expect((await SharedPreferences.getInstance()).containsKey(key), isFalse);
    },
  );

  test('native picker cancellation/error clears marker', () async {
    await expectLater(
      ImagePickerRecoveryGuard.pickForClarification(
        owner: 'request::q1',
        pick: () async => throw StateError('cancelled'),
      ),
      throwsStateError,
    );
    expect((await SharedPreferences.getInstance()).containsKey(key), isFalse);
  });

  test(
    'cold clarification marker discards result before composer receives it',
    () async {
      SharedPreferences.setMockInitialValues({
        key:
            '{"purpose":"clarify","owner":"other-chat/request::q1","token":"old-process"}',
      });
      final response = LostDataResponse(
        files: [XFile('/picker/image.png')],
        type: RetrieveType.image,
      );
      expect(
        await ImagePickerRecoveryGuard.recoverForComposer(() async => response),
        isNull,
      );
      expect((await SharedPreferences.getInstance()).containsKey(key), isFalse);
    },
  );

  test(
    'empty cache keeps the fence until a late native result arrives',
    () async {
      SharedPreferences.setMockInitialValues({key: 'old-clarification-marker'});
      final prefs = await SharedPreferences.getInstance();
      expect(
        await ImagePickerRecoveryGuard.recoverForComposer(
          () async => LostDataResponse.empty(),
        ),
        isNull,
      );
      expect(prefs.getString(key), 'old-clarification-marker');
      final lateResult = LostDataResponse(
        files: [XFile('/picker/late.png')],
        type: RetrieveType.image,
      );
      expect(
        await ImagePickerRecoveryGuard.recoverForComposer(
          () async => lateResult,
        ),
        isNull,
      );
      expect(prefs.containsKey(key), isFalse);
      final composerResult = LostDataResponse(
        files: [XFile('/picker/composer.png')],
        type: RetrieveType.image,
      );
      expect(
        await ImagePickerRecoveryGuard.recoverForComposer(
          () async => composerResult,
        ),
        same(composerResult),
      );
    },
  );

  test('ordinary composer recovery preserves exact native response', () async {
    final response = LostDataResponse(
      files: [XFile('/picker/image.png')],
      type: RetrieveType.image,
    );
    expect(
      await ImagePickerRecoveryGuard.recoverForComposer(() async => response),
      same(response),
    );
  });

  test(
    'failed lost-data retrieval retains clarification marker for retry',
    () async {
      SharedPreferences.setMockInitialValues({key: 'old-clarification-marker'});
      await expectLater(
        ImagePickerRecoveryGuard.recoverForComposer(
          () async => throw StateError('platform not ready'),
        ),
        throwsStateError,
      );
      expect(
        (await SharedPreferences.getInstance()).getString(key),
        'old-clarification-marker',
      );
      expect(
        await ImagePickerRecoveryGuard.recoverForComposer(
          () async => LostDataResponse.empty(),
        ),
        isNull,
      );
      expect(
        (await SharedPreferences.getInstance()).getString(key),
        'old-clarification-marker',
      );
    },
  );

  test(
    'same-process recovery cannot consume an active clarification picker',
    () async {
      final entered = Completer<void>();
      final picked = Completer<String>();
      final work = ImagePickerRecoveryGuard.pickForClarification(
        owner: 'request::q1',
        pick: () {
          entered.complete();
          return picked.future;
        },
      );
      await entered.future;
      var retrieves = 0;
      expect(
        await ImagePickerRecoveryGuard.recoverForComposer(() async {
          retrieves++;
          return LostDataResponse.empty();
        }),
        isNull,
      );
      expect(retrieves, 0);
      await expectLater(
        ImagePickerRecoveryGuard.pickForClarification(
          owner: 'request::q2',
          pick: () async => 'unexpected',
        ),
        throwsStateError,
      );
      picked.complete('image');
      expect(await work, 'image');
      expect((await SharedPreferences.getInstance()).containsKey(key), isFalse);
    },
  );
}
