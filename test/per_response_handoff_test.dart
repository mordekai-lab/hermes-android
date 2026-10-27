import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/gateway_turn_contract.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/attachment_draft_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_client.dart';
import 'package:hermes_android/core/services/gateway_turn_application_controller.dart';
import 'package:hermes_android/core/services/gateway_turn_coordinator.dart';
import 'package:hermes_android/core/services/gateway_turn_recovery.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_composer_adapter.dart';
import 'support/completed_stock_turn.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

const _clientTurnId = '123e4567-e89b-42d3-a456-426614174000';
const _turnId = 'server-turn';
const _messageId = 'server-assistant-message';
const _manifestDigest =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  for (final includeFirst in [false, true]) {
    testWidgets(
      'QUALITY84 per-response handoff preserves earlier failed output (physicalFirst=$includeFirst)',
      (tester) async {
        SharedPreferences.setMockInitialValues({'verbose_mode': true});
        await tester.binding.setSurfaceSize(const Size(1000, 2000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        String? exported;
        String? copied;
        const share = MethodChannel('dev.fluttercommunity.plus/share');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(share, (
          call,
        ) async {
          exported = (call.arguments as Map)['text'] as String?;
          return 'success';
        });
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String?;
            }
            return null;
          },
        );
        addTearDown(() {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            share,
            null,
          );
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
        });
        final history = _QualityHistory();
        final owner = _QualitySequence();
        await _pumpChat(
          tester,
          turnSession: owner,
          apiClient: ApiClient(
            baseUrl: 'http://recovery.fixture',
            apiKey: 'fixture',
            httpClient: history,
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'First prompt');
        await tester.tap(find.byTooltip('Send'));
        await tester.pumpAndSettle();
        expect(find.text('First failed output'), findsOneWidget);
        // A failed response's received material survives an empty physical read.
        await tester.tap(find.byTooltip('Chat actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();
        expect(find.text('First failed output'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'Second prompt');
        await tester.tap(find.byTooltip('Send'));
        await tester.pumpAndSettle();
        expect(owner.submitCount, 2);
        expect(find.text('First failed output'), findsOneWidget);
        expect(find.text('Second success'), findsOneWidget);
        history.rows = [
          if (includeFirst)
            {'id': 7, 'role': 'assistant', 'content': 'First failed output'},
          {'id': 16, 'role': 'user', 'content': 'Second prompt'},
          {'id': 17, 'role': 'assistant', 'content': 'Second success'},
        ];
        await tester.tap(find.byTooltip('Chat actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();
        expect(find.text('Second success'), findsOneWidget);
        expect(
          find.text('First failed output'),
          findsOneWidget,
          reason:
              'A saved final_message_ref for response B cannot retire unmatched failed response A',
        );
        final bubbles = tester
            .widgetList<MessageBubble>(find.byType(MessageBubble))
            .toList();
        final first = bubbles.singleWhere(
          (b) => b.content == 'First failed output',
        );
        expect(first.metadata['_gateway_response_outcome'], 'failed');
        expect(first.metadata['_chat_response_complete'], isFalse);
        expect(first.metadata['id'], includeFirst ? 7 : isNull);
        expect(
          bubbles.indexOf(first),
          lessThan(bubbles.indexWhere((b) => b.content == 'Second success')),
        );
        expect(find.textContaining('Turn failed'), findsWidgets);
        await tester.tap(find.byTooltip('Chat actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Export / share'));
        await tester.pumpAndSettle();
        expect(exported, contains('First failed output'));
        expect(exported, contains('Second success'));
        expect(exported, contains('Turn failed'));
        await tester.longPress(find.text('First failed output'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Copy message'));
        await tester.pumpAndSettle();
        expect(copied, 'First failed output');
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}

Future<void> _pumpChat(
  WidgetTester tester, {
  required _FakeTurnSession turnSession,
  Session chatSession = const Session(
    id: 'recovery-session',
    title: 'Recovery chat',
    model: 'fixture-model',
    source: 'test',
    messageCount: 0,
    isActive: true,
    preview: '',
    startedAt: 1,
  ),
  ApiClient? apiClient,
  TestRemotePromptSubmit? testRemotePromptSubmit,
  TestRemoteAttachmentUpload? testRemoteAttachmentUpload,
  AttachmentDraftService? attachmentDraftService,
  List<AttachmentDraft> initialDrafts = const [],
  TestDesktopConnectionHook? connectionHook,
  TestProjectOverviewLoader? projectOverviewLoader,
}) async {
  apiClient ??= ApiClient(
    baseUrl: 'http://recovery.fixture',
    apiKey: 'synthetic-key',
    httpClient: _EmptyChatHttpClient(),
  );
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChatScreen(
        connection: SavedConnection(
          id: 'recovery-fixture',
          label: 'Recovery fixture',
          host: 'recovery.fixture',
          port: 8642,
          apiKey: 'synthetic-key',
        ),
        session: chatSession,
        testApiClient: apiClient,
        testTurnApplicationSession: turnSession,
        testRemotePromptSubmit: completedStockTurn(testRemotePromptSubmit),
        testNormalResume:
            ({required localSessionId, required storedSessionId}) async =>
                const ResumedGatewaySession(
                  runtimeSessionId: 'fixture-runtime',
                  running: false,
                ),
        testRemoteAttachmentUpload: testRemoteAttachmentUpload,
        testAttachmentDraftService: attachmentDraftService,
        testInitialAttachmentDrafts: initialDrafts,
        testDesktopConnectionHook: connectionHook,
        testProjectOverviewLoader: projectOverviewLoader,
        testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

GatewayTurnRecoveryState _acceptedState() =>
    GatewayTurnRecoveryState.initial(
      clientTurnId: _clientTurnId,
    ).markSubmissionStarted().applyAck(
      const GatewayTurnAck(
        clientTurnId: _clientTurnId,
        turnId: _turnId,
        status: GatewayRecoveryTurnStatus.accepted,
        lastSeq: 0,
        created: true,
      ),
    );

GatewayTurnRecoveryState _completedState(String text) {
  final page = GatewayTurnReconcilePage.fromWire(
    {
      'automatic_resubmit': false,
      'mode': 'snapshot',
      'earliest_seq': 1,
      'last_seq': 4,
      'next_after_seq': 4,
      'has_more': false,
      'snapshot': {
        'turn_id': _turnId,
        'client_turn_id': _clientTurnId,
        'status': 'completed',
        'last_seq': 4,
        'assistant': {'message_id': _messageId, 'text': text, 'complete': true},
        'attachment_manifest_digest': _manifestDigest,
        'final_message_ref': 7,
      },
    },
    expectedAfterSeq: 0,
    expectedTurnId: _turnId,
    expectedClientTurnId: _clientTurnId,
  )!;
  return _acceptedState().applyReconcilePage(page);
}

class _FakeTurnSession implements GatewayTurnApplicationSession {
  @override
  bool get hasActiveTurn => false;

  @override
  Object addTurnActivityListener(void Function() listener) => Object();

  @override
  void removeTurnActivityListener(Object token) {}

  final List<Object> _recoverResults;
  final GatewayTurnRecoveryState? submitResult = null;
  final Object? submitError = null;
  final Object? recoverError = null;
  final Completer<void>? recoverGate = null;
  final Completer<void>? submitGate = null;
  final Completer<void>? stageGate = null;
  int recoverCount = 0;
  int submitCount = 0;
  int stageCount = 0;
  int closeCount = 0;
  final List<String> submittedTexts = [];
  GatewayTurnSessionBoundCallback? _onSessionBound;
  Object? _sessionBoundRegistration;

  void bind(String localSessionId, String storedSessionId) {
    _onSessionBound?.call(localSessionId, storedSessionId);
  }

  @override
  Object setAsyncEventListener(
    String localSessionId,
    DesktopAsyncEventCallback listener,
  ) => Object();

  @override
  void removeAsyncEventListener(String localSessionId, Object registration) {}

  @override
  Object setTurnSettledListener(
    String localSessionId,
    GatewayTurnSettledCallback listener,
  ) => Object();

  @override
  void removeTurnSettledListener(String localSessionId, Object registration) {}

  @override
  bool ownsApprovalRequest({
    required String sessionId,
    required String requestId,
  }) => false;

  @override
  Future<bool> tryRespondToApproval({
    required String sessionId,
    required String choice,
    String? requestId,
  }) async => false;

  @override
  Future<bool> tryRespondToClarify({
    required String requestId,
    required String answer,
    String? questionId,
  }) async => false;

  @override
  Future<bool> tryRespondToSudo({
    required String requestId,
    required String password,
  }) async => false;

  @override
  Future<bool> tryRespondToSecret({
    required String requestId,
    required String value,
  }) async => false;

  _FakeTurnSession(this._recoverResults);

  @override
  Future<List<GatewayTurnRecoveryState>> recoverPending(
    String localSessionId, {
    GatewayTurnStateCallback? onState,
  }) async {
    await recoverGate?.future;
    if (recoverError case final error?) throw error;
    final index = recoverCount < _recoverResults.length
        ? recoverCount
        : _recoverResults.length - 1;
    recoverCount += 1;
    final value = _recoverResults[index];
    final states = value is GatewayTurnRecoveryState
        ? <GatewayTurnRecoveryState>[value]
        : (value as List<GatewayTurnRecoveryState>);
    for (final state in states) {
      onState?.call(state);
    }
    return states;
  }

  @override
  Future<GatewayTurnRecoveryState> submit({
    required String localSessionId,
    required String text,
    List<GatewayTurnAttachmentReceipt> attachments = const [],
    GatewayTurnStateCallback? onState,
  }) async {
    submitCount += 1;
    submittedTexts.add(text);
    await submitGate?.future;
    if (submitError case final error?) throw error;
    final state = submitResult ?? _completedState('Done');
    onState?.call(state);
    return state;
  }

  @override
  Future<void> close() async => closeCount++;

  @override
  Object setSessionBoundListener(
    String localSessionId,
    GatewayTurnSessionBoundCallback listener,
  ) {
    final token = Object();
    _sessionBoundRegistration = token;
    _onSessionBound = listener;
    return token;
  }

  @override
  void removeSessionBoundListener(String localSessionId, Object registration) {
    if (!identical(_sessionBoundRegistration, registration)) return;
    _sessionBoundRegistration = null;
    _onSessionBound = null;
  }

  @override
  Future<void> detachAttachments({
    required String localSessionId,
    required Iterable<GatewayTurnAttachmentReceipt> attachments,
  }) => throw UnimplementedError();

  @override
  Future<GatewayTurnRecoveryState> interrupt({
    required String localSessionId,
    required String clientTurnId,
  }) => throw UnimplementedError();

  @override
  Future<GatewayTurnAttachmentReceipt> stageAttachment({
    required String localSessionId,
    required String clientAttachmentId,
    required String name,
    required String dataUrl,
    required int byteLength,
    required String mediaType,
    required GatewayTurnAttachmentKind kind,
  }) async {
    stageCount += 1;
    await stageGate?.future;
    throw StateError('Recovery staging must not run in legacy fallback.');
  }
}

class _EmptyChatHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET' && request.url.path.endsWith('/messages')) {
      return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode({'data': <Object>[]}))),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode({'error': 'unexpected request'}))),
      404,
      headers: {'content-type': 'application/json'},
    );
  }
}

class _QualitySequence extends _FakeTurnSession {
  _QualitySequence() : super([const <GatewayTurnRecoveryState>[]]);
  @override
  Future<GatewayTurnRecoveryState> submit({
    required String localSessionId,
    required String text,
    List<GatewayTurnAttachmentReceipt> attachments = const [],
    GatewayTurnStateCallback? onState,
  }) async {
    submitCount++;
    final second = submitCount == 2;
    final id = second ? '123e4567-e89b-42d3-a456-426614174001' : _clientTurnId;
    final turn = second ? 'second-turn' : _turnId;
    final state = GatewayTurnRecoveryState.initial(clientTurnId: id)
        .markSubmissionStarted()
        .applyAck(
          GatewayTurnAck(
            clientTurnId: id,
            turnId: turn,
            status: GatewayRecoveryTurnStatus.accepted,
            lastSeq: 0,
            created: true,
          ),
        );
    final page = GatewayTurnReconcilePage.fromWire(
      {
        'automatic_resubmit': false,
        'mode': 'snapshot',
        'earliest_seq': 1,
        'last_seq': 4,
        'next_after_seq': 4,
        'has_more': false,
        'snapshot': {
          'turn_id': turn,
          'client_turn_id': id,
          'status': second ? 'completed' : 'failed',
          'last_seq': 4,
          'assistant': {
            'message_id': second ? 'second-message' : _messageId,
            'text': second ? 'Second success' : 'First failed output',
            'complete': true,
          },
          'attachment_manifest_digest': _manifestDigest,
          'final_message_ref': second ? 17 : 7,
        },
      },
      expectedAfterSeq: 0,
      expectedTurnId: turn,
      expectedClientTurnId: id,
    )!;
    final done = state.applyReconcilePage(page);
    onState?.call(done);
    return done;
  }
}

class _QualityHistory extends http.BaseClient {
  List<Map<String, dynamic>> rows = [];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode({'data': rows}))),
        200,
        headers: {'content-type': 'application/json'},
      );
}
