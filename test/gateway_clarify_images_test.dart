import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/gateway_clarify.dart';
import 'package:hermes_android/core/services/attachment_draft_service.dart';
import 'package:hermes_android/core/services/image_picker_recovery_guard.dart';
import 'package:hermes_android/core/widgets/gateway_clarify_dialog.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _gallery = Key('clarify-choose-images');
const _camera = Key('clarify-take-photo');
const _continue = Key('clarify-continue');
const _pickerChannel = MethodChannel('plugins.flutter.io/image_picker');

/// Only cache I/O is replaced; the real sequential upload/validation/retry
/// coordinator still runs. Sanitisation is covered by attachment_draft_service_test.
class _Drafts extends AttachmentDraftService {
  final prepared = <AttachmentDraft>[];
  final removed = <AttachmentDraft>[];
  Future<AttachmentDraft>? heldPreparation;
  Future<String>? heldRead;
  bool failPreparation = false;

  @override
  Future<AttachmentDraft> prepareImage({
    required String sourcePath,
    required String displayName,
    required Iterable<AttachmentDraft> existingDrafts,
    required AttachmentDraftMode mode,
  }) async {
    expect(mode, AttachmentDraftMode.remoteGateway);
    if (failPreparation) throw Exception('private picker detail');
    if (heldPreparation != null) return heldPreparation!;
    final draft = AttachmentDraft(
      id: '${prepared.length}',
      cachedPath: '/unused/clarify-${prepared.length}.png',
      name: displayName,
      byteLength: 4,
      mediaType: 'image/png',
      kind: AttachmentDraftKind.image,
      sanitized: true,
    );
    prepared.add(draft);
    return draft;
  }

  @override
  Future<String> readDataUrl(AttachmentDraft draft) async =>
      heldRead ?? 'data:image/png;base64,AQIDBA==';

  @override
  Future<void> removeCachedFile(AttachmentDraft draft) async {
    removed.add(draft);
  }
}

Future<void> _pumpDialog(
  WidgetTester tester, {
  required _Drafts drafts,
  required ClarifyResponder respond,
  AttachmentUploadCallback? upload,
  ClarifyRouteOwner? owns,
  List<String> choices = const [],
  bool multiSelect = false,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            child: const Text('Open question'),
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => GatewayClarifyDialog(
                request: GatewayClarifyRequest.fromEventData({
                  'request_id': 'image-question',
                  'question': 'Can you send a screenshot?',
                  'choices': choices,
                  'multi_select': multiSelect,
                })!,
                onRespond: respond,
                onUploadImage: upload,
                attachmentDraftService: drafts,
                canCloseRoute: owns,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open question'));
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, {bool camera = false}) async {
  final button = find.byKey(camera ? _camera : _gallery);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
  await tester.pump();
}

Future<void> _answer(WidgetTester tester) async {
  await tester.tap(find.byKey(_continue));
  await tester.pump();
  await tester.pump();
}

void main() {
  late List<String> pickedPaths;
  late List<MethodCall> pickerCalls;
  late Future<Object?> Function(MethodCall)? heldPicker;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    pickedPaths = ['/picker/screenshot.png'];
    pickerCalls = [];
    heldPicker = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pickerChannel, (call) async {
          pickerCalls.add(call);
          if (heldPicker != null) return heldPicker!(call);
          if (call.method == 'pickMultiImage') return pickedPaths;
          if (call.method == 'pickImage') {
            return pickedPaths.isEmpty ? null : pickedPaths.first;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pickerChannel, null);
  });

  testWidgets('a clarification offers gallery and camera image attachments', (
    tester,
  ) async {
    await _pumpDialog(
      tester,
      drafts: _Drafts(),
      respond: (_) async {},
      upload: ({required draft, required dataUrl}) async =>
          const AttachmentUploadReceipt(refText: '[Image: /host/image.png]'),
    );
    expect(find.byKey(_gallery), findsOneWidget);
    expect(find.byKey(_camera), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(_continue)).onPressed,
      isNull,
    );
  });

  testWidgets('unsupported consumers remain text only', (tester) async {
    await _pumpDialog(tester, drafts: _Drafts(), respond: (_) async {});
    expect(find.byKey(_gallery), findsNothing);
    expect(find.byKey(_camera), findsNothing);
  });

  testWidgets('cancelled native picker result is never prepared or uploaded', (
    tester,
  ) async {
    final picker = Completer<Object?>();
    heldPicker = (_) => picker.future;
    final drafts = _Drafts();
    var current = true;
    await _pumpDialog(
      tester,
      drafts: drafts,
      owns: () => current,
      respond: (_) => throw StateError('unexpected answer'),
      upload: ({required draft, required dataUrl}) =>
          throw StateError('unexpected upload'),
    );
    await _choose(tester);
    expect(pickerCalls, hasLength(1));
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(ImagePickerRecoveryGuard.pendingClarifyKey),
      contains('image-question'),
    );
    current = false;
    await tester.pumpWidget(const SizedBox.shrink());
    picker.complete(['/picker/late.png']);
    await tester.pump();
    await tester.pump();
    expect(drafts.prepared, isEmpty);
    expect(
      prefs.containsKey(ImagePickerRecoveryGuard.pendingClarifyKey),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('attachment controls remain usable on a phone with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pumpDialog(
      tester,
      drafts: _Drafts(),
      respond: (_) async {},
      textScale: 2,
      upload: ({required draft, required dataUrl}) async =>
          const AttachmentUploadReceipt(refText: '[Image: /host/image.png]'),
    );
    await _choose(tester);
    expect(find.text('screenshot.png'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ten images disable picking until an image is removed', (
    tester,
  ) async {
    pickedPaths = List.generate(10, (index) => '/picker/$index.png');
    await _pumpDialog(
      tester,
      drafts: _Drafts(),
      respond: (_) async {},
      upload: ({required draft, required dataUrl}) async =>
          AttachmentUploadReceipt(refText: '[Image: /host/${draft.name}]'),
    );
    await _choose(tester);
    expect(tester.widget<TextButton>(find.byKey(_gallery)).onPressed, isNull);
    expect(tester.widget<TextButton>(find.byKey(_camera)).onPressed, isNull);
    final remove = find.byKey(const ValueKey('clarify-remove-0'));
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pump();
    expect(
      tester.widget<TextButton>(find.byKey(_gallery)).onPressed,
      isNotNull,
    );
  });

  testWidgets('image-only answer uploads only on Continue and sends host ref', (
    tester,
  ) async {
    final drafts = _Drafts();
    final uploaded = <String>[];
    final answers = <String>[];
    await _pumpDialog(
      tester,
      drafts: drafts,
      respond: (answer) async => answers.add(answer),
      upload: ({required draft, required dataUrl}) async {
        expect(dataUrl, 'data:image/png;base64,AQIDBA==');
        uploaded.add(draft.name);
        return const AttachmentUploadReceipt(
          refText: '[Image: /host/image.png]',
        );
      },
    );
    await _choose(tester);
    expect(drafts.prepared.single.name, 'screenshot.png');
    expect(uploaded, isEmpty);
    expect(answers, isEmpty);
    expect(
      tester.widget<FilledButton>(find.byKey(_continue)).onPressed,
      isNotNull,
    );
    await _answer(tester);
    await tester.pumpAndSettle();
    expect(uploaded, ['screenshot.png']);
    expect(answers, ['[Image: /host/image.png]']);
    expect(drafts.removed, contains(drafts.prepared.single));
    expect(find.text('Open question'), findsOneWidget);
  });

  testWidgets('camera uses bounded capture and includes caption with image', (
    tester,
  ) async {
    final answers = <String>[];
    await _pumpDialog(
      tester,
      drafts: _Drafts(),
      respond: (answer) async => answers.add(answer),
      upload: ({required draft, required dataUrl}) async =>
          const AttachmentUploadReceipt(refText: '[Image: /host/photo.png]'),
    );
    await _choose(tester, camera: true);
    expect(pickerCalls.single.method, 'pickImage');
    expect(pickerCalls.single.arguments, containsPair('source', 0));
    expect(pickerCalls.single.arguments, containsPair('maxWidth', 1600.0));
    expect(pickerCalls.single.arguments, containsPair('imageQuality', 75));
    await tester.enterText(
      find.byKey(const Key('clarify-other-field')),
      'The broken display',
    );
    await _answer(tester);
    await tester.pumpAndSettle();
    expect(answers, ['The broken display\n\n[Image: /host/photo.png]']);
  });

  testWidgets('multiple selections and choices preserve source order', (
    tester,
  ) async {
    pickedPaths = ['/picker/one.png', '/picker/two.png'];
    final answers = <String>[];
    await _pumpDialog(
      tester,
      drafts: _Drafts(),
      respond: (answer) async => answers.add(answer),
      choices: ['First', 'Second'],
      multiSelect: true,
      upload: ({required draft, required dataUrl}) async =>
          AttachmentUploadReceipt(refText: '[Image: /host/${draft.name}]'),
    );
    await tester.tap(find.byKey(const Key('clarify-choice-1')));
    await tester.tap(find.byKey(const Key('clarify-choice-0')));
    await _choose(tester);
    await _answer(tester);
    await tester.pumpAndSettle();
    expect(answers, [
      'First, Second\n\n[Image: /host/one.png]\n\n[Image: /host/two.png]',
    ]);
  });

  testWidgets('upload failure keeps images; retry reuses successful uploads', (
    tester,
  ) async {
    pickedPaths = ['/picker/one.png', '/picker/two.png'];
    final drafts = _Drafts();
    final uploaded = <String>[];
    final answers = <String>[];
    var fail = true;
    await _pumpDialog(
      tester,
      drafts: drafts,
      respond: (answer) async => answers.add(answer),
      upload: ({required draft, required dataUrl}) async {
        uploaded.add(draft.name);
        if (draft.name == 'two.png' && fail) {
          throw Exception('private upload detail');
        }
        return AttachmentUploadReceipt(refText: '[Image: /host/${draft.name}]');
      },
    );
    await _choose(tester);
    await _answer(tester);
    expect(answers, isEmpty);
    expect(find.byKey(const Key('clarify-error')), findsOneWidget);
    expect(find.textContaining('private upload detail'), findsNothing);
    expect(drafts.prepared.last.status, AttachmentDraftStatus.failed);
    fail = false;
    await _answer(tester);
    await tester.pumpAndSettle();
    expect(uploaded, ['one.png', 'two.png', 'two.png']);
    expect(answers, ['[Image: /host/one.png]\n\n[Image: /host/two.png]']);
  });

  testWidgets('answer failure retries refs without uploading deleted caches', (
    tester,
  ) async {
    var uploads = 0;
    var responses = 0;
    await _pumpDialog(
      tester,
      drafts: _Drafts(),
      respond: (_) async {
        if (++responses == 1) throw Exception('answer rejected');
      },
      upload: ({required draft, required dataUrl}) async {
        uploads++;
        return const AttachmentUploadReceipt(
          refText: '[Image: /host/image.png]',
        );
      },
    );
    await _choose(tester);
    await _answer(tester);
    expect(find.byKey(const Key('clarify-error')), findsOneWidget);
    await _answer(tester);
    await tester.pumpAndSettle();
    expect(uploads, 1);
    expect(responses, 2);
  });

  testWidgets('Skip never uploads selected images and sends empty answer', (
    tester,
  ) async {
    final drafts = _Drafts();
    final answers = <String>[];
    await _pumpDialog(
      tester,
      drafts: drafts,
      respond: (answer) async => answers.add(answer),
      upload: ({required draft, required dataUrl}) =>
          throw StateError('unexpected upload'),
    );
    await _choose(tester);
    await tester.tap(find.byKey(const Key('clarify-skip')));
    await tester.pumpAndSettle();
    expect(answers, ['']);
    expect(drafts.removed, contains(drafts.prepared.single));
  });

  testWidgets('removing selected image prevents upload and disables Continue', (
    tester,
  ) async {
    final drafts = _Drafts();
    await _pumpDialog(
      tester,
      drafts: drafts,
      respond: (_) async {},
      upload: ({required draft, required dataUrl}) =>
          throw StateError('unexpected upload'),
    );
    await _choose(tester);
    final remove = find.byKey(const ValueKey('clarify-remove-0'));
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pump();
    expect(drafts.removed, [drafts.prepared.single]);
    expect(
      tester.widget<FilledButton>(find.byKey(_continue)).onPressed,
      isNull,
    );
  });

  testWidgets('picker cancellation and sanitisation failure do not answer', (
    tester,
  ) async {
    pickedPaths = [];
    final drafts = _Drafts();
    final answers = <String>[];
    await _pumpDialog(
      tester,
      drafts: drafts,
      respond: (answer) async => answers.add(answer),
      upload: ({required draft, required dataUrl}) =>
          throw StateError('unexpected upload'),
    );
    await _choose(tester);
    expect(drafts.prepared, isEmpty);
    expect(find.byKey(const Key('clarify-error')), findsNothing);
    pickedPaths = ['/picker/bad.png'];
    drafts.failPreparation = true;
    await _choose(tester);
    expect(find.byKey(const Key('clarify-error')), findsOneWidget);
    expect(find.textContaining('private picker detail'), findsNothing);
    expect(answers, isEmpty);
    expect(
      tester.widget<FilledButton>(find.byKey(_continue)).onPressed,
      isNull,
    );
  });

  testWidgets('duplicate Continue while upload is pending sends once', (
    tester,
  ) async {
    final held = Completer<AttachmentUploadReceipt>();
    final answers = <String>[];
    var uploads = 0;
    await _pumpDialog(
      tester,
      drafts: _Drafts(),
      respond: (answer) async => answers.add(answer),
      upload: ({required draft, required dataUrl}) {
        uploads++;
        return held.future;
      },
    );
    await _choose(tester);
    final submit = tester
        .widget<FilledButton>(find.byKey(_continue))
        .onPressed!;
    submit();
    submit();
    await tester.pump();
    expect(uploads, 1);
    expect(answers, isEmpty);
    expect(
      tester.widget<FilledButton>(find.byKey(_continue)).onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('clarify-skip')))
          .onPressed,
      isNull,
    );
    // Back means Skip only before submission. It cannot send a second empty
    // answer while the accepted file.attach/clarify.lock is in flight.
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(GatewayClarifyDialog), findsOneWidget);
    expect(answers, isEmpty);
    held.complete(
      const AttachmentUploadReceipt(refText: '[Image: /host/image.png]'),
    );
    await tester.pumpAndSettle();
    expect(answers, ['[Image: /host/image.png]']);
  });

  testWidgets('cancellation during upload cannot answer or pop a newer route', (
    tester,
  ) async {
    final held = Completer<AttachmentUploadReceipt>();
    var current = true;
    final answers = <String>[];
    await _pumpDialog(
      tester,
      drafts: _Drafts(),
      owns: () => current,
      respond: (answer) async => answers.add(answer),
      upload: ({required draft, required dataUrl}) => held.future,
    );
    await _choose(tester);
    await _answer(tester);
    current = false;
    final context = tester.element(find.byType(GatewayClarifyDialog));
    Navigator.of(context).pop(false);
    await tester.pumpAndSettle();
    held.complete(
      const AttachmentUploadReceipt(refText: '[Image: /host/late.png]'),
    );
    await tester.pumpAndSettle();
    expect(answers, isEmpty);
    expect(find.text('Open question'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposed pending preparation cleans late draft without upload', (
    tester,
  ) async {
    final prepared = Completer<AttachmentDraft>();
    final drafts = _Drafts()..heldPreparation = prepared.future;
    await _pumpDialog(
      tester,
      drafts: drafts,
      respond: (_) => throw StateError('unexpected answer'),
      upload: ({required draft, required dataUrl}) =>
          throw StateError('unexpected upload'),
    );
    await _choose(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    final lateDraft = AttachmentDraft(
      id: 'late',
      cachedPath: '/unused/late.png',
      name: 'late.png',
      byteLength: 4,
      mediaType: 'image/png',
      kind: AttachmentDraftKind.image,
      sanitized: true,
    );
    prepared.complete(lateDraft);
    await tester.pump();
    await tester.pump();
    expect(drafts.removed, [lateDraft]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelled question after file read never starts upload', (
    tester,
  ) async {
    final read = Completer<String>();
    final drafts = _Drafts()..heldRead = read.future;
    var current = true;
    await _pumpDialog(
      tester,
      drafts: drafts,
      owns: () => current,
      respond: (_) => throw StateError('unexpected answer'),
      upload: ({required draft, required dataUrl}) =>
          throw StateError('unexpected upload'),
    );
    await _choose(tester);
    await _answer(tester);
    current = false;
    read.complete('data:image/png;base64,AQIDBA==');
    await tester.pump();
    await tester.pump();
    expect(drafts.prepared.single.status, AttachmentDraftStatus.failed);
    expect(tester.takeException(), isNull);
  });
}
