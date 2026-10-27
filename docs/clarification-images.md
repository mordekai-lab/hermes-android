# Answering agent questions with images

This feature is unreleased. It adds image controls to **Hermes needs your input**
question popups, not to password or command-approval dialogs.

1. Tap **Choose images** to select screenshots/photos, or **Take photo** to use
   the camera.
2. Check the thumbnails and filenames. Use the remove button to discard an image.
3. Optionally type an answer or select the requested choices. An image-only answer
   is allowed.
4. Tap **Continue** to upload the selected images and answer this question.

Selection alone does not upload anything. The normal chat composer and its draft
remain separate. Each question in a batch has its own selected images. **Skip**
discards those images and sends the normal empty answer. Back/dismiss also follows
existing Skip behaviour before submission; while uploading or answering, wait for
completion or an error before dismissing.

## Limits and privacy

The existing image preparation policy applies: JPEG, PNG and WebP sources,
orientation correction and metadata removal, up to ten images and 64 MiB total
of prepared image data per answer. The picker requests images bounded to
1600 × 1600 pixels. No new service or third-party upload destination is added.
Images are uploaded only to the configured Hermes gateway. Local prepared files
are removed after confirmed upload or when the popup is discarded.

If an upload or answer fails, the popup keeps its text and attachment state.
Tap **Continue** again to retry; confirmed uploads are reused. You can remove a
failed image or all images and answer with text instead. A question cancelled by
Hermes cannot send a late answer or close a newer popup. An upload already
accepted by the server can leave a server-side file when its question expires;
closing the popup does not delete that server file.

Before launching the Android picker, the app records that it belongs to this
question. If Android kills the app while the picker is open, its recovered
result is discarded rather than attached to a later chat prompt. Reopen the
still-pending question and select the image again. Ordinary composer-picker
recovery is unchanged. No original photo is deleted during this discard.

## Compatibility

Image controls require a tracked Remote Gateway server question with a question
ID and its connected originating session. Normal and experimental recovery-v2
question owners are supported. Legacy untracked/flat questions and consumers
without that upload capability remain text-only. The upload uses existing
`file.attach`, followed by the existing `clarify.lock` answer, on the original
socket and runtime; it never reconnects, creates a session, submits a new prompt
or queues an image for the next prompt.

Clarification answers are tool-result text, not native multimodal user messages.
The answer includes the gateway's exact file reference, its returned absolute
image path and a hint to inspect it with `vision_analyze`. This avoids assuming
that `@file:` references are expanded inside a clarification answer. The agent
needs an enabled vision tool and access to the uploaded path. A sandbox/SSH
backend may not be able to read a gateway-host path; this change does not add
sandbox file transfer or guarantee vision-model access. Existing server upload
permissions, drain/restart restrictions and vision limits still apply.

Hermes Agent assisted with implementation, documentation and regression tests.
