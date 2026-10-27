import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/experimental_history_handoff.dart';

void main() {
  for (final outcome in ['failed', 'unknown', 'completed']) {
    test(
      '$outcome A keeps its own prompt, detail and identity when B hands off',
      () {
        final promptA = <String, dynamic>{'role': 'user', 'content': 'A'};
        final a = <String, dynamic>{
          'role': 'assistant',
          'content': 'same prose',
          '_gateway_client_turn_id': 'A',
          '_gateway_final_message_ref': 7,
          '_gateway_response_outcome': outcome,
          '_gateway_reasoning': 'A reasoning',
          '_chat_response_complete': outcome == 'completed',
        };
        final promptB = <String, dynamic>{'role': 'user', 'content': 'B'};
        final b = <String, dynamic>{
          'role': 'assistant',
          'content': 'same prose',
          '_gateway_client_turn_id': 'B',
          '_gateway_final_message_ref': 17,
          '_chat_response_complete': true,
        };
        final savedB = <String, dynamic>{
          'id': 17,
          'role': 'assistant',
          'content': 'same prose',
        };
        final savedUserB = <String, dynamic>{
          'id': 16,
          'role': 'user',
          'content': 'B',
        };
        final prompts =
            Map<Map<String, dynamic>, Map<String, dynamic>>.identity()
              ..[a] = promptA
              ..[b] = promptB;
        final handoffs = <Map<String, dynamic>>[];
        final rows = reconcileExperimentalHistory(
          received: [promptA, a, promptB, b],
          saved: [savedUserB, savedB],
          prompts: prompts,
          handoff: (old, replacement) => handoffs.add(old),
        );
        expect(rows.map((r) => r['content']), [
          'A',
          'same prose',
          'B',
          'same prose',
        ]);
        expect(rows[0], same(promptA));
        expect(rows[1], same(a));
        expect(a['_gateway_reasoning'], 'A reasoning');
        expect(a['_gateway_response_outcome'], outcome);
        expect(handoffs, [same(b)]);
        expect(rows.last['id'], 17);
        expect(rows.last['_gateway_client_turn_id'], 'B');

        final proof = reconcileExperimentalHistory(
          received: [promptA, a, promptB, b],
          saved: [
            {
              'id': 7,
              'role': 'assistant',
              'content': 'saved A',
              '_chat_response_complete': true,
            },
            savedUserB,
            savedB,
          ],
          prompts: prompts,
          handoff: (_, _) {},
        );
        expect(proof.map((r) => r['id']), [7, 16, 17]);
        expect(proof.first['_gateway_response_outcome'], outcome);
        expect(proof.first['_chat_response_complete'], outcome == 'completed');
      },
    );
  }

  test(
    'successive unproved responses remain ordered before newer saved rows',
    () {
      final a = <String, dynamic>{
        'role': 'assistant',
        'content': 'A',
        '_gateway_client_turn_id': 'A',
        '_gateway_response_outcome': 'unknown',
      };
      final b = <String, dynamic>{
        'role': 'assistant',
        'content': 'B',
        '_gateway_client_turn_id': 'B',
        '_gateway_final_message_ref': 17,
        '_gateway_response_outcome': 'failed',
      };
      final c = <String, dynamic>{
        'role': 'assistant',
        'content': 'C',
        '_gateway_client_turn_id': 'C',
        '_gateway_final_message_ref': 27,
        '_chat_response_complete': true,
      };
      final rows = reconcileExperimentalHistory(
        received: [a, b, c],
        saved: [
          {'id': 26, 'role': 'user', 'content': 'C prompt'},
          {'id': 27, 'role': 'assistant', 'content': 'saved C'},
          {'id': 30, 'role': 'assistant', 'content': 'newer saved'},
        ],
        prompts: Map.identity(),
        handoff: (_, _) {},
      );
      expect(rows.map((r) => r['content']), [
        'A',
        'B',
        'C prompt',
        'saved C',
        'newer saved',
      ]);
      expect(rows[0], same(a));
      expect(rows[1], same(b));
    },
  );
}
