import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/attachment_draft.dart';
import '../models/gateway_clarify.dart';
import '../services/attachment_draft_service.dart';
import '../services/image_picker_recovery_guard.dart';

import 'package:hermes_android/core/l10n/l10n.dart';

typedef ClarifyResponder = Future<void> Function(String answer);

/// Whether the card may still close the route it was opened in.
///
/// A gateway `request.cancel` closes the card itself while an answer is in
/// flight, and the screen that opened the card may have opened the next
/// question's card by the time [ClarifyResponder] completes. Popping then
/// closes whatever route is on top instead — the chat screen, or the next
/// question — so the card asks before it pops.
typedef ClarifyRouteOwner = bool Function();

class GatewayClarifyDialog extends StatefulWidget {
  final GatewayClarifyRequest request;
  final ClarifyResponder onRespond;

  /// Uploads into the session that owns this question, never a new turn.
  /// Omit for consumers without the Desktop Gateway attachment transport.
  final AttachmentUploadCallback? onUploadImage;
  final AttachmentDraftService? attachmentDraftService;
  final String? imagePickerOwner;

  /// Defaults to owning the route: a card mounted as a route of its own
  /// (tests, a single-question prompt) closes itself.
  final ClarifyRouteOwner? canCloseRoute;

  const GatewayClarifyDialog({
    required this.request,
    required this.onRespond,
    this.onUploadImage,
    this.attachmentDraftService,
    this.imagePickerOwner,
    this.canCloseRoute,
    super.key,
  });

  @override
  State<GatewayClarifyDialog> createState() => _GatewayClarifyDialogState();
}

class _GatewayClarifyDialogState extends State<GatewayClarifyDialog> {
  final TextEditingController _otherController = TextEditingController();
  final Set<int> _selectedIndices = {};
  final List<AttachmentDraft> _images = [];
  final ImagePicker _imagePicker = ImagePicker();
  late final AttachmentDraftService _draftService =
      widget.attachmentDraftService ?? AttachmentDraftService();
  Future<void> _pendingWork = Future.value();
  int? _selectedIndex;
  bool _preparing = false;
  bool _submitting = false;
  String? _error;

  bool get _busy => _preparing || _submitting;
  bool get _ownsRequest => mounted && (widget.canCloseRoute?.call() ?? true);

  @override
  void dispose() {
    _otherController.dispose();
    // Let an accepted file read/upload finish before deleting its cache. A
    // picker returning after cancellation cleans its newly prepared file too.
    unawaited(_cleanUpImages());
    super.dispose();
  }

  Future<void> _cleanUpImages() async {
    try {
      await _pendingWork;
    } finally {
      await _draftService.removeAll(_images);
    }
  }

  void _pickImages({bool camera = false}) {
    if (_busy || !_ownsRequest) return;
    setState(() {
      _preparing = true;
      _error = null;
    });
    _pendingWork = _prepareImages(camera: camera);
  }

  Future<void> _prepareImages({required bool camera}) async {
    try {
      final images = await ImagePickerRecoveryGuard.pickForClarification(
        owner: widget.imagePickerOwner ?? widget.request.identityKey,
        pick: () async {
          if (!_ownsRequest) return <XFile>[];
          if (camera) {
            final image = await _imagePicker.pickImage(
              source: ImageSource.camera,
              imageQuality: 75,
              maxWidth: 1600,
              maxHeight: 1600,
            );
            return image == null ? <XFile>[] : [image];
          }
          return _imagePicker.pickMultiImage(
            imageQuality: 75,
            maxWidth: 1600,
            maxHeight: 1600,
          );
        },
      );
      for (final image in images) {
        if (!_ownsRequest) return;
        final draft = await _draftService.prepareImage(
          sourcePath: image.path,
          displayName: image.name,
          existingDrafts: _images,
          mode: AttachmentDraftMode.remoteGateway,
        );
        if (!_ownsRequest) {
          await _draftService.removeCachedFile(draft);
          return;
        }
        setState(() => _images.add(draft));
      }
    } catch (_) {
      if (_ownsRequest) {
        setState(() {
          _error = context.l10n.unable_to_prepare_this_image_try_another_one;
        });
      }
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  void _removeImage(AttachmentDraft draft) {
    if (_busy || !_ownsRequest) return;
    setState(() {
      _images.remove(draft);
      _error = null;
    });
    unawaited(_draftService.removeCachedFile(draft));
  }

  String get _answer {
    final custom = _otherController.text.trim();
    if (!widget.request.multiSelect) {
      if (custom.isNotEmpty) return custom;
      final selectedIndex = _selectedIndex;
      return selectedIndex == null ? '' : widget.request.choices[selectedIndex];
    }

    final ordered = _selectedIndices.toList()..sort();
    final parts = [
      for (final index in ordered) widget.request.choices[index],
      if (custom.isNotEmpty) custom,
    ];
    return parts.join(', ');
  }

  void _selectChoice(int index) {
    if (_busy) return;
    setState(() {
      _error = null;
      if (widget.request.multiSelect) {
        if (!_selectedIndices.add(index)) {
          _selectedIndices.remove(index);
        }
      } else {
        _selectedIndex = index;
        _otherController.clear();
      }
    });
  }

  void _respond(String answer, {bool skip = false}) {
    if (_busy || !_ownsRequest) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    _pendingWork = _sendAnswer(answer, skip: skip);
  }

  Future<void> _sendAnswer(String answer, {required bool skip}) async {
    try {
      if (!skip && _images.isNotEmpty) {
        await AttachmentDraftSendCoordinator(_draftService).uploadThenSubmit(
          drafts: _images,
          upload: ({required draft, required dataUrl}) {
            if (!_ownsRequest) throw StateError('Question is no longer open');
            return widget.onUploadImage!(draft: draft, dataUrl: dataUrl);
          },
          onChanged: (_) {
            if (_ownsRequest) setState(() {});
          },
          submitPrompt: (refs) async {
            if (!_ownsRequest) return;
            await widget.onRespond(
              [if (answer.isNotEmpty) answer, ...refs].join('\n\n'),
            );
          },
        );
      } else if (_ownsRequest) {
        await widget.onRespond(answer);
      }
      // The answer may have been sent while the gateway cancelled the request:
      // the cancellation closes this card's route, and the screen may already
      // have opened the next question's card. Popping then would close a route
      // this card no longer owns.
      if (mounted && (widget.canCloseRoute?.call() ?? true)) {
        final route = ModalRoute.of<bool>(context)!;
        final navigator = Navigator.of(context);
        if (route.isCurrent) {
          navigator.pop(true);
        } else {
          // An approval can open above clarify while clarify.lock is pending.
          // A normal pop would close that approval, not this answered card.
          navigator.removeRoute(route, true);
        }
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error =
            context.l10n.hermes_could_not_accept_the_answer_please_try_again;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final request = widget.request;
    final answer = _answer;

    return PopScope(
      // Back/barrier dismissal means Skip. Do not race that empty answer
      // against an accepted upload/answer; server cancellation still removes
      // this exact route through the owning screen.
      canPop: !_submitting,
      child: AlertDialog(
        icon: const Icon(Icons.help_outline_rounded),
        title: Text(context.l10n.hermes_needs_your_input),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectableText(
                  request.question,
                  key: const Key('clarify-question'),
                  style: theme.textTheme.titleMedium,
                ),
                if (request.hasChoices) ...[
                  const SizedBox(height: 12),
                  Text(
                    request.multiSelect
                        ? context.l10n.select_one_or_more_options_then_continue
                        : context
                              .l10n
                              .select_one_option_or_enter_another_answer,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 6),
                  for (var index = 0; index < request.choices.length; index++)
                    Semantics(
                      selected: request.multiSelect
                          ? _selectedIndices.contains(index)
                          : _selectedIndex == index,
                      button: true,
                      child: ListTile(
                        key: Key('clarify-choice-$index'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          request.multiSelect
                              ? (_selectedIndices.contains(index)
                                    ? Icons.check_box_rounded
                                    : Icons.check_box_outline_blank_rounded)
                              : (_selectedIndex == index
                                    ? Icons.radio_button_checked_rounded
                                    : Icons.radio_button_off_rounded),
                        ),
                        title: Text(request.choices[index]),
                        enabled: !_busy,
                        onTap: () => _selectChoice(index),
                      ),
                    ),
                ],
                SizedBox(height: request.hasChoices ? 8 : 16),
                TextField(
                  key: const Key('clarify-other-field'),
                  controller: _otherController,
                  autofocus: !request.hasChoices,
                  enabled: !_busy,
                  minLines: 1,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    labelText: request.hasChoices
                        ? context.l10n.other_answer
                        : context.l10n.your_answer,
                  ),
                  onChanged: (value) {
                    setState(() {
                      _error = null;
                      if (!request.multiSelect && value.trim().isNotEmpty) {
                        _selectedIndex = null;
                      }
                    });
                  },
                  onSubmitted: (_) {
                    final currentAnswer = _answer;
                    if (currentAnswer.isNotEmpty || _images.isNotEmpty) {
                      _respond(currentAnswer);
                    }
                  },
                ),
                if (widget.onUploadImage != null) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        key: const Key('clarify-choose-images'),
                        onPressed:
                            _busy || _images.length >= maxRemoteAttachmentDrafts
                            ? null
                            : _pickImages,
                        icon: const Icon(Icons.photo_library_outlined),
                        label: Text(context.l10n.choose_images),
                      ),
                      TextButton.icon(
                        key: const Key('clarify-take-photo'),
                        onPressed:
                            _busy || _images.length >= maxRemoteAttachmentDrafts
                            ? null
                            : () => _pickImages(camera: true),
                        icon: const Icon(Icons.camera_alt_outlined),
                        label: Text(context.l10n.take_photo),
                      ),
                    ],
                  ),
                  if (_preparing) const LinearProgressIndicator(),
                  for (final image in _images)
                    Row(
                      key: ValueKey('clarify-image-${image.id}'),
                      children: [
                        if (image.status == AttachmentDraftStatus.ready ||
                            image.status == AttachmentDraftStatus.failed)
                          Image.file(
                            File(image.cachedPath),
                            width: 40,
                            height: 40,
                            cacheWidth: 112,
                            cacheHeight: 112,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const Icon(Icons.image_outlined),
                          )
                        else if (image.status ==
                            AttachmentDraftStatus.uploading)
                          const SizedBox.square(
                            dimension: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          const Icon(Icons.check_circle_outline),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            image.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          key: ValueKey('clarify-remove-${image.id}'),
                          tooltip: context.l10n.remove_attachment,
                          onPressed: _busy ? null : () => _removeImage(image),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    key: const Key('clarify-error'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const Key('clarify-skip'),
            onPressed: _busy ? null : () => _respond('', skip: true),
            child: Text(context.l10n.skip),
          ),
          FilledButton(
            key: const Key('clarify-continue'),
            onPressed: _busy || (answer.isEmpty && _images.isEmpty)
                ? null
                : () => _respond(_answer),
            child: _submitting
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(context.l10n.continue_label),
          ),
        ],
      ),
    );
  }
}
