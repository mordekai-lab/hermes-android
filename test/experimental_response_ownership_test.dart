import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/gateway_turn_application_controller.dart';
import 'package:hermes_android/core/services/gateway_turn_coordinator.dart';
import 'package:hermes_android/core/services/gateway_turn_journal.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_composer_adapter.dart';
import 'package:hermes_android/core/widgets/gateway_insight_card.dart';
import 'package:hermes_android/core/widgets/gateway_activity_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Gateway gateway;
  late GatewayTurnApplicationController controller;
  late _JournalStore store;
  HttpOverrides? overrides;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'verbose_mode': true});
    overrides = HttpOverrides.current;
    HttpOverrides.global = null;
    gateway = _Gateway();
    await gateway.start();
    store = _JournalStore();
    controller = GatewayTurnApplicationController(
      journalFactory: () => GatewayTurnJournal(store: store),
    );
  });
  tearDown(() async {
    await controller.close();
    await gateway.close();
    HttpOverrides.global = overrides;
  });

  test(
    'closed control preflight remains a typed fail-closed transport failure',
    () async {
      final normal = controller.normalSessionFor(gateway.connection);
      normal.client!.close();
      await expectLater(
        controller.sessionFor(gateway.connection).recoverPending('fresh-draft'),
        throwsA(
          isA<GatewayTurnCoordinatorException>()
              .having(
                (error) => error.failure,
                'failure',
                GatewayTurnCoordinatorFailure.transportUnavailable,
              )
              .having((error) => error.stockGateway, 'stockGateway', isFalse),
        ),
      );
      expect(gateway.calls('session.open'), isEmpty);
      expect(gateway.calls('prompt.submit'), isEmpty);
      expect(store.value, isNull);
    },
  );

  for (final unsafe in [false, true]) {
    testWidgets(
      'normal control disconnect cannot overwrite ${unsafe ? 'fail-closed' : 'active experimental'} draft admission',
      (tester) async {
        await _runWidget(tester, controller, gateway, () async {
          gateway.recovery = true;
          gateway.unsafeRecovery = unsafe;
          await _mount(tester, gateway, controller);
          await _pumpUntil(
            tester,
            () => gateway.calls('client.capabilities').isNotEmpty,
          );
          if (!unsafe) {
            await _pumpUntil(tester, () => _sendEnabled(tester));
            await tester.enterText(find.byType(TextField), 'Experimental once');
            await tester.tap(find.byTooltip('Send'));
            await _pumpUntil(
              tester,
              () => gateway.calls('prompt.submit').isNotEmpty,
            );
            await _pumpUntil(
              tester,
              () => find
                  .byKey(const Key('chat-stop-response'))
                  .evaluate()
                  .isNotEmpty,
            );
            expect(
              gateway.calls('prompt.submit').single['params'],
              containsPair('version', 2),
            );
          }
          if (!unsafe) {
            void event(int seq, String type, Map<String, dynamic> payload) {
              gateway.sockets.last.add(
                jsonEncode({
                  'jsonrpc': '2.0',
                  'method': 'event',
                  'params': {
                    'type': type,
                    'session_id': 'runtime-1',
                    'turn_id': 'recovery-turn',
                    'seq': seq,
                    'message_id': 'owned-message',
                    'payload': payload,
                  },
                }),
              );
            }

            event(1, 'message.start', {});
            event(2, 'message.delta', {'text': 'Owned experimental text'});
            await _pumpUntil(
              tester,
              () => find.text('Owned experimental text').evaluate().isNotEmpty,
            );
            expect(find.text('Owned experimental text'), findsOneWidget);
          }
          final normal = controller.normalSessionFor(gateway.connection);
          normal.client!.setReconnectAllowed(false);
          await tester.runAsync(() => gateway.sockets.first.close());
          await _pumpUntil(
            tester,
            () =>
                normal.findChat('fresh-draft')!.snapshot.connectionState.name ==
                'disconnected',
          );
          if (unsafe) {
            expect(_sendEnabled(tester), isFalse);
            expect(gateway.calls('prompt.submit'), isEmpty);
            expect(gateway.calls('session.open'), isEmpty);
          } else {
            expect(find.byKey(const Key('chat-stop-response')), findsOneWidget);
            expect(
              find.text('Owned experimental text'),
              findsOneWidget,
              reason:
                  'An unrelated normal/control disconnect must retain selected experimental output',
            );
            expect(gateway.calls('prompt.submit'), hasLength(1));
            expect(gateway.calls('session.create'), isEmpty);
          }
        });
      },
    );
  }

  for (final outcome in [
    'active',
    'completed',
    'failed',
    'fail-closed',
    'uncertain',
  ]) {
    testWidgets(
      'selected experimental $outcome output and history details survive idle control history and reconnect',
      (tester) async {
        await _runWidget(tester, controller, gateway, () async {
          gateway.recovery = true;
          gateway.rows = [
            {
              'id': 1,
              'role': 'assistant',
              'content': 'Owned earlier prose',
              '_gateway_reasoning': 'Owned earlier reasoning',
            },
            {
              'id': 2,
              'role': 'tool',
              'name': 'terminal',
              'tool_call_id': 'owned-tool',
              'content': 'Owned tool result',
            },
          ];
          await _mount(tester, gateway, controller);
          await _pumpUntil(
            tester,
            () =>
                gateway.calls('session.open').isNotEmpty &&
                _sendEnabled(tester) &&
                find.byType(GatewayReasoningCard).evaluate().isNotEmpty,
          );
          expect(find.byType(GatewayReasoningCard), findsOneWidget);
          expect(find.byType(GatewayActivityCard), findsOneWidget);
          expect(
            tester
                .widget<GatewayReasoningCard>(find.byType(GatewayReasoningCard))
                .text,
            'Owned earlier reasoning',
          );
          await tester.enterText(
            find.byType(TextField),
            'Experimental presentation',
          );
          await tester.tap(find.byTooltip('Send'));
          await _pumpUntil(
            tester,
            () => gateway.calls('prompt.submit').isNotEmpty,
          );
          _event(gateway, 1, 'message.start', {});
          _event(gateway, 2, 'message.delta', {
            'text': 'Owned experimental text',
          });
          await _pumpUntil(
            tester,
            () => find.text('Owned experimental text').evaluate().isNotEmpty,
          );
          if (outcome == 'completed') {
            _event(gateway, 3, 'message.complete', {
              'text': 'Owned experimental text',
              'status': 'completed',
            });
          } else if (outcome == 'failed') {
            _event(gateway, 3, 'turn.status', {'status': 'failed'});
          } else if (outcome == 'fail-closed') {
            _event(gateway, 3, 'message.delta', {'text': 17});
          } else if (outcome == 'uncertain') {
            await tester.runAsync(() => gateway.sockets[1].close());
          }
          if (['completed', 'failed', 'fail-closed'].contains(outcome)) {
            await _pumpUntil(
              tester,
              () => find
                  .byKey(const Key('chat-stop-response'))
                  .evaluate()
                  .isEmpty,
            );
          }
          final normal = controller.normalSessionFor(gateway.connection);
          final chat = normal.findChat('fresh-draft')!;
          // The real normal owner accepts an independent observation, including
          // deferred history fan-out. It is not the selected response owner.
          chat.observeHistory([
            {
              'id': 99,
              'role': 'assistant',
              'content': 'Unrelated control history',
            },
          ]);
          await tester.pump();
          _expectOwnedDetails(tester);
          normal.client!.setReconnectAllowed(false);
          await tester.runAsync(() => gateway.sockets.first.close());
          await _pumpUntil(
            tester,
            () => chat.snapshot.connectionState.name == 'disconnected',
          );
          _expectOwnedDetails(tester);
          var ready = false;
          normal.client!.readGatewayReadyFrame().then((_) => ready = true);
          await _pumpUntil(tester, () => ready);
          expect(chat.snapshot.connectionState.name, 'connected');
          _expectOwnedDetails(tester);
          expect(find.text('Unrelated control history'), findsNothing);
          if (['completed', 'failed', 'fail-closed'].contains(outcome)) {
            final reads = gateway.history.length;
            gateway.rows = [];
            await tester.tap(find.byTooltip('Chat actions'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('Refresh'));
            await _pumpUntil(tester, () => gateway.history.length > reads);
            await tester.pumpAndSettle();
            _expectOwnedDetails(tester);
          }
          expect(gateway.calls('prompt.submit'), hasLength(1));
          expect(gateway.calls('session.create'), isEmpty);
        });
      },
    );
  }

  testWidgets(
    'later stored normal selection displays normal history and accepts fresh normal notifications',
    (tester) async {
      await _runWidget(tester, controller, gateway, () async {
        gateway.recovery = true;
        await _mount(tester, gateway, controller);
        await _pumpUntil(tester, () => _sendEnabled(tester));
        await tester.enterText(find.byType(TextField), 'Experimental first');
        await tester.tap(find.byTooltip('Send'));
        await _pumpUntil(
          tester,
          () => gateway.calls('prompt.submit').isNotEmpty,
        );
        _event(gateway, 1, 'message.start', {});
        _event(gateway, 2, 'message.complete', {
          'text': 'Settled experimental',
          'status': 'completed',
        });
        await _pumpUntil(
          tester,
          () => find.text('Settled experimental').evaluate().isNotEmpty,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        gateway.created = true;
        gateway.rows = [
          {
            'id': 40,
            'role': 'assistant',
            'content': 'Selected stored normal history',
          },
        ];
        await _mount(
          tester,
          gateway,
          controller,
          stored: true,
          sessionId: 'stored-recovery',
        );
        await _pumpUntil(
          tester,
          () =>
              find.text('Selected stored normal history').evaluate().isNotEmpty,
        );
        final normal = controller.normalSessionFor(gateway.connection);
        final chat = normal.findChat('stored-recovery')!;
        expect(chat, same(normal.findChat('fresh-draft')));
        chat.observeHistory([
          {
            'id': 41,
            'role': 'assistant',
            'content': 'Fresh normal observation',
          },
        ]);
        await _pumpUntil(
          tester,
          () => find.text('Fresh normal observation').evaluate().isNotEmpty,
        );
        expect(find.text('Settled experimental'), findsNothing);
        expect(gateway.calls('prompt.submit'), hasLength(1));
      });
    },
  );

  testWidgets(
    'late first experimental turn frames and normal history cannot overwrite a newer experimental turn',
    (tester) async {
      await _runWidget(tester, controller, gateway, () async {
        gateway.recovery = true;
        await _mount(tester, gateway, controller);
        await _pumpUntil(tester, () => _sendEnabled(tester));
        await tester.enterText(find.byType(TextField), 'First turn');
        await tester.tap(find.byTooltip('Send'));
        await _pumpUntil(
          tester,
          () => gateway.calls('prompt.submit').length == 1,
        );
        _event(gateway, 1, 'message.start', {});
        _event(gateway, 2, 'message.complete', {
          'text': 'First retained reply',
          'status': 'completed',
        });
        await _pumpUntil(
          tester,
          () =>
              _sendEnabled(tester) &&
              find.byKey(const Key('chat-stop-response')).evaluate().isEmpty,
        );
        await tester.enterText(find.byType(TextField), 'Second turn');
        await tester.tap(find.byTooltip('Send'));
        await _pumpUntil(
          tester,
          () => gateway.calls('prompt.submit').length == 2,
        );
        _event(
          gateway,
          1,
          'message.start',
          {},
          turn: 'recovery-turn-2',
          message: 'second-message',
        );
        _event(
          gateway,
          2,
          'message.delta',
          {'text': 'Newer selected reply'},
          turn: 'recovery-turn-2',
          message: 'second-message',
        );
        await _pumpUntil(
          tester,
          () => find.text('Newer selected reply').evaluate().isNotEmpty,
        );
        controller
            .normalSessionFor(gateway.connection)
            .findChat('fresh-draft')!
            .observeHistory([
              {'id': 100, 'role': 'assistant', 'content': 'Late normal page'},
            ]);
        _event(gateway, 2, 'message.complete', {
          'text': 'First retained reply',
          'status': 'completed',
        });
        await tester.pump();
        expect(find.text('Newer selected reply'), findsOneWidget);
        expect(find.text('First retained reply'), findsOneWidget);
        expect(find.text('Late normal page'), findsNothing);
        expect(find.byKey(const Key('chat-stop-response')), findsOneWidget);
        expect(gateway.calls('prompt.submit'), hasLength(2));
      });
    },
  );
}

void _event(
  _Gateway gateway,
  int seq,
  String type,
  Map<String, dynamic> payload, {
  String turn = 'recovery-turn',
  String message = 'owned-message',
}) {
  gateway.sockets[1].add(
    jsonEncode({
      'jsonrpc': '2.0',
      'method': 'event',
      'params': {
        'type': type,
        'session_id': 'runtime-1',
        'turn_id': turn,
        'seq': seq,
        'message_id': message,
        'payload': payload,
      },
    }),
  );
}

void _expectOwnedDetails(WidgetTester tester) {
  expect(find.text('Owned experimental text'), findsOneWidget);
  expect(find.text('Owned earlier prose'), findsOneWidget);
  expect(find.byType(GatewayReasoningCard), findsOneWidget);
  expect(
    tester.widget<GatewayReasoningCard>(find.byType(GatewayReasoningCard)).text,
    'Owned earlier reasoning',
  );
  expect(find.byType(GatewayActivityCard), findsOneWidget);
}

bool _sendEnabled(WidgetTester tester) {
  final buttons = find.widgetWithIcon(IconButton, Icons.send);
  return buttons.evaluate().isNotEmpty &&
      tester.widget<IconButton>(buttons).onPressed != null;
}

Future<void> _mount(
  WidgetTester tester,
  _Gateway gateway,
  GatewayTurnApplicationController controller, {
  bool stored = false,
  String? sessionId,
}) async {
  const picker = MethodChannel('plugins.flutter.io/image_picker');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    picker,
    (_) async => null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      picker,
      null,
    ),
  );
  await tester.binding.setSurfaceSize(const Size(1000, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChatScreen(
        connection: gateway.connection,
        session: Session(
          id: sessionId ?? (stored ? 'stored-chat' : 'fresh-draft'),
          title: 'Stock chat',
          model: 'fixture',
          source: 'mobile',
          messageCount: 0,
          isActive: false,
          preview: '',
          startedAt: 1,
          isLocalDraft: !stored,
        ),
        turnApplicationController: controller,
        testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
      ),
    ),
  );
}

Future<void> _dispose(
  WidgetTester tester,
  GatewayTurnApplicationController controller,
  _Gateway gateway,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  var closed = false;
  final closing = controller.close().whenComplete(() => closed = true);
  closing.ignore();
  await _pumpUntil(tester, () => closed);
  await closing;
  await tester.runAsync(gateway.close);
  await tester.pump(const Duration(seconds: 16));
}

Future<void> _runWidget(
  WidgetTester tester,
  GatewayTurnApplicationController controller,
  _Gateway gateway,
  Future<void> Function() body,
) async {
  try {
    await body();
  } finally {
    await _dispose(tester, controller, gateway);
  }
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 300; i++) {
    await tester.pump();
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  fail('Stock fixture condition not reached');
}

// Stock shapes are derived from NousResearch/hermes-agent at
// 69f73ec5f11f5a945cc864f29c4e2ad2307eaec3: tui_gateway/ws.py,
// contracts/{liveness,sessions,prompt_voice}.py. This is a loopback contract
// fixture, NOT a real gateway, inference run or an upstream v2 implementation.
class _Gateway {
  late HttpServer server;
  final sockets = <WebSocket>[];
  final closedSockets = <int>{};
  final requests = <Map<String, dynamic>>[];
  final responses = <Map<String, dynamic>>[];
  final history = <Uri>[];
  int tickets = 0;
  int recoverySubmits = 0;
  bool created = false;
  bool running = true;
  bool explicitComplete = false;
  bool recovery = false;
  bool unsafeRecovery = false;
  bool downgradeRecoverySocket = false;
  bool _closed = false;
  int _bindingVersion = 0;
  List<Map<String, dynamic>> rows = [];
  List<Map<String, dynamic>> openRequests = [];
  Completer<void>? firstHistoryGate;
  bool firstHistoryReturned = false;
  SavedConnection get connection => SavedConnection(
    id: 'stock-contract',
    label: 'Stock fixture',
    host: '127.0.0.1',
    port: server.port,
    apiKey: 'fixture',
    dashboardPortOverride: server.port,
    dashboardProxied: true,
  );
  List<Map<String, dynamic>> calls(String method) =>
      requests.where((request) => request['method'] == method).toList();
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/api/auth/ws-ticket') {
        tickets++;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"ticket":"fixture-ticket"}');
        await request.response.close();
      } else if (request.uri.path.endsWith('/messages')) {
        final snapshot = [
          for (final row in rows) Map<String, dynamic>.from(row),
        ];
        history.add(request.uri);
        final first = history.length == 1;
        if (first) await firstHistoryGate?.future;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'data': snapshot}));
        await request.response.close();
        if (first) firstHistoryReturned = true;
      } else if (request.uri.path == '/api/ws') {
        final ws = await WebSocketTransformer.upgrade(request);
        final index = sockets.length;
        sockets.add(ws);
        final capable = recovery && !(downgradeRecoverySocket && index > 0);
        ws.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {
                'skin': {'name': 'default'},
                'change_events': true,
                'heartbeat': true,
                'replay_epoch': 'epoch-$index',
                if (capable) 'protocol': {'name': 'hermes-jsonrpc', 'major': 2},
                if (capable)
                  'capabilities': {
                    'turn_recovery': {
                      ..._recoveryCapability,
                      if (unsafeRecovery) 'automatic_resubmit': true,
                    },
                  },
              },
            },
          }),
        );
        ws.listen((raw) {
          final frame = Map<String, dynamic>.from(
            jsonDecode(raw as String) as Map,
          );
          if (frame['method'] == null) {
            responses.add({...frame, 'socket': index});
            return;
          }
          requests.add({...frame, 'socket': index});
          final params = frame['params'] as Map;
          final method = frame['method'];
          if (method == 'prompt.submit' && params['version'] == 2) {
            recoverySubmits++;
          }
          Map<String, dynamic>? error;
          final result = switch (method) {
            'client.capabilities' => {
              'server_requests': ['approval', 'clarify', 'sudo', 'secret'],
              'declines_not_shown': true,
            },
            'session.resume' => {
              'session_id': 'runtime-$index',
              'stored_session_id': 'stored-chat',
              'message_count': rows.length,
              'messages': [],
              'messages_omitted': true,
              'info': {},
              'running': running,
              'status': running ? 'working' : 'idle',
              if (explicitComplete) 'inflight': {'status': 'complete'},
              'open_requests': openRequests,
            },
            'session.create' => {
              'session_id': 'runtime-$index',
              'stored_session_id': 'stored-chat',
              'message_count': 0,
              'messages': [],
              'info': {},
            },
            'session.open' => {
              'runtime_session_id': 'runtime-$index',
              'stored_session_id': 'stored-recovery',
              'mobile_session_id': params['mobile_session_id'],
              'binding_version': ++_bindingVersion,
              'turn_recovery': true,
              'automatic_resubmit': false,
              'capabilities': {'turn_recovery': _recoveryCapability},
            },
            'prompt.submit' when params['version'] == 2 => {
              'accepted': true,
              'automatic_resubmit': false,
              'client_turn_id': params['client_turn_id'],
              'turn_id': recoverySubmits == 1
                  ? 'recovery-turn'
                  : 'recovery-turn-$recoverySubmits',
              'status': 'accepted',
              'last_seq': 0,
              'created': true,
            },
            'prompt.submit' => {'status': 'streaming'},
            'projects.tree' => {'projects': []},
            'clarify.lock' => {'status': 'ok', 'remaining': []},
            'config.get' => {
              'config': {
                'voice': {'stop_phrases': []},
              },
            },
            'gateway.ping' => {'ok': true},
            _ => <String, dynamic>{},
          };
          if (method == 'session.resume' && !created) {
            error = {'code': 4007, 'message': 'session not found'};
          }
          if (method == 'session.create') created = true;
          try {
            ws.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                if (error != null) 'error': error else 'result': result,
              }),
            );
          } on StateError {
            // The fixture may receive buffered requests after explicit close.
          }
        }, onDone: () => closedSockets.add(index));
      } else {
        request.response.statusCode = 404;
        await request.response.close();
      }
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final held = firstHistoryGate;
    if (held != null && !held.isCompleted) held.complete();
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }
}

// Experimental Android fixture contract only; never inferred from stock
// client.capabilities, persisted_turn, a replay epoch or session running state.
const _recoveryCapability = <String, dynamic>{
  'version': 2,
  'shadow_only': false,
  'methods': ['session.open', 'turn.reconcile', 'turn.interrupt'],
  'prompt_submit_version': 2,
  'applies_to': [
    'session.open',
    'prompt.submit@2',
    'turn.reconcile',
    'turn.interrupt',
  ],
  'automatic_resubmit': false,
  'execution_route': 'single_process_in_process',
  'event_retention_seconds': 86400,
  'turn_retention_seconds': 604800,
  'max_event_bytes': 65536,
  'max_turn_bytes': 4194304,
  'terminal_event_reserve_bytes': 1024,
  'max_prompt_bytes': 65536,
  'mobile_session_id_format': 'canonical_lowercase_uuid',
  'client_turn_id_format': 'canonical_lowercase_uuid',
  'reconcile_max_events': 256,
  'reconcile_max_page_bytes': 524288,
};

class _JournalStore implements GatewayTurnJournalStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String next) async => value = next;
  @override
  Future<void> delete() async => value = null;
  @override
  Future<String?> readLegacy() async => null;
  @override
  Future<void> deleteLegacy() async {}
}
