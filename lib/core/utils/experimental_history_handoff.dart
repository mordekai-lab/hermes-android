/// Reconcile each received response only against its own physical row reference.
/// Local prompt associations are captured at send time, never inferred from
/// saved prose or neighbouring saved rows. Unproved groups keep their objects.
List<Map<String, dynamic>> reconcileExperimentalHistory({
  required List<Map<String, dynamic>> received,
  required List<Map<String, dynamic>> saved,
  required Map<Map<String, dynamic>, Map<String, dynamic>> prompts,
  required void Function(Map<String, dynamic>, Map<String, dynamic>) handoff,
}) {
  final rows = List<Map<String, dynamic>>.of(saved);
  final replacements =
      Map<Map<String, dynamic>, Map<String, dynamic>>.identity();
  final retiredPrompts = Set<Map<String, dynamic>>.identity();
  for (final response in received) {
    final reference = response['_gateway_final_message_ref'];
    final index = rows.indexWhere(
      (row) =>
          reference is int &&
          row['id'] == reference &&
          const {'assistant', 'agent'}.contains(row['role']) &&
          row['content'] is String &&
          (row['content'] as String).isNotEmpty,
    );
    if (response['_gateway_client_turn_id'] == null ||
        response['_gateway_pending_response'] == true ||
        index < 0) {
      continue;
    }
    final replacement = <String, dynamic>{...response, ...rows[index]};
    // Physical correlation is not successful lifecycle evidence.
    if (response['_chat_response_complete'] == false) {
      replacement['_chat_response_complete'] = false;
    }
    rows[index] = replacement;
    replacements[response] = replacement;
    final prompt = prompts[response];
    if (prompt != null) retiredPrompts.add(prompt);
    handoff(response, replacement);
  }

  final ownedPrompts = prompts.values.toSet();
  final insertions = <int, List<Map<String, dynamic>>>{};
  var previousPosition = 0;
  for (final row in received) {
    final replacement = replacements[row];
    if (replacement != null || row['id'] != null) {
      final id = replacement?['id'] ?? row['id'];
      final index = rows.indexWhere((savedRow) => savedRow['id'] == id);
      if (index >= 0) previousPosition = index + 1;
      continue;
    }
    if (retiredPrompts.contains(row) || ownedPrompts.contains(row)) continue;
    final reference = row['_gateway_final_message_ref'];
    var position = previousPosition;
    if (reference is int) {
      final next = rows.indexWhere(
        (savedRow) => savedRow['id'] is int && savedRow['id'] > reference,
      );
      position = next < 0 ? rows.length : next;
    }
    final group = insertions.putIfAbsent(position, () => []);
    final prompt = prompts[row];
    if (prompt != null) group.add(prompt);
    group.add(row);
    previousPosition = position;
  }
  return [
    for (var index = 0; index <= rows.length; index++) ...[
      ...?insertions[index],
      if (index < rows.length) rows[index],
    ],
  ];
}
