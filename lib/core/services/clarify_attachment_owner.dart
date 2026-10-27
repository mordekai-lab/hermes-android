import 'dart:convert';

import 'ws_client.dart';

/// Optional capability of the owner of an outstanding server clarification.
/// Uploads must use that request's existing socket/session, without reconnect,
/// session creation, prompt submission or image-queue mutation.
abstract interface class ClarifyAttachmentOwner {
  bool canAttachToClarify({
    required String requestId,
    required String questionId,
  });

  Future<RemoteFileAttachment> attachToClarify({
    required String requestId,
    required String questionId,
    required String name,
    required String dataUrl,
  });
}

/// Clarify answers are tool-result text, not prompts: @file references are not
/// expanded there. Preserve the gateway reference verbatim and provide its
/// actual absolute path so the agent can open the image with the vision tool.
String clarifyImageReference(RemoteFileAttachment attachment) {
  if (attachment.path.trim().isEmpty) {
    throw StateError('The gateway returned no image path');
  }
  return '${attachment.refText}\n'
      'Attached image path: ${jsonEncode(attachment.path)}\n'
      'Use vision_analyze with image_url set to this path to inspect the image.';
}
