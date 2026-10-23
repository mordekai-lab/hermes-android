import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/rest_chat_reply_retention.dart';

Map<String, dynamic> row(int id, String role, String text) => {
  'id': id,
  'role': role,
  'content': text,
};

void main() {
  final previous = [
    row(10, 'user', 'Same question'),
    row(11, 'assistant', 'Same answer'),
  ];
  final localUser = <String, dynamic>{
    'role': 'user',
    'content': 'Same question',
  };
  final localAnswer = <String, dynamic>{
    'role': 'assistant',
    'content': 'Same answer',
    '_chat_response_complete': true,
    '_gateway_pending_response': false,
  };
  final local = [...previous, localUser, localAnswer];

  test(
    'empty, old and user-only history cannot discard the received answer',
    () {
      final retention = RestChatReplyRetention.admit(
        previous,
        historyKnown: true,
      )..complete(local);
      for (final history in [
        <Map<String, dynamic>>[],
        previous,
        [...previous, row(12, 'user', 'Same question')],
      ]) {
        expect(retention.reconcile(history), local);
        expect(retention.hasRetainedReply, true);
      }
      expect(identical(retention.reconcile(previous).last, localAnswer), true);
    },
  );

  test(
    'durable new response replaces the live answer exactly once, not by text',
    () {
      final retention = RestChatReplyRetention.admit(
        previous,
        historyKnown: true,
      )..complete(local);
      final canonical = [
        ...previous,
        row(12, 'user', 'Same question'),
        row(13, 'assistant', 'Same answer'),
      ];
      expect(retention.reconcile(canonical), canonical);
      expect(retention.hasRetainedReply, false);
    },
  );

  test('known empty floor zero can reconcile a first response', () {
    final retention = RestChatReplyRetention.admit([], historyKnown: true)
      ..complete([localUser, localAnswer]);
    final canonical = [
      row(1, 'user', 'Same question'),
      row(2, 'assistant', 'Same answer'),
    ];
    expect(retention.admissionFloor, 0);
    expect(retention.reconcile(canonical), canonical);
  });

  test(
    'unknown admission floor never guesses identity from repeated answer text',
    () {
      for (final history in [
        <Map<String, dynamic>>[],
        [localUser, localAnswer],
      ]) {
        final retention = RestChatReplyRetention.admit(
          history,
          historyKnown: false,
        )..complete(local);
        expect(retention.admissionFloor, isNull);
        expect(retention.reconcile(previous), local);
      }
      final retention = RestChatReplyRetention.admit(local, historyKnown: true)
        ..complete(local);
      expect(retention.admissionFloor, isNull);
      expect(retention.reconcile(previous), local);
    },
  );

  test('tool calls and interim rows are not a canonical final answer', () {
    final retention = RestChatReplyRetention.admit(previous, historyKnown: true)
      ..complete(local);
    final canonical = [
      ...previous,
      {
        ...row(12, 'assistant', 'Commentary'),
        'tool_calls': [
          {'id': 'tool'},
        ],
      },
      {...row(13, 'assistant', 'Preview'), 'interim': true},
      row(14, 'tool', 'Result'),
    ];
    expect(retention.reconcile(canonical), local);
  });

  test('loading older rows preserves local identity and receipt scopes', () {
    final retention = RestChatReplyRetention.admit(previous, historyKnown: true)
      ..complete(local);
    final older = row(9, 'user', 'Earlier');
    expect(retention.reconcile([older, ...previous]), [older, ...local]);
    expect(
      identical(retention.reconcile([older, ...previous]).last, localAnswer),
      true,
    );
  });
}
