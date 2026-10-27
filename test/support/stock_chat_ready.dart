import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/gateway_turn_application_controller.dart';

/// Wait on the production control greeting and composer, not the removed stock
/// failure banner. No injected session factory or recovery capability bypass.
Future<void> stockChatReady(
  WidgetTester tester,
  GatewayTurnApplicationController controller,
  SavedConnection connection,
) async {
  var ready = false;
  Object? failure;
  controller.normalSessionFor(connection).client!.readGatewayReadyFrame().then((
    frame,
  ) {
    ready = (frame['params'] as Map)['type'] == 'gateway.ready';
  }, onError: (Object error) => failure = error);
  for (var i = 0; i < 3000; i++) {
    await tester.pump();
    if (failure != null) fail('Stock control greeting failed: $failure');
    final send = find.byKey(const Key('chat-send-message'));
    if (ready &&
        send.evaluate().isNotEmpty &&
        tester.widget<IconButton>(send).onPressed != null) {
      expect(
        find.byKey(const ValueKey('legacy-transport-notice')),
        findsNothing,
      );
      return;
    }
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  fail('Production stock greeting/composer readiness did not arrive');
}
