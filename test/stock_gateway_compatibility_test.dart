import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/gateway_turn_contract.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/gateway_turn_application_controller.dart';
import 'package:hermes_android/core/services/gateway_turn_coordinator.dart';
import 'package:hermes_android/core/services/gateway_turn_journal.dart';
import 'package:hermes_android/core/services/normal_gateway_application_session.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_composer_adapter.dart';

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

  for (final stored in [false, true]) {
    testWidgets(
      '${stored ? 'stored chat' : 'fresh draft'} uses one stock session socket without a failure banner',
      (tester) async {
        await _runWidget(tester, controller, gateway, () async {
          gateway.created = stored;
          await _mount(tester, gateway, controller, stored: stored);
          await _pumpUntil(
            tester,
            () => gateway.calls('client.capabilities').isNotEmpty,
          );
          await _pumpUntil(tester, () => _sendEnabled(tester));
          expect(gateway.sockets, hasLength(1));
          expect(gateway.tickets, 1);
          expect(
            find.byKey(const ValueKey('legacy-transport-notice')),
            findsNothing,
          );
          expect(gateway.calls('session.open'), isEmpty);
          await tester.enterText(find.byType(TextField), 'One stock prompt');
          await tester.tap(find.byTooltip('Send'));
          await _pumpUntil(
            tester,
            () => gateway.calls('prompt.submit').isNotEmpty,
          );
          final normal = controller.normalSessionFor(gateway.connection);
          final chat = normal.findChat('stored-chat')!;
          expect(chat.wireEmitted, isTrue);
          expect(gateway.calls('prompt.submit'), hasLength(1));
          expect(gateway.calls('session.create'), hasLength(stored ? 0 : 1));
          expect(gateway.sockets, hasLength(1));
          expect(
            store.value,
            isNull,
            reason: 'Stock sends do not invent v2 journal authority',
          );
          final submit = gateway.calls('prompt.submit').single;
          expect(submit['socket'], 0);
          expect(
            (submit['params'] as Map).keys,
            isNot(contains('client_turn_id')),
          );
          expect((submit['params'] as Map).keys, isNot(contains('version')));
          _expectBoundedReads(gateway);
        });
      },
    );
  }

  testWidgets(
    'first stock send negotiates without waiting for held visible history',
    (tester) async {
      await _runWidget(tester, controller, gateway, () async {
        gateway.firstHistoryGate = Completer<void>();
        await _mount(tester, gateway, controller);
        await _pumpUntil(tester, () => gateway.history.isNotEmpty);
        await tester.enterText(find.byType(TextField), 'Send before history');
        await tester.tap(find.byTooltip('Send'));
        await _pumpUntil(
          tester,
          () => gateway.calls('prompt.submit').isNotEmpty,
        );
        final normal = controller.normalSessionFor(gateway.connection);
        final chat = normal.findChat('stored-chat')!;
        expect(chat.snapshot.hasActiveTurn, isTrue);
        expect(gateway.firstHistoryGate!.isCompleted, isFalse);
        await tester.enterText(find.byType(TextField), 'Next unsent draft');
        gateway.firstHistoryGate!.complete();
        await _pumpUntil(tester, () => gateway.firstHistoryReturned);
        await tester.pump();
        expect(chat.snapshot.hasActiveTurn, isTrue);
        expect(find.text('Next unsent draft'), findsOneWidget);
        expect(gateway.calls('prompt.submit'), hasLength(1));
        expect(gateway.calls('session.create'), hasLength(1));
        expect(gateway.calls('session.open'), isEmpty);
        expect(gateway.sockets, hasLength(1));
        expect(gateway.tickets, 1);
      });
    },
  );

  for (final terminal in [false, true]) {
    testWidgets(
      'fresh stock draft reconciles socket loss with ${terminal ? 'explicit completed' : 'unknown idle'} outcome and never resends',
      (tester) async {
        await _runWidget(tester, controller, gateway, () async {
          await _mount(tester, gateway, controller);
          await _pumpUntil(tester, () => _sendEnabled(tester));
          await tester.enterText(
            find.byType(TextField),
            'Finish while detached',
          );
          await tester.tap(find.byTooltip('Send'));
          await _pumpUntil(
            tester,
            () => gateway.calls('prompt.submit').isNotEmpty,
          );
          final normal = controller.normalSessionFor(gateway.connection);
          final chat = normal.findChat('stored-chat')!;
          // Lose the socket while the submit ACK/terminal watcher is pending.
          // The server persists its result without delivering message.complete.
          normal.setLifecycle(background: true);
          gateway.running = false;
          gateway.explicitComplete = terminal;
          gateway.rows = [
            {'id': 1, 'role': 'user', 'content': 'Finish while detached'},
            {
              'id': 2,
              'role': 'assistant',
              'content': 'Saved while detached',
              'finish_reason': 'stop',
            },
          ];
          await tester.runAsync(() => gateway.sockets.single.close());
          await _pumpUntil(tester, () => chat.snapshot.reconciling);
          normal.setLifecycle(background: false);
          chat.requestRecovery();
          await _pumpUntil(tester, () => !chat.snapshot.hasActiveTurn);
          expect(
            chat.phase,
            terminal
                ? NormalGatewayTurnPhase.completed
                : NormalGatewayTurnPhase.reconciledUnknown,
          );
          expect(
            chat.snapshot.historyRows.last['content'],
            'Saved while detached',
          );
          await _pumpUntil(
            tester,
            () => find.text('Saved while detached').evaluate().isNotEmpty,
          );
          expect(gateway.calls('prompt.submit'), hasLength(1));
          expect(gateway.calls('session.create'), hasLength(1));
          expect(
            gateway.sockets,
            hasLength(2),
            reason: 'Only the lost socket is replaced',
          );
          expect(gateway.tickets, 2);
          expect(gateway.calls('session.open'), isEmpty);
          expect(gateway.calls('turn.reconcile'), isEmpty);
          expect(
            gateway.calls('session.resume').last['params'],
            containsPair('session_id', 'stored-chat'),
          );
          expect(await normal.pendingStore.load(normal.scope), isEmpty);
          _expectBoundedReads(gateway);
        });
      },
    );
  }

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
            expect(gateway.calls('prompt.submit'), hasLength(1));
            expect(gateway.calls('session.create'), isEmpty);
          }
        });
      },
    );
  }

  test(
    'stock negotiation retains same-socket approval and clarify ownership on resume',
    () async {
      final normal = controller.normalSessionFor(gateway.connection);
      await normal.ready;
      final chat = normal.chatFor(
        'local',
        storedSessionId: 'stored-chat',
        title: 'Requests',
      );
      gateway.created = true;
      gateway.openRequests = [
        {
          'id': 'approval-1',
          'method': 'approval',
          'params': {
            'session_id': 'runtime-0',
            'command': 'fixture',
            'description': 'Allow fixture',
          },
        },
        {
          'id': 'clarify-1',
          'method': 'clarify',
          'params': {
            'session_id': 'runtime-0',
            'questions': [
              {
                'qid': 'q1',
                'question': 'Which fixture?',
                'choices': ['A', 'B'],
              },
            ],
          },
        },
      ];
      await expectLater(
        controller.sessionFor(gateway.connection).recoverPending('fresh-draft'),
        throwsA(_stockAbsence),
      );
      await normal.client!.ensureSession('local');
      await _until(() => chat.snapshot.pendingInput.length == 2);
      final approval = chat.snapshot.pendingInput.singleWhere(
        (event) => event.type == 'approval.request',
      );
      final clarify = chat.snapshot.pendingInput.singleWhere(
        (event) => event.type == 'clarify.request',
      );
      final approvalId = approval.data['server_request_id'] as String;
      final clarifyId = clarify.data['server_request_id'] as String;
      expect(
        await normal.tryRespondToApproval(
          sessionId: 'local',
          requestId: approvalId,
          choice: 'once',
        ),
        isTrue,
      );
      await normal.client!.respondToClarify(
        requestId: clarifyId,
        answer: 'A',
        questionId: 'q1',
      );
      await _until(() => gateway.responses.isNotEmpty);
      expect(gateway.responses.map((response) => response['id']), [
        'approval-1',
      ]);
      expect(gateway.calls('clarify.lock').single['socket'], 0);
      expect(gateway.calls('clarify.lock').single['params'], {
        'request_id': 'clarify-1',
        'question_id': 'q1',
        'answer': 'A',
      });
      expect(chat.snapshot.pendingInput, isEmpty);
      expect(gateway.responses.map((response) => response['socket']).toSet(), {
        0,
      });
      expect(gateway.sockets, hasLength(1));
      expect(gateway.calls('session.open'), isEmpty);
    },
  );

  test(
    'a capable greeting activates experimental v2 only after both socket gates',
    () async {
      gateway.recovery = true;
      final recovery = controller.sessionFor(gateway.connection);
      expect(await recovery.recoverPending('fresh-draft'), isEmpty);
      expect(gateway.calls('session.open'), hasLength(1));
      expect(gateway.calls('session.resume'), isEmpty);
      expect(gateway.calls('session.create'), isEmpty);
      final state = await recovery.submit(
        localSessionId: 'fresh-draft',
        text: 'Experimental once',
      );
      expect(state.status, GatewayRecoveryTurnStatus.accepted);
      expect(gateway.calls('prompt.submit'), hasLength(1));
      final submit = gateway.calls('prompt.submit').single;
      expect(submit['socket'], gateway.calls('session.open').single['socket']);
      expect(submit['params'], containsPair('version', 2));
      expect(
        submit['params'],
        containsPair('client_turn_id', state.clientTurnId),
      );
      // Recovery deliberately keeps its own per-draft transport; it cannot steal
      // a normal socket serving another chat or any pending server requests.
      expect(gateway.sockets, hasLength(2));
      expect(gateway.tickets, 2);
    },
  );

  test(
    'fresh greeting after server upgrade is not masked by a negative cache',
    () async {
      final recovery = controller.sessionFor(gateway.connection);
      await expectLater(
        recovery.recoverPending('draft-before'),
        throwsA(_stockAbsence),
      );
      expect(gateway.sockets, hasLength(1));
      gateway.recovery = true;
      final normal = controller.normalSessionFor(gateway.connection);
      normal.client!.setReconnectAllowed(false);
      await gateway.sockets.single.close();
      await _until(() => gateway.closedSockets.contains(0));
      // A new draft can negotiate again after a server replacement. A draft
      // already using normal transport is never migrated mid-turn.
      expect(await recovery.recoverPending('draft-after'), isEmpty);
      expect(gateway.calls('session.open'), hasLength(1));
      expect(gateway.calls('prompt.submit'), isEmpty);
      expect(gateway.sockets, hasLength(3));
    },
  );

  test(
    'canonical authority cannot become clean stock or ordinary fallback',
    () async {
      gateway.sessionAuthority = true;
      await expectLater(
        controller.sessionFor(gateway.connection).recoverPending('fresh-draft'),
        throwsA(
          isA<GatewayTurnCoordinatorException>()
              .having(
                (error) => error.failure,
                'failure',
                GatewayTurnCoordinatorFailure.invalidResponse,
              )
              .having((error) => error.stockGateway, 'stockGateway', isFalse),
        ),
      );
      expect(gateway.sockets, hasLength(1));
      expect(gateway.tickets, 1);
      expect(gateway.calls('session.open'), isEmpty);
      expect(gateway.calls('session.create'), isEmpty);
      expect(gateway.calls('prompt.submit'), isEmpty);
      expect(store.value, isNull);
    },
  );

  test(
    'malformed recovery advertisement does not become stock fallback',
    () async {
      gateway.recovery = true;
      gateway.unsafeRecovery = true;
      await expectLater(
        controller.sessionFor(gateway.connection).recoverPending('fresh-draft'),
        throwsA(
          isA<GatewayTurnCoordinatorException>().having(
            (error) => error.failure,
            'failure',
            GatewayTurnCoordinatorFailure.invalidResponse,
          ),
        ),
      );
      expect(gateway.sockets, hasLength(1));
      expect(gateway.calls('session.open'), isEmpty);
      expect(gateway.calls('prompt.submit'), isEmpty);
      expect(store.value, isNull);
    },
  );

  test(
    'capable control greeting cannot authorize a downgraded recovery socket',
    () async {
      gateway.recovery = true;
      gateway.downgradeRecoverySocket = true;
      await expectLater(
        controller.sessionFor(gateway.connection).recoverPending('fresh-draft'),
        throwsA(_stockAbsence),
      );
      expect(gateway.sockets, hasLength(2));
      expect(gateway.calls('session.open'), isEmpty);
      expect(gateway.calls('prompt.submit'), isEmpty);
    },
  );

  test(
    'stock downgrade preserves unresolved durable journal and forbids normal fallback',
    () async {
      gateway.recovery = true;
      final recovery = controller.sessionFor(gateway.connection);
      await recovery.recoverPending('fresh-draft');
      await recovery.submit(
        localSessionId: 'fresh-draft',
        text: 'Uncertain experimental once',
      );
      await controller.close();
      gateway.recovery = false;
      controller = GatewayTurnApplicationController(
        journalFactory: () => GatewayTurnJournal(store: store),
      );
      final before = store.value;
      await expectLater(
        controller.sessionFor(gateway.connection).recoverPending('fresh-draft'),
        throwsA(
          isA<GatewayTurnCoordinatorException>()
              .having(
                (error) => error.failure,
                'failure',
                GatewayTurnCoordinatorFailure
                    .unsupportedCapabilityWithPendingTurns,
              )
              .having((error) => error.stockGateway, 'stockGateway', isFalse),
        ),
      );
      expect(store.value, before);
      expect(gateway.calls('prompt.submit'), hasLength(1));
      expect(gateway.calls('session.create'), isEmpty);
      expect(gateway.calls('session.resume'), isEmpty);
      expect(gateway.calls('turn.reconcile'), isEmpty);
      expect(
        gateway.sockets,
        hasLength(3),
        reason:
            'Restart uses one normal greeting, not another disposable probe',
      );
    },
  );
}

final _stockAbsence = isA<GatewayTurnCoordinatorException>()
    .having(
      (error) => error.failure,
      'failure',
      GatewayTurnCoordinatorFailure.unsupportedCapability,
    )
    .having((error) => error.stockGateway, 'stockGateway', isTrue);

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
          id: stored ? 'stored-chat' : 'fresh-draft',
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

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Stock wire condition not reached');
    }
    await Future<void>.delayed(Duration.zero);
  }
}

void _expectBoundedReads(_Gateway gateway) {
  for (final call in gateway.calls('session.resume')) {
    expect(call['params'], containsPair('omit_messages', true));
  }
  for (final uri in gateway.history) {
    expect(uri.queryParameters['limit'], '50');
    expect(uri.queryParameters['order'], 'latest');
  }
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
  bool created = false;
  bool running = true;
  bool explicitComplete = false;
  bool recovery = false;
  bool unsafeRecovery = false;
  bool sessionAuthority = false;
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
                if (sessionAuthority) 'session_authority': true,
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
              'turn_id': 'recovery-turn',
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
