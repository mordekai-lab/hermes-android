import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/chat_timeline.dart';
import 'package:hermes_android/core/models/gateway_activity.dart';
import 'package:hermes_android/core/models/gateway_insight.dart';
import 'package:hermes_android/core/utils/chat_display_items.dart';

List<String> _content(List<dynamic> items) => items
    .cast<Map<String, dynamic>>()
    .map((item) => item['_display_content'] as String)
    .toList();

void main() {
  test('normal mode shows only user messages and final answers', () {
    final rows = <Map<String, dynamic>>[
      {'role': 'user', 'content': 'First question'},
      {'role': 'assistant', 'content': 'First answer'},
      {'role': 'user', 'content': 'Inspect'},
      {
        'role': 'assistant',
        'content': 'I will inspect the files',
        'tool_calls': [
          {'id': 't1'},
        ],
      },
      {'role': 'tool', 'content': 'Private tool result'},
      {
        'role': 'assistant',
        'content': 'Interim commentary',
        '_gateway_interim': true,
      },
      {
        'role': 'assistant',
        'content': 'The final answer',
        '_gateway_reasoning': 'Exposed reasoning',
        '_gateway_reasoning_verbose': true,
      },
    ];
    final original = rows.map(Map<String, dynamic>.from).toList();
    final items = buildChatDisplayItems(
      messages: rows,
      toolActivities: [
        GatewayToolActivity(
          name: 'terminal',
          phase: GatewayToolActivityPhase.running,
        ),
      ],
      subagentActivities: const [
        GatewaySubagentActivity(
          id: 'child',
          goal: 'Inspect files',
          phase: GatewaySubagentPhase.running,
        ),
      ],
      notices: const [
        GatewayNotice(kind: GatewayNoticeKind.review, text: 'Review details'),
      ],
    );
    expect(_content(items), [
      'First question',
      'First answer',
      'Inspect',
      'The final answer',
    ]);
    expect(items.last['_retry_prompt'], 'Inspect');
    expect(rows, original);
  });

  test(
    'live commentary stays hidden; final text is not split by receipt runs',
    () {
      final row = <String, dynamic>{
        'role': 'assistant',
        'content': 'Final answer',
        '_gateway_pending_response': true,
      };
      final timeline = const ChatTimeline()
          .appendText(row, 'Final ')
          .reasoning(
            row,
            const GatewayReasoningUpdate(
              text: 'Reasoning details',
              mode: GatewayReasoningEventMode.append,
              verbose: true,
            ),
          )
          .appendText(row, 'answer');
      final rows = [
        <String, dynamic>{'role': 'user', 'content': 'Question'},
        row,
      ];
      expect(
        _content(buildChatDisplayItems(messages: rows, timeline: timeline)),
        ['Question'],
      );
      row['_gateway_pending_response'] = false;
      row['_chat_response_complete'] = true;
      expect(
        _content(buildChatDisplayItems(messages: rows, timeline: timeline)),
        ['Question', 'Final answer'],
      );
    },
  );

  test(
    'canonical tool-heavy history does not turn commentary into a reply',
    () {
      expect(
        _content(
          buildChatDisplayItems(
            messages: [
              {'role': 'user', 'content': 'Question'},
              {
                'role': 'assistant',
                'content': 'Looking into it',
                'finish_reason': 'tool_calls',
              },
              {'role': 'tool', 'content': 'A result'},
            ],
          ),
        ),
        ['Question'],
      );
    },
  );

  test('active canonical tail is hidden without hiding older answers', () {
    final rows = <Map<String, dynamic>>[
      {'role': 'user', 'content': 'Earlier question'},
      {'role': 'assistant', 'content': 'Earlier answer'},
      {'role': 'user', 'content': 'Current question'},
      {'role': 'assistant', 'content': 'Working commentary'},
    ];
    expect(_content(buildChatDisplayItems(messages: rows, active: true)), [
      'Earlier question',
      'Earlier answer',
      'Current question',
    ]);
    rows.last['_chat_response_complete'] = true;
    expect(_content(buildChatDisplayItems(messages: rows, active: true)), [
      'Earlier question',
      'Earlier answer',
      'Current question',
      'Working commentary',
    ]);
  });

  test('verbose details start collapsed even with gateway verbose hints', () {
    final items = buildChatDisplayItems(
      verbose: true,
      messages: [
        {
          'role': 'assistant',
          'content': 'Reply',
          '_gateway_reasoning': 'Details',
          '_gateway_reasoning_verbose': true,
        },
      ],
    );
    expect(
      items.whereType<ChatReasoningItem>().single.initiallyExpanded,
      false,
    );
  });
}
