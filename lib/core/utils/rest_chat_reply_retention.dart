import 'chat_display_items.dart';

/// A successful SSE response is evidence even when the subsequent history GET
/// succeeds before the server has persisted that turn. Retain the local
/// transcript until durable identity, not matching text, confirms a new answer.
class RestChatReplyRetention {
  final int? admissionFloor;
  List<Map<String, dynamic>>? _completedRows;

  RestChatReplyRetention.admit(
    List<Map<String, dynamic>> history, {
    required bool historyKnown,
  }) : admissionFloor = historyKnown && history.every((row) => _id(row) != null)
           ? history.fold<int>(0, (floor, row) {
               final id = _id(row)!;
               return id > floor ? id : floor;
             })
           : null;

  static int? _id(Map<String, dynamic> row) =>
      int.tryParse(row['id']?.toString() ?? '');

  bool get hasRetainedReply => _completedRows != null;

  void complete(List<Map<String, dynamic>> rows) {
    _completedRows = List.of(rows);
  }

  List<Map<String, dynamic>> reconcile(List<Map<String, dynamic>> canonical) {
    final retained = _completedRows;
    if (retained == null) return canonical;
    final floor = admissionFloor;
    final responseRows = floor == null
        ? const <Map<String, dynamic>>[]
        : canonical.where((row) => (_id(row) ?? -1) > floor).toList();
    if (buildChatDisplayItems(messages: responseRows)
        .whereType<Map<String, dynamic>>()
        .any((row) => row['role'] == 'assistant')) {
      _completedRows = null;
      return canonical;
    }
    // Older pages can be prepended by identity without replacing the streamed
    // tail. Unknown-floor histories are deliberately not text-deduplicated.
    final ids = retained.map(_id).whereType<int>().toList()..sort();
    return [
      if (ids.isNotEmpty)
        ...canonical.where((row) => _id(row) != null && _id(row)! < ids.first),
      ...retained,
    ];
  }
}
