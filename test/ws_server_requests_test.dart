import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/clarify_attachment_owner.dart';
import 'package:hermes_android/core/services/connection_mutation_barrier.dart';
import 'package:hermes_android/core/services/desktop_gateway_client.dart';
import 'package:hermes_android/core/services/gateway_turn_application_controller.dart';
import 'package:hermes_android/core/services/gateway_turn_journal.dart';
import 'package:hermes_android/core/services/ws_client.dart';

void main() {
  for (final withTurnRecovery in [false, true]) {
    final ownerName = withTurnRecovery ? 'recovery-v2 owner' : 'Desktop owner';
    group('$ownerName request-bound clarify images', () {
      late _ServerRequestGateway gateway;
      late ClarifyAttachmentOwner owner;
      late List<StreamEvent> events;
      late Future<bool> Function({
        required String requestId,
        required String answer,
        String? questionId,
      })
      respond;
      final expectedSocketCount = withTurnRecovery ? 2 : 1;
      const name = 'screen "λ".png';
      const dataUrl =
          'data:image/png;base64,'
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8'
          '/x8AAwMCAO+aF9sAAAAASUVORK5CYII=';
      const path = '/srv/hermes/work/uploads/screen "λ"\\line\nshot.png';
      const refText = r'  @file:/srv/hermes/uploads/raw "λ"\ref.png  ';

      setUp(() async {
        gateway = await _ServerRequestGateway.start(
          withDashboardAuth: true,
          withTurnRecovery: withTurnRecovery,
        );
        addTearDown(gateway.stop);
        gateway.fileAttachResult = {
          'attached': true,
          'uploaded': true,
          'name': name,
          'path': path,
          'ref_text': refText,
        };
        final connection = SavedConnection(
          id: 'clarify-image-$withTurnRecovery',
          label: 'Clarify image fixture',
          host: '127.0.0.1',
          port: gateway.port,
          apiKey: 'fixture-key',
          dashboardPortOverride: gateway.port,
          dashboardUsername: 'user',
          dashboardPassword: 'pass',
          gatewayProfile: 'work',
        );
        final receivedEvents = <StreamEvent>[];
        events = receivedEvents;
        if (withTurnRecovery) {
          final controller = GatewayTurnApplicationController(
            journalFactory: () =>
                GatewayTurnJournal(store: _MemoryJournalStore()),
          );
          addTearDown(controller.close);
          // Exercise the default private application wrapper, not a fake
          // session factory or a separately constructed Desktop client.
          final session = controller.sessionFor(connection);
          expect(session, isA<ClarifyAttachmentOwner>());
          owner = session as ClarifyAttachmentOwner;
          respond = session.tryRespondToClarify;
          for (final localSessionId in ['mobile-1', 'mobile-2']) {
            session.setAsyncEventListener(
              localSessionId,
              (_, event) => receivedEvents.add(event),
            );
            await session.submit(
              localSessionId: localSessionId,
              text: 'Start $localSessionId',
            );
          }
          // Two private sockets/runtimes make an accidental control-socket
          // upload or delegation to the latest session observable.
          expect(gateway.socketCount, expectedSocketCount);
        } else {
          final client = DesktopGatewayClient.fromConnection(connection);
          addTearDown(client.close);
          // Disable only the independent background reconnect policy. The
          // upload itself must still never reconnect/resume/create on failure.
          client.setReconnectAllowed(false);
          client.setAsyncEventListener((_, event) => receivedEvents.add(event));
          owner = client;
          respond =
              ({
                required String requestId,
                required String answer,
                String? questionId,
              }) async {
                await client.respondToClarify(
                  requestId: requestId,
                  questionId: questionId,
                  answer: answer,
                );
                return true;
              };
          await client.ensureSession('mobile-1');
        }
      });

      Future<String> request({
        String wireId = 'image-clarify',
        List<Map<String, dynamic>> questions = const [
          {'qid': 'q1', 'question': 'Send a screenshot?'},
        ],
        Map<String, String> answers = const {},
      }) async {
        final eventOffset = events.length;
        gateway.sendServerRequest(
          id: wireId,
          method: 'clarify',
          params: {
            'session_id': 'runtime-1',
            'questions': questions,
            if (answers.isNotEmpty) 'answers': answers,
          },
        );
        await _waitFor(
          () => events
              .skip(eventOffset)
              .any((event) => event.type == 'clarify.request'),
        );
        return events
            .skip(eventOffset)
            .firstWhere((event) => event.type == 'clarify.request')
            .data['request_id']
            .toString();
      }

      void expectOnlyMethodsSince(int offset, List<String> methods) {
        expect(gateway.socketCount, expectedSocketCount);
        expect(
          gateway.clientFrames
              .skip(offset)
              .where((entry) => entry.frame['method'] != null)
              .map((entry) => entry.frame['method']),
          orderedEquals(methods),
        );
      }

      test('uploads then locks on original socket/runtime/profile', () async {
        final requestId = await request();
        final frameOffset = gateway.clientFrames.length;
        expect(
          owner.canAttachToClarify(requestId: requestId, questionId: 'q1'),
          isTrue,
        );
        final attachment = await owner.attachToClarify(
          requestId: requestId,
          questionId: 'q1',
          name: name,
          dataUrl: dataUrl,
        );
        expect(attachment.name, name);
        expect(attachment.path, path);
        expect(attachment.refText, refText);
        expect(attachment.uploaded, isTrue);
        expect(gateway.fileAttachments.single, {
          'session_id': 'runtime-1',
          'profile': 'work',
          'name': name,
          'path': '',
          'data_url': dataUrl,
        });
        expect(gateway.fileAttachSocketIndexes, [0]);
        expect(gateway.clarifyLocks, isEmpty);
        expectOnlyMethodsSince(frameOffset, ['file.attach']);

        // Clarify results are not prompts: preserve the opaque reference and
        // JSON-quote the path, including quotes, backslash and LF.
        final reference = clarifyImageReference(attachment);
        expect(reference, startsWith('$refText\n'));
        expect(
          reference,
          contains('Attached image path: ${jsonEncode(path)}\n'),
        );
        expect(reference, contains('vision_analyze'));
        expect(reference, contains('image_url'));
        final answer = 'Look at this screenshot.\n$reference';
        expect(
          await respond(requestId: requestId, questionId: 'q1', answer: answer),
          isTrue,
        );
        expect(gateway.clarifyLocks.single, {
          'request_id': 'image-clarify',
          'question_id': 'q1',
          'answer': answer,
          'profile': 'work',
        });
        expect(gateway.clarifyLockSocketIndexes, [0]);
        expectOnlyMethodsSince(frameOffset, ['file.attach', 'clarify.lock']);
        expect(
          owner.canAttachToClarify(requestId: requestId, questionId: 'q1'),
          isFalse,
        );
        expect(gateway.serverResponses, isNot(contains('image-clarify')));
      });

      test('refuses unknown requests and invalid/locked qids', () async {
        final requestId = await request(
          wireId: 'partial-clarify',
          questions: const [
            {'qid': 'locked', 'question': 'Already answered?'},
            {'qid': 'q1', 'question': 'First image?'},
            {'qid': 'q2', 'question': 'Second image?'},
          ],
          answers: const {'locked': 'Previously supplied'},
        );
        gateway.sendServerRequest(
          id: 'not-a-clarification',
          method: 'secret',
          params: {
            'session_id': 'runtime-1',
            'env_var': 'TOKEN',
            'prompt': 'Token',
          },
        );
        await _waitFor(
          () => events.any((event) => event.type == 'secret.request'),
        );
        final secretId = events
            .lastWhere((event) => event.type == 'secret.request')
            .data['request_id']
            .toString();
        final frameOffset = gateway.clientFrames.length;
        for (final invalid in [
          (requestId: 'unknown-request', qid: 'q1'),
          (requestId: 'partial-clarify', qid: 'q1'),
          (requestId: secretId, qid: 'q1'),
          (requestId: requestId, qid: 'unknown-qid'),
          (requestId: requestId, qid: ''),
          (requestId: requestId, qid: ' q1 '),
          (requestId: requestId, qid: 'locked'),
        ]) {
          expect(
            owner.canAttachToClarify(
              requestId: invalid.requestId,
              questionId: invalid.qid,
            ),
            isFalse,
          );
          await expectLater(
            owner.attachToClarify(
              requestId: invalid.requestId,
              questionId: invalid.qid,
              name: name,
              dataUrl: dataUrl,
            ),
            throwsStateError,
          );
        }
        expectOnlyMethodsSince(frameOffset, []);
        expect(
          await respond(
            requestId: requestId,
            questionId: 'q1',
            answer: 'First answer',
          ),
          isTrue,
        );
        expect(
          owner.canAttachToClarify(requestId: requestId, questionId: 'q2'),
          isTrue,
        );
        expect(
          owner.canAttachToClarify(requestId: requestId, questionId: 'q1'),
          isFalse,
        );
        await expectLater(
          owner.attachToClarify(
            requestId: requestId,
            questionId: 'q1',
            name: name,
            dataUrl: dataUrl,
          ),
          throwsStateError,
        );
        expect(gateway.fileAttachments, isEmpty);
        expectOnlyMethodsSince(frameOffset, ['clarify.lock']);
      });

      for (final ending in [
        'cancellation',
        'replacement',
        'lock',
        'disconnect',
      ]) {
        test('held upload cannot outlive request $ending', () async {
          final wireId = ending == 'lock' ? 'partial-clarify' : 'image-clarify';
          final requestId = await request(
            wireId: wireId,
            questions: [
              {'qid': 'q1', 'question': 'Send a screenshot?'},
              if (ending == 'lock') {'qid': 'q2', 'question': 'Next image?'},
            ],
          );
          final frameOffset = gateway.clientFrames.length;
          gateway.holdFileAttachResponses = true;
          var settled = false;
          // Observe errors immediately, including socket-close rejection, so
          // the intentionally suspended operation never leaks an async error.
          final upload = owner
              .attachToClarify(
                requestId: requestId,
                questionId: 'q1',
                name: name,
                dataUrl: dataUrl,
              )
              .then<Object>(
                (attachment) {
                  settled = true;
                  return attachment;
                },
                onError: (Object error) {
                  settled = true;
                  return error;
                },
              );
          await _waitFor(() => gateway.heldFileAttachResponseCount == 1);
          expect(gateway.fileAttachments, hasLength(1));
          expect(gateway.fileAttachSocketIndexes, [0]);
          expect(settled, isFalse);
          expect(
            owner.canAttachToClarify(requestId: requestId, questionId: 'q1'),
            isTrue,
          );
          String? replacementId;
          switch (ending) {
            case 'cancellation':
              gateway.sendEvent(
                type: 'request.cancel',
                sessionId: 'runtime-1',
                payload: {'id': wireId, 'method': 'clarify'},
              );
              await _waitFor(
                () => events.any(
                  (event) =>
                      event.type == 'request.cancel' &&
                      event.data['id'] == requestId,
                ),
              );
              break;
            case 'replacement':
              replacementId = await request(
                wireId: wireId,
                questions: const [
                  {'qid': 'q1', 'question': 'A different screenshot?'},
                ],
              );
              expect(replacementId, isNot(requestId));
              expect(requestId, endsWith(':$wireId'));
              expect(replacementId, endsWith(':$wireId'));
              expect(
                owner.canAttachToClarify(
                  requestId: replacementId,
                  questionId: 'q1',
                ),
                isTrue,
              );
              break;
            case 'lock':
              expect(
                await respond(
                  requestId: requestId,
                  questionId: 'q1',
                  answer: 'Answered on another route',
                ),
                isTrue,
              );
              expect(
                owner.canAttachToClarify(
                  requestId: requestId,
                  questionId: 'q2',
                ),
                isTrue,
              );
              break;
            case 'disconnect':
              await gateway.closeSocket(0);
              await _waitFor(
                () => events.any(
                  (event) =>
                      event.type == 'request.cancel' &&
                      event.data['id'] == requestId,
                ),
              );
              break;
          }
          expect(
            owner.canAttachToClarify(requestId: requestId, questionId: 'q1'),
            isFalse,
          );
          if (ending != 'disconnect') expect(settled, isFalse);
          gateway.holdFileAttachResponses = false;
          gateway.releaseFileAttachResponses();
          final outcome = await upload.timeout(const Duration(seconds: 5));
          if (ending == 'disconnect') {
            expect(
              outcome,
              isA<JsonRpcError>()
                  .having((error) => error.method, 'method', 'file.attach')
                  .having(
                    (error) => error.reason,
                    'reason',
                    'connection_closed',
                  ),
            );
          } else {
            expect(outcome, isA<StateError>());
          }
          expect(gateway.heldFileAttachResponseCount, 0);
          await expectLater(
            owner.attachToClarify(
              requestId: requestId,
              questionId: 'q1',
              name: name,
              dataUrl: dataUrl,
            ),
            throwsStateError,
          );
          expectOnlyMethodsSince(frameOffset, [
            'file.attach',
            if (ending == 'lock') 'clarify.lock',
          ]);
          expect(gateway.serverResponses, isNot(contains(wireId)));

          if (replacementId != null) {
            // A rejected late result must neither consume nor poison the new
            // authority, even when socket, runtime, qid and wire ID are reused.
            final attachment = await owner.attachToClarify(
              requestId: replacementId,
              questionId: 'q1',
              name: name,
              dataUrl: dataUrl,
            );
            final answer = clarifyImageReference(attachment);
            expect(
              await respond(
                requestId: replacementId,
                questionId: 'q1',
                answer: answer,
              ),
              isTrue,
            );
            expect(gateway.fileAttachSocketIndexes, [0, 0]);
            expect(gateway.clarifyLockSocketIndexes, [0]);
            expect(gateway.clarifyLocks.single, {
              'request_id': wireId,
              'question_id': 'q1',
              'answer': answer,
              'profile': 'work',
            });
            expectOnlyMethodsSince(frameOffset, [
              'file.attach',
              'file.attach',
              'clarify.lock',
            ]);
          }
        });
      }
    });
  }

  test(
    'closed recovery owner detach cannot reject a same-ID replacement request',
    () async {
      final gateway = await _ServerRequestGateway.start(
        withDashboardAuth: true,
        withTurnRecovery: true,
        reuseSessionIdentity: true,
      );
      final controller = GatewayTurnApplicationController(
        journalFactory: () => GatewayTurnJournal(store: _MemoryJournalStore()),
      );
      addTearDown(() async {
        await controller.close();
        await gateway.stop();
      });
      final connection = SavedConnection(
        id: 'same-id-recovery-replacement',
        label: 'Fixture',
        host: '127.0.0.1',
        port: gateway.port,
        apiKey: 'fixture',
        dashboardPortOverride: gateway.port,
        dashboardUsername: 'user',
        dashboardPassword: 'pass',
      );
      final old = controller.sessionFor(connection);
      final oldEvent = Completer<StreamEvent>();
      final oldToken = old.setAsyncEventListener('mobile-1', (_, event) {
        if (event.type == 'approval.request') oldEvent.complete(event);
      });
      await old.submit(localSessionId: 'mobile-1', text: 'Old explicit turn');
      void approval(int socket, String id) => gateway.sendServerRequest(
        socketIndex: socket,
        id: id,
        method: 'approval',
        params: {
          'session_id': 'runtime-1',
          'request_id': 'approval-reused',
          'command': 'echo fixture',
          'choices': ['once', 'deny'],
        },
      );
      approval(0, 'same-request');
      final oldRequest = (await oldEvent.future).data['server_request_id']
          .toString();
      final mutation = ConnectionMutationBarrier.begin([connection.id]);
      mutation.release();
      final current = controller.sessionFor(connection);
      expect(current, isNot(same(old)));
      final currentEvent = Completer<StreamEvent>();
      final laterEvent = Completer<StreamEvent>();
      final currentEvents = <StreamEvent>[];
      final superseded = current.setAsyncEventListener('mobile-1', (_, _) {});
      final token = current.setAsyncEventListener('mobile-1', (_, event) {
        currentEvents.add(event);
        if (event.type == 'approval.request' && !currentEvent.isCompleted) {
          currentEvent.complete(event);
        } else if (event.type == 'approval.request') {
          laterEvent.complete(event);
        }
      });
      await current.submit(
        localSessionId: 'mobile-1',
        text: 'Fresh explicit turn',
      );
      expect(gateway.socketCount, 2);
      approval(1, 'same-request');
      final request = (await currentEvent.future).data['server_request_id']
          .toString();
      // Wire, runtime, stored, local and approval IDs are reused. The bridge's
      // owner-qualified handles must nevertheless remain distinct.
      expect(oldRequest, endsWith(':same-request'));
      expect(request, endsWith(':same-request'));
      expect(request, isNot(oldRequest));
      await expectLater(
        old.tryRespondToApproval(
          sessionId: 'mobile-1',
          requestId: oldRequest,
          choice: 'once',
        ),
        throwsStateError,
      );
      expect(
        await current.tryRespondToApproval(
          sessionId: 'mobile-1',
          requestId: oldRequest,
          choice: 'once',
        ),
        isFalse,
      );
      for (var i = 0; i < 2; i++) {
        old.removeAsyncEventListener('mobile-1', oldToken);
        old.removeAsyncEventListener('mobile-1', token);
        current.removeAsyncEventListener('mobile-1', oldToken);
        current.removeAsyncEventListener('mobile-1', superseded);
        current.removeAsyncEventListener('other-local', token);
        current.removeAsyncEventListener('mobile-1', Object());
      }
      expect(
        current.ownsApprovalRequest(sessionId: 'mobile-1', requestId: request),
        isTrue,
      );
      expect(
        gateway.serverResponseSocketKeys,
        isNot(contains('1:same-request')),
      );
      final answered = Completer<Map<String, dynamic>>();
      gateway.onServerResponse = (socket, frame) {
        if (socket == 1 && frame['id'] == 'same-request') {
          answered.complete(frame);
        }
      };
      expect(
        await current.tryRespondToApproval(
          sessionId: 'mobile-1',
          requestId: request,
          choice: 'deny',
        ),
        isTrue,
      );
      expect((await answered.future)['result'], {'choice': 'deny'});
      expect(
        currentEvents.where((e) => e.type == 'approval.request'),
        hasLength(1),
      );

      // The same replacement registration must still receive new requests,
      // not merely leave an already-delivered request answerable.
      final laterAnswered = Completer<Map<String, dynamic>>();
      gateway.onServerResponse = (socket, frame) {
        if (socket == 1 && frame['id'] == 'after-late-detach') {
          laterAnswered.complete(frame);
        }
      };
      approval(1, 'after-late-detach');
      final laterRequest = (await laterEvent.future).data['server_request_id']
          .toString();
      expect(
        await current.tryRespondToApproval(
          sessionId: 'mobile-1',
          requestId: laterRequest,
          choice: 'deny',
        ),
        isTrue,
      );
      expect((await laterAnswered.future)['result'], {'choice': 'deny'});
      expect(
        currentEvents.where((e) => e.type == 'approval.request'),
        hasLength(2),
      );

      // Exact still-open removal must retain its existing rejection semantics.
      final rejected = Completer<Map<String, dynamic>>();
      gateway.onServerResponse = (socket, frame) {
        if (socket == 1 && frame['id'] == 'detach-request') {
          rejected.complete(frame);
        }
      };
      final delivered = Completer<void>();
      final exact = current.setAsyncEventListener('mobile-1', (_, event) {
        if (event.type == 'approval.request') delivered.complete();
      });
      approval(1, 'detach-request');
      await delivered.future;
      current.removeAsyncEventListener('mobile-1', token);
      expect(
        gateway.serverResponseSocketKeys,
        isNot(contains('1:detach-request')),
      );
      current.removeAsyncEventListener('mobile-1', exact);
      current.removeAsyncEventListener('mobile-1', exact);
      expect((await rejected.future)['error'], containsPair('code', -32601));
      await controller.close();
      current.removeAsyncEventListener('mobile-1', exact);
    },
  );

  test('WsClient advertises and answers server initiated requests', () async {
    final gateway = await _ServerRequestGateway.start();
    addTearDown(gateway.stop);
    final requests = <GatewayServerRequest>[];
    final client = WsClient(
      'http://127.0.0.1:${gateway.port}',
      token: 'fixture-key',
      profile: 'work',
      heartbeatInterval: const Duration(hours: 1),
      heartbeatDeadline: const Duration(hours: 2),
    );
    client.onServerRequest = (request) {
      requests.add(request);
      request.respond({'value': 'answered'});
      return true;
    };
    addTearDown(client.close);

    await client.connect().timeout(const Duration(seconds: 5));
    await _waitFor(() => gateway.capabilityFrames.isNotEmpty);
    expect(gateway.capabilityFrames.single['params'], {
      'server_requests': true,
    });

    gateway.sendServerRequest(
      id: 'srq-live',
      method: 'secret',
      params: {
        'session_id': 'runtime-1',
        'env_var': 'TOKEN',
        'prompt': 'Token',
      },
    );
    await _waitFor(() => gateway.serverResponses.containsKey('srq-live'));

    expect(requests, hasLength(1));
    expect(requests.single.method, 'secret');
    expect(requests.single.replayed, isFalse);
    expect(gateway.serverResponses['srq-live'], {
      'jsonrpc': '2.0',
      'id': 'srq-live',
      'result': {'value': 'answered'},
    });
  });

  test(
    'WsClient rejects unhandled methods and can replay open requests',
    () async {
      final gateway = await _ServerRequestGateway.start();
      addTearDown(gateway.stop);
      final client = WsClient(
        'http://127.0.0.1:${gateway.port}',
        token: 'fixture-key',
        heartbeatInterval: const Duration(hours: 1),
        heartbeatDeadline: const Duration(hours: 2),
      );
      addTearDown(client.close);
      await client.connect().timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(gateway.capabilityFrames, isEmpty);

      gateway.sendServerRequest(
        id: 'srq-unknown',
        method: 'preview.read',
        params: {'session_id': 'runtime-1'},
      );
      await _waitFor(() => gateway.serverResponses.containsKey('srq-unknown'));
      expect(
        gateway.serverResponses['srq-unknown']?['error'],
        containsPair('code', -32601),
      );

      GatewayServerRequest? replayed;
      client.onServerRequest = (request) {
        replayed = request;
        request.respond({'choice': 'deny'});
        return true;
      };
      client.deliverOpenRequests([
        {
          'id': 'srq-replayed',
          'method': 'approval',
          'params': {
            'session_id': 'runtime-1',
            'request_id': 'approval-1',
            'command': 'rm file',
          },
        },
      ]);
      await _waitFor(() => gateway.serverResponses.containsKey('srq-replayed'));
      expect(replayed?.replayed, isTrue);
      expect(gateway.serverResponses['srq-replayed']?['result'], {
        'choice': 'deny',
      });
    },
  );

  test(
    'Desktop bridge routes approval, secret and clarify responses',
    () async {
      final gateway = await _ServerRequestGateway.start(
        withDashboardAuth: true,
      );
      addTearDown(gateway.stop);
      final client = DesktopGatewayClient.fromConnection(
        SavedConnection(
          id: 'server-request-test',
          label: 'Local fixture',
          host: 'localhost',
          port: gateway.port,
          apiKey: 'fixture-key',
          useHttps: false,
          desktopGatewayUrl: 'http://127.0.0.1:${gateway.port}',
          dashboardUsername: 'user',
          dashboardPassword: 'pass',
        ),
      );
      addTearDown(client.close);
      final events = <StreamEvent>[];
      client.setAsyncEventListener((_, event) => events.add(event));
      await client.ensureSession('mobile-1');

      gateway.sendServerRequest(
        id: 'srq-approval',
        method: 'approval',
        params: {
          'session_id': 'runtime-1',
          'request_id': 'approval-queue-1',
          'command': 'rm file',
          'description': 'Delete a file',
          'choices': ['once', 'deny'],
        },
      );
      await _waitFor(
        () => events.any((event) => event.type == 'approval.request'),
      );
      final approvalEvent = events.lastWhere(
        (event) => event.type == 'approval.request',
      );
      final approvalRequestId =
          approvalEvent.data['server_request_id'] as String;
      expect(approvalRequestId, endsWith(':srq-approval'));
      expect(
        client.ownsApprovalRequest('mobile-1', requestId: approvalRequestId),
        isTrue,
      );
      expect(
        client.ownsApprovalRequest('mobile-1', requestId: 'another-request'),
        isFalse,
      );
      await client.respondToApproval(sessionId: 'mobile-1', choice: 'deny');
      await _waitFor(() => gateway.serverResponses.containsKey('srq-approval'));
      expect(
        client.ownsApprovalRequest('mobile-1', requestId: approvalRequestId),
        isFalse,
      );
      expect(gateway.serverResponses['srq-approval']?['result'], {
        'choice': 'deny',
      });

      gateway.sendServerRequest(
        id: 'srq-secret',
        method: 'secret',
        params: {
          'session_id': 'runtime-1',
          'env_var': 'TOKEN',
          'prompt': 'Enter token',
        },
      );
      await _waitFor(
        () => events.any((event) => event.type == 'secret.request'),
      );
      final secretRequestId = events
          .lastWhere((event) => event.type == 'secret.request')
          .data['request_id']
          .toString();
      expect(secretRequestId, endsWith(':srq-secret'));
      await client.respondToSecret(requestId: secretRequestId, value: 'value');
      await _waitFor(() => gateway.serverResponses.containsKey('srq-secret'));
      expect(gateway.serverResponses['srq-secret']?['result'], {
        'value': 'value',
      });

      gateway.sendServerRequest(
        id: 'srq-clarify',
        method: 'clarify',
        params: {
          'session_id': 'runtime-1',
          'questions': [
            {'qid': 'q1', 'question': 'Proceed?'},
          ],
        },
      );
      await _waitFor(
        () => events.any((event) => event.type == 'clarify.request'),
      );
      final clarifyRequestId = events
          .lastWhere((event) => event.type == 'clarify.request')
          .data['request_id']
          .toString();
      await client.respondToClarify(
        requestId: clarifyRequestId,
        questionId: 'q1',
        answer: 'Yes',
      );
      await _waitFor(() => gateway.clarifyLocks.isNotEmpty);
      expect(gateway.clarifyLocks.single, {
        'request_id': 'srq-clarify',
        'question_id': 'q1',
        'answer': 'Yes',
      });
    },
  );

  test(
    'application recovery socket routes requests and responses end to end',
    () async {
      final gateway = await _ServerRequestGateway.start(
        withDashboardAuth: true,
        withTurnRecovery: true,
      );
      addTearDown(gateway.stop);
      final controller = GatewayTurnApplicationController(
        journalFactory: () => GatewayTurnJournal(store: _MemoryJournalStore()),
      );
      addTearDown(controller.close);
      final session = controller.sessionFor(
        SavedConnection(
          id: 'recovery-server-request-test',
          label: 'Local fixture',
          host: 'localhost',
          port: gateway.port,
          apiKey: 'fixture-key',
          useHttps: false,
          desktopGatewayUrl: 'http://127.0.0.1:${gateway.port}',
          dashboardUsername: 'user',
          dashboardPassword: 'pass',
        ),
      );
      final events = <StreamEvent>[];
      final registration = session.setAsyncEventListener(
        'mobile-1',
        (_, event) => events.add(event),
      );

      await session.submit(localSessionId: 'mobile-1', text: 'Hello');
      expect(gateway.socketCount, 1);

      gateway.sendServerRequest(
        id: 'recovery-clarify',
        method: 'clarify',
        params: {
          'session_id': 'runtime-1',
          'questions': [
            {'qid': 'q1', 'question': 'Proceed?'},
          ],
        },
      );
      await _waitFor(
        () => events.any((event) => event.type == 'clarify.request'),
      );
      expect(
        await session.tryRespondToClarify(
          requestId: events
              .lastWhere((event) => event.type == 'clarify.request')
              .data['request_id']
              .toString(),
          questionId: 'q1',
          answer: 'Yes',
        ),
        isTrue,
      );
      await _waitFor(() => gateway.clarifyLocks.isNotEmpty);
      expect(gateway.clarifyLocks.single['answer'], 'Yes');
      expect(
        events.any(
          (event) =>
              event.type == 'clarify.remaining' &&
              (event.data['remaining'] as List).isEmpty,
        ),
        isTrue,
      );

      for (final request in <({String id, String method})>[
        (id: 'recovery-approval', method: 'approval'),
        (id: 'recovery-sudo', method: 'sudo'),
        (id: 'recovery-secret', method: 'secret'),
      ]) {
        gateway.sendServerRequest(
          id: request.id,
          method: request.method,
          params: {
            'session_id': 'runtime-1',
            if (request.method == 'approval') ...{
              'request_id': 'approval-1',
              'command': 'echo ok',
              'choices': ['once', 'deny'],
            },
            if (request.method == 'sudo') 'prompt': 'Password',
            if (request.method == 'secret') ...{
              'env_var': 'TOKEN',
              'prompt': 'Token',
            },
          },
        );
      }
      await _waitFor(
        () =>
            events.any((event) => event.type == 'approval.request') &&
            events.any((event) => event.type == 'sudo.request') &&
            events.any((event) => event.type == 'secret.request'),
      );
      gateway.sendServerRequest(
        id: 'recovery-approval-concurrent',
        method: 'approval',
        params: {
          'session_id': 'runtime-1',
          'request_id': 'approval-2',
          'command': 'echo concurrent',
          'choices': ['once', 'deny'],
        },
      );
      await _waitFor(
        () =>
            gateway.serverResponses.containsKey('recovery-approval-concurrent'),
      );
      expect(
        gateway.serverResponses['recovery-approval-concurrent']?['error'],
        containsPair('code', -32601),
      );
      expect(
        events.where((event) => event.type == 'approval.request'),
        hasLength(1),
      );
      expect(
        await session.tryRespondToApproval(
          sessionId: 'mobile-1',
          choice: 'once',
          requestId: events
              .lastWhere((event) => event.type == 'approval.request')
              .data['server_request_id']
              .toString(),
        ),
        isTrue,
      );
      expect(
        await session.tryRespondToSudo(
          requestId: events
              .lastWhere((event) => event.type == 'sudo.request')
              .data['request_id']
              .toString(),
          password: 'sudo-value',
        ),
        isTrue,
      );
      expect(
        await session.tryRespondToSecret(
          requestId: events
              .lastWhere((event) => event.type == 'secret.request')
              .data['request_id']
              .toString(),
          value: 'secret-value',
        ),
        isTrue,
      );
      await _waitFor(
        () => gateway.serverResponses.keys.toSet().containsAll({
          'recovery-approval',
          'recovery-sudo',
          'recovery-secret',
        }),
      );
      expect(gateway.serverResponses['recovery-approval']?['result'], {
        'choice': 'once',
      });
      expect(gateway.serverResponses['recovery-sudo']?['result'], {
        'value': 'sudo-value',
      });
      expect(gateway.serverResponses['recovery-secret']?['result'], {
        'value': 'secret-value',
      });
      expect(gateway.serverResponseSocketIndexes['recovery-approval'], 0);
      expect(gateway.serverResponseSocketIndexes['recovery-sudo'], 0);
      expect(gateway.serverResponseSocketIndexes['recovery-secret'], 0);
      expect(gateway.clarifyLockSocketIndexes.single, 0);

      final staleSecondEvents = <StreamEvent>[];
      final staleSecondRegistration = session.setAsyncEventListener(
        'mobile-2',
        (_, event) => staleSecondEvents.add(event),
      );
      await session.submit(localSessionId: 'mobile-2', text: 'Hello again');
      expect(gateway.socketCount, 2);
      gateway.sendServerRequest(
        id: 'recovery-replayed',
        method: 'secret',
        socketIndex: 1,
        params: {
          'session_id': 'runtime-2',
          'env_var': 'REPLAYED_TOKEN',
          'prompt': 'Replayed token',
        },
      );
      await _waitFor(
        () => staleSecondEvents.any(
          (event) =>
              event.type == 'secret.request' &&
              event.data['request_id'].toString().endsWith(
                ':recovery-replayed',
              ),
        ),
      );
      final secondEvents = <StreamEvent>[];
      session.setAsyncEventListener(
        'mobile-2',
        (_, event) => secondEvents.add(event),
      );
      await _waitFor(
        () => secondEvents.any(
          (event) =>
              event.type == 'secret.request' &&
              event.data['request_id'].toString().endsWith(
                ':recovery-replayed',
              ),
        ),
      );
      session.removeAsyncEventListener('mobile-2', staleSecondRegistration);
      final replayedRequestId = secondEvents
          .lastWhere(
            (event) =>
                event.type == 'secret.request' &&
                event.data['request_id'].toString().endsWith(
                  ':recovery-replayed',
                ),
          )
          .data['request_id']
          .toString();
      expect(
        await session.tryRespondToSecret(
          requestId: replayedRequestId,
          value: 'replayed-value',
        ),
        isTrue,
      );
      await _waitFor(
        () => gateway.serverResponses.containsKey('recovery-replayed'),
      );
      final staleEventCount = staleSecondEvents.length;

      gateway.sendServerRequest(
        id: 'recovery-second-secret',
        method: 'secret',
        socketIndex: 1,
        params: {
          'session_id': 'runtime-2',
          'env_var': 'SECOND_TOKEN',
          'prompt': 'Second token',
        },
      );
      await _waitFor(
        () => secondEvents.any(
          (event) =>
              event.type == 'secret.request' &&
              event.data['request_id'].toString().endsWith(
                ':recovery-second-secret',
              ),
        ),
      );
      expect(staleSecondEvents, hasLength(staleEventCount));
      expect(
        await session.tryRespondToSecret(
          requestId: secondEvents
              .lastWhere(
                (event) =>
                    event.type == 'secret.request' &&
                    event.data['request_id'].toString().endsWith(
                      ':recovery-second-secret',
                    ),
              )
              .data['request_id']
              .toString(),
          value: 'second-value',
        ),
        isTrue,
      );
      await _waitFor(
        () => gateway.serverResponses.containsKey('recovery-second-secret'),
      );
      expect(gateway.serverResponseSocketIndexes['recovery-second-secret'], 1);

      for (var socketIndex = 0; socketIndex < 2; socketIndex++) {
        gateway.sendServerRequest(
          id: 'shared-request-id',
          method: 'secret',
          socketIndex: socketIndex,
          params: {
            'session_id': 'runtime-${socketIndex + 1}',
            'env_var': 'SHARED_TOKEN',
            'prompt': 'Shared token',
          },
        );
      }
      await _waitFor(
        () =>
            events.any(
              (event) =>
                  event.type == 'secret.request' &&
                  event.data['request_id'].toString().endsWith(
                    ':shared-request-id',
                  ),
            ) &&
            secondEvents.any(
              (event) =>
                  event.type == 'secret.request' &&
                  event.data['request_id'].toString().endsWith(
                    ':shared-request-id',
                  ),
            ),
      );
      final firstSharedRequestId = events
          .lastWhere(
            (event) =>
                event.type == 'secret.request' &&
                event.data['request_id'].toString().endsWith(
                  ':shared-request-id',
                ),
          )
          .data['request_id']
          .toString();
      final secondSharedRequestId = secondEvents
          .lastWhere(
            (event) =>
                event.type == 'secret.request' &&
                event.data['request_id'].toString().endsWith(
                  ':shared-request-id',
                ),
          )
          .data['request_id']
          .toString();
      expect(firstSharedRequestId, isNot(secondSharedRequestId));
      expect(
        await session.tryRespondToSecret(
          requestId: firstSharedRequestId,
          value: 'first-shared-value',
        ),
        isTrue,
      );
      expect(
        await session.tryRespondToSecret(
          requestId: secondSharedRequestId,
          value: 'second-shared-value',
        ),
        isTrue,
      );
      await _waitFor(
        () => gateway.serverResponseSocketKeys.containsAll({
          '0:shared-request-id',
          '1:shared-request-id',
        }),
      );

      final thirdOldEvents = <StreamEvent>[];
      final thirdOldRegistration = session.setAsyncEventListener(
        'mobile-3',
        (_, event) => thirdOldEvents.add(event),
      );
      await session.submit(localSessionId: 'mobile-3', text: 'Third session');
      expect(gateway.socketCount, 3);
      gateway.sendServerRequest(
        id: 'partial-clarify',
        method: 'clarify',
        socketIndex: 2,
        params: {
          'session_id': 'runtime-3',
          'questions': [
            {'qid': 'q1', 'question': 'First?'},
            {'qid': 'q2', 'question': 'Second?'},
          ],
        },
      );
      await _waitFor(
        () => thirdOldEvents.any((event) => event.type == 'clarify.request'),
      );
      final partialRequestId = thirdOldEvents
          .lastWhere((event) => event.type == 'clarify.request')
          .data['request_id']
          .toString();
      expect(
        await session.tryRespondToClarify(
          requestId: partialRequestId,
          questionId: 'q1',
          answer: 'First answer',
        ),
        isTrue,
      );
      await _waitFor(
        () => thirdOldEvents.any(
          (event) =>
              event.type == 'clarify.remaining' &&
              (event.data['remaining'] as List).contains('q2'),
        ),
      );
      final thirdReplacementEvents = <StreamEvent>[];
      final thirdReplacementRegistration = session.setAsyncEventListener(
        'mobile-3',
        (_, event) => thirdReplacementEvents.add(event),
      );
      session.removeAsyncEventListener('mobile-3', thirdOldRegistration);
      await _waitFor(
        () => thirdReplacementEvents.any(
          (event) => event.type == 'clarify.request',
        ),
      );
      final replayedPartial = thirdReplacementEvents.lastWhere(
        (event) => event.type == 'clarify.request',
      );
      expect(replayedPartial.data['questions'], [
        {'qid': 'q2', 'question': 'Second?'},
      ]);
      expect(
        await session.tryRespondToClarify(
          requestId: replayedPartial.data['request_id'].toString(),
          questionId: 'q2',
          answer: 'Second answer',
        ),
        isTrue,
      );
      session.removeAsyncEventListener(
        'mobile-3',
        thirdReplacementRegistration,
      );

      gateway.sendServerRequest(
        id: 'recovery-pending-detach',
        method: 'secret',
        params: {
          'session_id': 'runtime-1',
          'env_var': 'PENDING_TOKEN',
          'prompt': 'Pending token',
        },
      );
      await _waitFor(
        () => events.any(
          (event) =>
              event.type == 'secret.request' &&
              event.data['request_id'].toString().endsWith(
                ':recovery-pending-detach',
              ),
        ),
      );
      session.removeAsyncEventListener('mobile-1', registration);
      await _waitFor(
        () => gateway.serverResponses.containsKey('recovery-pending-detach'),
      );
      expect(
        gateway.serverResponses['recovery-pending-detach']?['error'],
        containsPair('code', -32601),
      );
      gateway.sendServerRequest(
        id: 'recovery-detached',
        method: 'secret',
        params: {
          'session_id': 'runtime-1',
          'env_var': 'DETACHED_TOKEN',
          'prompt': 'Detached token',
        },
      );
      await _waitFor(
        () => gateway.serverResponses.containsKey('recovery-detached'),
      );
      expect(
        gateway.serverResponses['recovery-detached']?['error'],
        containsPair('code', -32601),
      );

      gateway.sendServerRequest(
        id: 'recovery-disconnected',
        method: 'approval',
        socketIndex: 1,
        params: {
          'session_id': 'runtime-2',
          'request_id': 'approval-disconnected',
          'command': 'echo disconnected',
          'choices': ['once', 'deny'],
        },
      );
      await _waitFor(
        () => secondEvents.any(
          (event) =>
              event.type == 'approval.request' &&
              event.data['server_request_id'].toString().endsWith(
                ':recovery-disconnected',
              ),
        ),
      );
      final disconnectedRequestId = secondEvents
          .lastWhere(
            (event) =>
                event.type == 'approval.request' &&
                event.data['server_request_id'].toString().endsWith(
                  ':recovery-disconnected',
                ),
          )
          .data['server_request_id']
          .toString();
      await gateway.closeSocket(1);
      await _waitFor(
        () => secondEvents.any(
          (event) =>
              event.type == 'request.cancel' &&
              event.data['id'] == disconnectedRequestId,
        ),
      );
      expect(
        await session.tryRespondToApproval(
          sessionId: 'mobile-2',
          choice: 'once',
        ),
        isFalse,
      );
      expect(gateway.serverResponses, isNot(contains('recovery-disconnected')));
    },
  );

  test(
    'Desktop bridge re-delivers open requests after session resume',
    () async {
      final gateway = await _ServerRequestGateway.start(
        withDashboardAuth: true,
        openRequestsOnResume: [
          {
            'id': 'srq-resumed-secret',
            'method': 'secret',
            'params': {
              'session_id': 'runtime-1',
              'env_var': 'TOKEN',
              'prompt': 'Enter token',
            },
          },
        ],
      );
      addTearDown(gateway.stop);
      final client = DesktopGatewayClient.fromConnection(
        SavedConnection(
          id: 'server-request-replay-test',
          label: 'Local fixture',
          host: 'localhost',
          port: gateway.port,
          apiKey: 'fixture-key',
          useHttps: false,
          desktopGatewayUrl: 'http://127.0.0.1:${gateway.port}',
          dashboardUsername: 'user',
          dashboardPassword: 'pass',
        ),
      );
      addTearDown(client.close);
      final events = <StreamEvent>[];
      client.setAsyncEventListener((_, event) => events.add(event));

      await client.ensureSession('stored-1');
      await _waitFor(
        () => events.any((event) => event.type == 'secret.request'),
      );
      final resumedRequestId = events
          .lastWhere((event) => event.type == 'secret.request')
          .data['request_id']
          .toString();
      await client.respondToSecret(requestId: resumedRequestId, value: 'value');
      await _waitFor(
        () => gateway.serverResponses.containsKey('srq-resumed-secret'),
      );
      expect(gateway.serverResponses['srq-resumed-secret']?['result'], {
        'value': 'value',
      });
    },
  );

  test(
    'Desktop bridge does not replay already locked clarify answers',
    () async {
      final gateway = await _ServerRequestGateway.start(
        withDashboardAuth: true,
        openRequestsOnResume: [
          {
            'id': 'srq-resumed-clarify',
            'method': 'clarify',
            'params': {
              'session_id': 'runtime-1',
              'questions': [
                {'qid': 'q1', 'question': 'Already answered?'},
                {'qid': 'q2', 'question': 'Still pending?'},
              ],
              'answers': {'q1': 'Yes'},
            },
          },
        ],
      );
      addTearDown(gateway.stop);
      final client = DesktopGatewayClient.fromConnection(
        SavedConnection(
          id: 'server-request-clarify-replay-test',
          label: 'Local fixture',
          host: 'localhost',
          port: gateway.port,
          apiKey: 'fixture-key',
          useHttps: false,
          desktopGatewayUrl: 'http://127.0.0.1:${gateway.port}',
          dashboardUsername: 'user',
          dashboardPassword: 'pass',
        ),
      );
      addTearDown(client.close);
      final events = <StreamEvent>[];
      client.setAsyncEventListener((_, event) => events.add(event));

      await client.ensureSession('stored-1');
      await _waitFor(
        () => events.any((event) => event.type == 'clarify.request'),
      );
      final event = events.lastWhere(
        (candidate) => candidate.type == 'clarify.request',
      );
      expect(event.data['questions'], [
        {'qid': 'q2', 'question': 'Still pending?'},
      ]);

      await client.respondToClarify(
        requestId: event.data['request_id'].toString(),
        questionId: 'q2',
        answer: 'No',
      );
      await _waitFor(() => gateway.clarifyLocks.isNotEmpty);
      expect(gateway.clarifyLocks.single, {
        'request_id': 'srq-resumed-clarify',
        'question_id': 'q2',
        'answer': 'No',
      });
    },
  );
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _ServerRequestGateway {
  _ServerRequestGateway(
    this._server,
    this.withDashboardAuth,
    this.withTurnRecovery,
    this.openRequestsOnResume,
  );

  final HttpServer _server;
  final bool withDashboardAuth;
  final bool withTurnRecovery;
  final List<Map<String, dynamic>>? openRequestsOnResume;
  final List<WebSocket> _sockets = [];
  final List<({int socketIndex, Map<String, dynamic> frame})> clientFrames = [];
  final List<Map<String, dynamic>> capabilityFrames = [];
  final Map<String, Map<String, dynamic>> serverResponses = {};
  final Map<String, int> serverResponseSocketIndexes = {};
  final Set<String> serverResponseSocketKeys = {};
  final List<Map<String, dynamic>> clarifyLocks = [];
  final List<int> clarifyLockSocketIndexes = [];
  final List<Map<String, dynamic>> fileAttachments = [];
  final List<int> fileAttachSocketIndexes = [];
  Map<String, dynamic> fileAttachResult = {};
  bool holdFileAttachResponses = false;
  final List<({WebSocket socket, Object? id, Map<String, dynamic> result})>
  _heldFileAttachResponses = [];
  bool reuseSessionIdentity = false;
  void Function(int, Map<String, dynamic>)? onServerResponse;

  int get port => _server.port;
  int get socketCount => _sockets.length;
  int get heldFileAttachResponseCount => _heldFileAttachResponses.length;

  static Future<_ServerRequestGateway> start({
    bool withDashboardAuth = false,
    bool withTurnRecovery = false,
    bool reuseSessionIdentity = false,
    List<Map<String, dynamic>>? openRequestsOnResume,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _ServerRequestGateway(
      server,
      withDashboardAuth,
      withTurnRecovery,
      openRequestsOnResume,
    );
    gateway.reuseSessionIdentity = reuseSessionIdentity;
    server.listen(gateway._handleHttp);
    return gateway;
  }

  Future<void> _handleHttp(HttpRequest request) async {
    if (withDashboardAuth &&
        request.method == 'POST' &&
        request.uri.path == '/auth/password-login') {
      request.response
        ..statusCode = 200
        ..headers.set('set-cookie', 'hermes_session_at=fixture; Path=/')
        ..write('{"ok":true}');
      await request.response.close();
      return;
    }
    if (withDashboardAuth &&
        request.method == 'POST' &&
        request.uri.path == '/api/auth/ws-ticket') {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write('{"ticket":"fixture-ticket"}');
      await request.response.close();
      return;
    }
    if (request.uri.path != '/api/ws') {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }

    final socket = await WebSocketTransformer.upgrade(request);
    _sockets.add(socket);
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {
          'type': 'gateway.ready',
          'payload': {
            if (withTurnRecovery) ...{
              'protocol': {'name': 'hermes-jsonrpc', 'major': 2},
              'capabilities': {'turn_recovery': _turnRecoveryCapability()},
            },
          },
        },
      }),
    );
    socket.listen((raw) => _handleSocketFrame(socket, raw));
  }

  void _handleSocketFrame(WebSocket socket, dynamic raw) {
    final frame = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
    final socketIndex = _sockets.indexOf(socket);
    clientFrames.add((socketIndex: socketIndex, frame: frame));
    final method = frame['method'];
    final id = frame['id'];
    if (method == null && id is String) {
      serverResponses[id] = frame;
      serverResponseSocketIndexes[id] = socketIndex;
      serverResponseSocketKeys.add('$socketIndex:$id');
      onServerResponse?.call(socketIndex, frame);
      return;
    }
    if (method == 'client.capabilities') {
      capabilityFrames.add(frame);
      _respond(socket, id, {
        'server_requests': ['clarify', 'approval', 'sudo', 'secret'],
      });
      return;
    }
    if (method == 'session.resume') {
      if (openRequestsOnResume != null) {
        _respond(socket, id, {
          'session_id': 'runtime-1',
          'open_requests': openRequestsOnResume,
        });
        return;
      }
      _error(socket, id, 4007, 'session not found');
      return;
    }
    if (method == 'session.create') {
      _respond(socket, id, {
        'session_id': 'runtime-1',
        'stored_session_id': 'stored-1',
      });
      return;
    }
    if (method == 'session.open') {
      final params = Map<String, dynamic>.from(frame['params'] as Map);
      _respond(socket, id, {
        'runtime_session_id':
            'runtime-${reuseSessionIdentity ? 1 : socketIndex + 1}',
        'stored_session_id':
            'stored-${reuseSessionIdentity ? 1 : socketIndex + 1}',
        'mobile_session_id': params['mobile_session_id'],
        'binding_version': 1,
        'turn_recovery': true,
        'automatic_resubmit': false,
        'capabilities': {'turn_recovery': _turnRecoveryCapability()},
      });
      return;
    }
    if (method == 'prompt.submit') {
      final params = Map<String, dynamic>.from(frame['params'] as Map);
      _respond(socket, id, {
        'accepted': true,
        'automatic_resubmit': false,
        'client_turn_id': params['client_turn_id'],
        'turn_id': 'turn-${socketIndex + 1}',
        'status': 'accepted',
        'last_seq': 0,
        'created': true,
      });
      return;
    }
    if (method == 'file.attach') {
      fileAttachments.add(Map<String, dynamic>.from(frame['params'] as Map));
      fileAttachSocketIndexes.add(socketIndex);
      final result = Map<String, dynamic>.from(fileAttachResult);
      if (holdFileAttachResponses) {
        _heldFileAttachResponses.add((socket: socket, id: id, result: result));
      } else {
        _respond(socket, id, result);
      }
      return;
    }
    if (method == 'clarify.lock') {
      final params = Map<String, dynamic>.from(frame['params'] as Map);
      clarifyLocks.add(params);
      clarifyLockSocketIndexes.add(socketIndex);
      final isPartialFixture = params['request_id'] == 'partial-clarify';
      final remaining = isPartialFixture && params['question_id'] == 'q1'
          ? <String>['q2']
          : <String>[];
      _respond(socket, id, {'status': 'ok', 'remaining': remaining});
      return;
    }
    if (method == 'gateway.ping') {
      _respond(socket, id, {'ok': true});
      return;
    }
    _error(socket, id, -32601, 'unknown method');
  }

  void sendServerRequest({
    required String id,
    required String method,
    required Map<String, dynamic> params,
    int socketIndex = 0,
  }) {
    final socket = _sockets[socketIndex];
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
  }

  void sendEvent({
    required String type,
    required String sessionId,
    required Map<String, dynamic> payload,
    int socketIndex = 0,
  }) {
    _sockets[socketIndex].add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': type, 'session_id': sessionId, 'payload': payload},
      }),
    );
  }

  void releaseFileAttachResponses() {
    final held = _heldFileAttachResponses.toList();
    _heldFileAttachResponses.clear();
    for (final response in held) {
      if (response.socket.readyState == WebSocket.open) {
        _respond(response.socket, response.id, response.result);
      }
    }
  }

  Future<void> closeSocket(int socketIndex) =>
      _sockets[socketIndex].close(WebSocketStatus.goingAway, 'fixture close');

  void _respond(WebSocket socket, dynamic id, Map<String, dynamic> result) {
    socket.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
  }

  void _error(WebSocket socket, dynamic id, int code, String message) {
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      }),
    );
  }

  Future<void> stop() async {
    _heldFileAttachResponses.clear();
    for (final socket in _sockets) {
      await socket.close();
    }
    _sockets.clear();
    await _server.close(force: true);
  }
}

Map<String, dynamic> _turnRecoveryCapability() => {
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

class _MemoryJournalStore implements GatewayTurnJournalStore {
  String? value;

  @override
  Future<void> delete() async => value = null;

  @override
  Future<void> deleteLegacy() async {}

  @override
  Future<String?> read() async => value;

  @override
  Future<String?> readLegacy() async => null;

  @override
  Future<void> write(String next) async => value = next;
}
