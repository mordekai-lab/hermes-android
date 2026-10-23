import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/gateway_turn_application_controller.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:hermes_android/core/widgets/chat_activity_bubble.dart';
import 'package:hermes_android/core/widgets/gateway_activity_card.dart';
import 'package:hermes_android/core/widgets/gateway_insight_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_composer_adapter.dart';

void main() {
  for (final verbose in [false, true]) {
    testWidgets(
      'activity visibility and collapsed defaults: verbose=$verbose',
      (tester) async {
        SharedPreferences.setMockInitialValues({'verbose_mode': verbose});
        final fixture = _Fixture();
        addTearDown(fixture.owner.close);
        await fixture.open(tester);
        await fixture.send(tester);
        fixture.event('reasoning.delta', {
          'text': 'Reasoning details',
          'verbose': true,
        });
        await tester.pump();
        await tester.pump();
        if (verbose) {
          expect(find.byType(GatewayReasoningCard), findsOneWidget);
          expect(find.text('Reasoning details'), findsNothing);
          expect(find.byType(ChatActivityBubble), findsNothing);
        } else {
          expect(find.byType(GatewayReasoningCard), findsNothing);
          expect(find.text('Reasoning…'), findsOneWidget);
          expect(find.byType(ChatActivityBubble), findsOneWidget);
        }
        fixture.event('tool.start', {'name': 'read_file', 'tool_id': 't1'});
        await tester.pump();
        await tester.pump();
        if (verbose) {
          expect(find.byType(GatewayActivityCard), findsOneWidget);
          expect(find.text('Read file: Running'), findsOneWidget);
          expect(find.text('Running'), findsNothing);
        } else {
          expect(find.byType(GatewayActivityCard), findsNothing);
          expect(find.text('Using Read file…'), findsOneWidget);
        }
        fixture.event('tool.complete', {'name': 'read_file', 'tool_id': 't1'});
        fixture.event('subagent.start', {
          'subagent_id': 'child',
          'goal': 'Inspect child',
        });
        await tester.pump();
        await tester.pump();
        if (verbose) {
          expect(find.byType(GatewaySubagentCard), findsOneWidget);
          expect(find.text('Inspect child'), findsNothing);
          final tiles = tester.widgetList<ExpansionTile>(
            find.byType(ExpansionTile),
          );
          expect(tiles.every((tile) => !tile.initiallyExpanded), true);
          await tester.tap(find.text('1 delegated task(s) active'));
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('Inspect child'), findsOneWidget);
        } else {
          expect(find.byType(GatewaySubagentCard), findsNothing);
          expect(find.text('Delegated task: Inspect child'), findsOneWidget);
        }
        fixture.event('message.delta', {'text': 'Interim commentary'});
        fixture.event('message.interim', {
          'text': 'Interim commentary',
          'already_streamed': true,
        });
        fixture.event('message.delta', {'text': 'Final streamed draft'});
        await tester.pump();
        await tester.pump();
        if (!verbose) {
          expect(_bubbles(tester), ['Question']);
          expect(find.text('Hermes is responding…'), findsOneWidget);
        }
        fixture.event('message.complete', {'text': 'Final answer'});
        fixture.completion.complete();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(ChatActivityBubble), findsNothing);
        if (!verbose) expect(_bubbles(tester), ['Question', 'Final answer']);
        // A child observer can finish later without reviving parent activity.
        fixture.event('subagent.complete', {
          'subagent_id': 'child',
          'status': 'completed',
        });
        await tester.pump();
        expect(find.byType(ChatActivityBubble), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }

  testWidgets(
    'normal active reattachment restores activity, not detail or prose',
    (tester) async {
      SharedPreferences.setMockInitialValues({'verbose_mode': false});
      final fixture = _Fixture();
      addTearDown(fixture.owner.close);
      await fixture.open(tester);
      await fixture.send(tester);
      fixture.event('message.delta', {'text': 'Hidden partial prose'});
      fixture.event('tool.start', {'name': 'terminal', 'tool_id': 't1'});
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await fixture.open(tester, id: 'stored-chat');
      expect(_bubbles(tester), ['Question']);
      expect(find.text('Using Terminal…'), findsOneWidget);
      expect(find.byType(GatewayActivityCard), findsNothing);
      expect(fixture.submissions, 1);
      fixture.event('turn.error', {'error': 'Stopped by the gateway'});
      fixture.completion.complete();
      await tester.pump();
      await tester.pump();
      expect(find.byType(ChatActivityBubble), findsNothing);
      expect(
        find.text('Hidden partial prose', findRichText: true),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await fixture.open(tester, id: 'stored-chat');
      expect(find.byType(ChatActivityBubble), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'normal parallel activity falls back only to work still running',
    (tester) async {
      SharedPreferences.setMockInitialValues({'verbose_mode': false});
      final fixture = _Fixture();
      addTearDown(fixture.owner.close);
      await fixture.open(tester);
      await fixture.send(tester);
      fixture.event('tool.start', {'name': 'terminal', 'tool_id': 't1'});
      fixture.event('tool.start', {'name': 'read_file', 'tool_id': 't2'});
      await tester.pump();
      expect(find.text('Using Read file…'), findsOneWidget);
      fixture.event('tool.complete', {'name': 'read_file', 'tool_id': 't2'});
      await tester.pump();
      expect(find.text('Using Terminal…'), findsOneWidget);
      fixture.event('reasoning.delta', {'text': 'Reasoning after the tools'});
      fixture.event('tool.complete', {'name': 'terminal', 'tool_id': 't1'});
      await tester.pump();
      expect(find.text('Reasoning…'), findsOneWidget);
      fixture.event('message.complete', {'text': 'Done'});
      fixture.completion.complete();
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('normal recovery keeps a truthful bubble without resubmitting', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'verbose_mode': false});
    final fixture = _Fixture();
    addTearDown(fixture.owner.close);
    await fixture.open(tester);
    await fixture.send(tester);
    fixture.event('tool.start', {'name': 'terminal', 'tool_id': 't1'});
    fixture.completion.completeError(StateError('socket lost'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(ChatActivityBubble), findsOneWidget);
    expect(find.text('Recovering without resending'), findsOneWidget);
    expect(find.text('Using Terminal…'), findsNothing);
    expect(fixture.submissions, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await fixture.owner.close();
    await tester.pump();
  });

  testWidgets(
    'Stop hides only this turn activity without reopening admission',
    (tester) async {
      SharedPreferences.setMockInitialValues({'verbose_mode': false});
      final fixture = _Fixture();
      addTearDown(fixture.owner.close);
      await fixture.open(tester);
      await fixture.send(tester);
      await tester.tap(find.byTooltip('Stop response'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(ChatActivityBubble), findsNothing);
      expect(fixture.owner.hasActiveTurn, true);
      fixture.event('message.complete', {'text': 'Stopped'});
      fixture.completion.complete();
      await tester.pump();
      await tester.pump();
      fixture.completion = Completer<void>();
      await fixture.send(tester);
      expect(find.byType(ChatActivityBubble), findsOneWidget);
      fixture.event('message.complete', {'text': 'Next answer'});
      fixture.completion.complete();
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('verbose can reveal retained detail after a normal-mode visit', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'verbose_mode': false});
    final fixture = _Fixture();
    addTearDown(fixture.owner.close);
    await fixture.open(tester);
    await fixture.send(tester);
    fixture.event('reasoning.delta', {
      'text': 'Retained details',
      'verbose': true,
    });
    fixture.event('tool.start', {'name': 'terminal', 'tool_id': 't1'});
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('verbose_mode', true);
    await fixture.open(tester, id: 'stored-chat');
    expect(find.byType(GatewayReasoningCard), findsOneWidget);
    expect(find.text('Retained details'), findsNothing);
    expect(find.byType(ChatActivityBubble), findsNothing);
    await tester.tap(find.text('Reasoning'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Retained details'), findsOneWidget);
    fixture.event('message.complete', {'text': 'Final answer'});
    fixture.completion.complete();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'successful turn.end without message.complete reveals the final delta once',
    (tester) async {
      SharedPreferences.setMockInitialValues({'verbose_mode': false});
      final fixture = _Fixture();
      addTearDown(fixture.owner.close);
      await fixture.open(tester);
      await fixture.send(tester);
      fixture.event('message.delta', {'text': 'Final deltas'});
      await tester.pump();
      expect(_bubbles(tester), ['Question']);
      fixture.event('turn.end', {'status': 'completed'});
      fixture.completion.complete();
      await tester.pump();
      await tester.pump();
      expect(_bubbles(tester), ['Question', 'Final deltas']);
      expect(find.byType(ChatActivityBubble), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.open(tester, id: 'stored-chat');
      expect(_bubbles(tester), ['Question', 'Final deltas']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  for (final status in ['failed', 'interrupted']) {
    testWidgets(
      'normal $status message.complete never promotes partial prose',
      (tester) async {
        SharedPreferences.setMockInitialValues({'verbose_mode': false});
        final fixture = _Fixture();
        addTearDown(fixture.owner.close);
        await fixture.open(tester);
        await fixture.send(tester);
        fixture.event('message.complete', {
          'text': 'Incomplete answer',
          'status': status,
        });
        fixture.completion.complete();
        await tester.pump();
        await tester.pump();
        expect(_bubbles(tester), ['Question']);
        expect(find.byType(ChatActivityBubble), findsNothing);
        expect(find.byType(SnackBar), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }

  testWidgets(
    'delegation manual expansion survives new receipt items and resets on a new visit',
    (tester) async {
      SharedPreferences.setMockInitialValues({'verbose_mode': true});
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = _Fixture();
      addTearDown(fixture.owner.close);
      await fixture.open(tester);
      await fixture.send(tester);
      fixture.event('subagent.start', {
        'subagent_id': 'child',
        'goal': 'Inspect child',
      });
      await tester.pump();
      await tester.tap(find.text('1 delegated task(s) active'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Inspect child'), findsOneWidget);
      fixture.event('message.delta', {'text': 'New prose before delegation'});
      fixture.event('reasoning.delta', {'text': 'New reasoning'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Inspect child'), findsOneWidget);
      expect(
        tester
            .widget<GatewaySubagentCard>(find.byType(GatewaySubagentCard))
            .pinnedExpansion,
        true,
      );
      fixture.event('message.delta', {'text': 'More text. ' * 4000});
      for (var frame = 0; frame < 16; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.drag(find.byType(ListView).first, const Offset(0, 20000));
      for (var frame = 0; frame < 16; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.byType(GatewaySubagentCard), findsNothing);
      await tester.tap(find.bySemanticsLabel('Go to end'));
      for (var frame = 0; frame < 16; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.text('Inspect child'), findsOneWidget);
      await tester.tap(find.text('1 delegated task(s) active'));
      await tester.pump(const Duration(milliseconds: 300));
      fixture.event('tool.start', {'tool_id': 't1', 'name': 'terminal'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Inspect child'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.open(tester, id: 'stored-chat');
      for (var frame = 0; frame < 16; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.text('Inspect child'), findsNothing);
      expect(
        tester
            .widget<GatewaySubagentCard>(find.byType(GatewaySubagentCard))
            .pinnedExpansion,
        isNull,
      );
      fixture.event('message.complete', {'text': 'Done'});
      fixture.completion.complete();
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'failed initial history is not a known empty REST admission floor',
    (tester) async {
      SharedPreferences.setMockInitialValues({'verbose_mode': false});
      final client = _SseClient()..failHistory = true;
      final fixture = _Fixture();
      addTearDown(fixture.owner.close);
      await fixture.open(tester, client: client, sse: true);
      expect(find.text('Failed to load messages'), findsWidgets);
      await fixture.send(tester);
      client.frame(
        'data: {"choices":[{"delta":{"content":"New answer"}}]}\n\n',
      );
      await tester.pump();
      client.failHistory = false;
      client.rows = [
        {'id': 1, 'role': 'user', 'content': 'Old prompt'},
        {'id': 2, 'role': 'assistant', 'content': 'Old answer'},
      ];
      client.frame('data: [DONE]\n\n');
      await client.stream.close();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_bubbles(tester), ['Question', 'New answer']);
      expect(find.byType(ChatActivityBubble), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'rejected next REST send cannot revoke a retained completed reply',
    (tester) async {
      SharedPreferences.setMockInitialValues({'verbose_mode': false});
      final client = _SseClient();
      final fixture = _Fixture();
      addTearDown(fixture.owner.close);
      await fixture.open(tester, client: client, sse: true);
      await fixture.send(tester);
      client.frame(
        'data: {"choices":[{"delta":{"content":"Retained answer"}}]}\n\n',
      );
      client.frame('data: [DONE]\n\n');
      await client.stream.close();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_bubbles(tester), ['Question', 'Retained answer']);
      client.rejectSubmissions = true;
      await fixture.send(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(client.submissions, 2);
      expect(find.byType(ChatActivityBubble), findsNothing);
      expect(_bubbles(tester), ['Question', 'Retained answer']);
      final readsBeforeRefresh = client.historyReads;
      await tester.tap(find.byTooltip('Chat actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Refresh').hitTestable());
      await tester.pumpAndSettle();
      expect(client.historyReads, greaterThan(readsBeforeRefresh));
      expect(_bubbles(tester), ['Question', 'Retained answer']);
      expect(client.submissions, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'stale successful REST history preserves verbose tool receipt order',
    (tester) async {
      SharedPreferences.setMockInitialValues({'verbose_mode': true});
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final client = _SseClient();
      final fixture = _Fixture();
      addTearDown(fixture.owner.close);
      await fixture.open(tester, client: client, sse: true);
      await fixture.send(tester);
      client.frame(
        'data: {"choices":[{"delta":{"content":"Before tool"}}]}\n\n',
      );
      client.frame(
        'event: hermes.tool.progress\ndata: {"name":"terminal","tool_id":"t1","status":"running"}\n\n',
      );
      client.frame(
        'event: hermes.tool.progress\ndata: {"name":"terminal","tool_id":"t1","status":"completed"}\n\n',
      );
      client.frame(
        'data: {"choices":[{"delta":{"content":"After tool"}}]}\n\n',
      );
      client.frame('data: [DONE]\n\n');
      await client.stream.close();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(_bubbles(tester), ['Question', 'Before tool', 'After tool']);
      expect(find.byType(GatewayActivityCard), findsOneWidget);
      final tile = find.descendant(
        of: find.byType(GatewayActivityCard),
        matching: find.byType(ExpansionTile),
      );
      expect(tester.widget<ExpansionTile>(tile).initiallyExpanded, false);
      final before = tester
          .getTopLeft(find.widgetWithText(MessageBubble, 'Before tool'))
          .dy;
      final tool = tester.getTopLeft(find.byType(GatewayActivityCard)).dy;
      final after = tester
          .getTopLeft(find.widgetWithText(MessageBubble, 'After tool'))
          .dy;
      expect(before, lessThan(tool));
      expect(tool, lessThan(after));
      final readsBeforeRefresh = client.historyReads;
      await tester.tap(find.byTooltip('Chat actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Refresh').hitTestable());
      await tester.pumpAndSettle();
      expect(client.historyReads, greaterThan(readsBeforeRefresh));
      expect(_bubbles(tester), ['Question', 'Before tool', 'After tool']);
      expect(find.byType(GatewayActivityCard), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  for (final historyOutcome in [
    'failed',
    'empty',
    'old',
    'user-only',
    'fresh',
  ]) {
    testWidgets(
      'normal SSE retains its final answer with $historyOutcome history',
      (tester) async {
        SharedPreferences.setMockInitialValues({'verbose_mode': false});
        final client = _SseClient();
        final previous = <Map<String, dynamic>>[
          {'id': 1, 'role': 'user', 'content': 'Older question'},
          {'id': 2, 'role': 'assistant', 'content': 'Older answer'},
        ];
        client.rows = previous;
        final fixture = _Fixture();
        addTearDown(fixture.owner.close);
        await fixture.open(tester, client: client, sse: true);
        await fixture.send(tester);
        client.frame(
          'event: hermes.tool.progress\ndata: {"name":"terminal","tool_id":"t1","status":"running"}\n\n',
        );
        await tester.pump();
        await tester.pump();
        expect(find.text('Using Terminal…'), findsOneWidget);
        client.frame(
          'data: {"choices":[{"delta":{"content":"Hidden streamed answer"}}]}\n\n',
        );
        await tester.pump();
        await tester.pump();
        expect(_bubbles(tester), [
          'Older question',
          'Older answer',
          'Question',
        ]);
        expect(find.byType(ChatActivityBubble), findsOneWidget);
        client.failHistory = historyOutcome == 'failed';
        client.rows = switch (historyOutcome) {
          'empty' => [],
          'user-only' => [
            ...previous,
            {'id': 3, 'role': 'user', 'content': 'Question'},
          ],
          'fresh' => [
            ...previous,
            {'id': 3, 'role': 'user', 'content': 'Question'},
            {'id': 4, 'role': 'assistant', 'content': 'Hidden streamed answer'},
          ],
          _ => previous,
        };
        client.frame('data: [DONE]\n\n');
        await client.stream.close();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(ChatActivityBubble), findsNothing);
        expect(_bubbles(tester), [
          'Older question',
          'Older answer',
          'Question',
          'Hidden streamed answer',
        ]);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }
}

List<String> _bubbles(WidgetTester tester) => tester
    .widgetList<MessageBubble>(find.byType(MessageBubble))
    .map((bubble) => bubble.content)
    .toList();

class _Fixture {
  final owner = GatewayTurnApplicationController();
  var completion = Completer<void>();
  StreamCallback? onEvent;
  int submissions = 0;
  final history = <Map<String, dynamic>>[];
  final connection = SavedConnection(
    id: 'verbose-activity',
    label: 'Fixture',
    host: 'fixture.invalid',
    port: 8642,
    apiKey: 'test',
  );

  Future<void> submit({
    required String sessionId,
    required String text,
    required StreamCallback onEvent,
    required void Function() onSent,
  }) {
    submissions++;
    this.onEvent = onEvent;
    onSent();
    return completion.future;
  }

  void event(String type, Map<String, dynamic> data) =>
      onEvent!(StreamEvent(type: type, data: data));

  Future<void> send(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField), 'Question');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    await tester.pump();
  }

  Future<void> open(
    WidgetTester tester, {
    String id = 'local-chat',
    http.Client? client,
    bool sse = false,
  }) async {
    if (!sse) {
      owner.normalSessionFor(
        connection,
        submit: submit,
        history: (_) async => history,
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChatScreen(
          connection: connection,
          session: Session(
            id: id,
            title: 'Chat',
            model: 'fixture',
            source: 'test',
            messageCount: 0,
            isActive: false,
            preview: '',
            startedAt: 1,
          ),
          turnApplicationController: owner,
          testApiClient: ApiClient(
            baseUrl: connection.baseUrl,
            apiKey: 'test',
            httpClient: client ?? _HistoryClient(history),
          ),
          testRemotePromptSubmit: sse ? null : submit,
          testStoredSessionKey: (_) => 'stored-chat',
          testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }
}

class _HistoryClient extends http.BaseClient {
  final List<Map<String, dynamic>> rows;
  _HistoryClient(this.rows);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode({'data': rows}))),
        200,
        headers: {'content-type': 'application/json'},
      );
}

class _SseClient extends http.BaseClient {
  final stream = StreamController<List<int>>();
  bool failHistory = false;
  bool rejectSubmissions = false;
  int submissions = 0;
  int historyReads = 0;
  List<Map<String, dynamic>> rows = [];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/messages')) historyReads++;
    if (request.method == 'POST') {
      submissions++;
      if (rejectSubmissions) {
        return http.StreamedResponse(
          Stream.value(utf8.encode('Rejected')),
          500,
        );
      }
      return http.StreamedResponse(
        stream.stream,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode({'data': rows}))),
      failHistory ? 500 : 200,
      headers: {'content-type': 'application/json'},
    );
  }

  void frame(String frame) => stream.add(utf8.encode(frame));
}
