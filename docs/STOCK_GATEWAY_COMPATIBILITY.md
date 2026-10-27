# Stock gateway compatibility and experimental recovery (#84)

## Decision

A working stock JSON-RPC connection is a supported transport, not a failed
recovery-v2 connection. Use its normal `session.resume` / `session.create` /
`prompt.submit` path. Missing Android recovery-v2 advertisement is **not** a
reason to replace that path with REST or show a permanent failure banner.
The official integration guide identifies the TUI gateway JSON-RPC transport
as the custom-client interface for sessions, prompts, approvals and streaming.[1]

Keep experimental recovery-v2 separate. A fresh, non-Project local draft may
attempt it only after the full `GatewayTurnRecoveryCapability` contract passes.
Stored chats and Project drafts keep the normal transport. Neither a successful
`client.capabilities` response nor a generic method-support verdict grants
recovery authority.

## Current upstream evidence

Checked against public NousResearch/hermes-agent main
`69f73ec5f11f5a945cc864f29c4e2ad2307eaec3`, independently resolved from the remote
branch on 2026-10-27. Installed source was inspected read-only, was at a different
revision with local changes, and was not substituted for this upstream snapshot.

- The classic WebSocket greeting carries `skin`, `change_events`, `heartbeat`
  and `replay_epoch`. The stdio greeting carries the corresponding non-WebSocket
  fields. Neither emitter advertises the Android `protocol` / `turn_recovery`
  v2 contract.[2][3]
- `client.capabilities` declares the client's server-request support; its result
  lists server-request methods and `declines_not_shown`. The separate
  `gateway.capabilities` result advertises `per_session_exclusive_submit`, not
  the Android recovery-v2 contract.[4]
- Classic `session.resume` takes a **stored** session ID and supports
  `omit_messages`. Its response can carry `running`, `status`, `inflight` and
  `open_requests`. Classic creation returns distinct runtime/stored identities
  and can defer creation of the database row until the first prompt.[5][6]
- Classic `session.events.since` uses `last_seen` and returns replay frames,
  `latest_seq`, `truncated`, `epoch` and `open_requests`. Replay is bounded and
  process-epoch scoped; truncation requires refetching state rather than
  treating the retained tail as complete.[5][6][7]
- `message.complete.persisted_turn` supplies committed row addresses, with
  explicit completeness and optional user/final-assistant IDs. This is useful
  saved/received-output correlation, not permission to retry an uncertain
  submission or an advertisement of Android recovery-v2.[8][9]
- Classic `PromptSubmitParams` has no Android `client_turn_id` / `binding_version`
  / v2 submission envelope. Successful ordinary submit must not be promoted to
  an exactly-once client-retry guarantee.[10]

### Important newer upstream contract, not an alias

Current main can additionally advertise `session_authority: true` when the
WebSocket is attached to a canonical session authority. That selects different
session handlers; its typed contract includes authority/execution generations,
pending admissions/prompts and a `submission_id`. It is **not** the Android
`turn_recovery` v2 protocol.[2][11]

This compatibility slice validates the **classic/standalone session contract**
used by the stock-server reports in #84, not canonical-authority protocol parity.
A canonical-authority adapter needs separate schema, receipt, replay and approval
acceptance tests. Do not claim all current-main deployment modes are verified or
infer v2 support from the new boolean. The upstream negotiation discussion
remains a separate dependency.[12]

## Client implementation

1. Recovery admission reads the immutable `gateway.ready` from the app-owned
   normal/control socket via `DesktopGatewayClient.readGatewayReadyFrame`.
   Concurrent normal/control work uses that client's existing socket single
   flight. A stock connection no longer opens/closes a disposable recovery
   probe or discards its pending `client.capabilities` reply.
2. Both this preflight and any subsequent dedicated recovery socket use the
   **same existing fail-closed validator**. The real recovery socket is checked
   again: a capable control greeting is permission to attempt recovery, not
   authority for another socket or `session.open` result.
3. Clean absence permits normal transport only after the existing durable
   binding/journal check proves no unresolved recovery authority. Pending,
   acknowledgement-uncertain or failed journal entries still block downgrade.
   Malformed/unsafe advertisements and transport/authentication failures do not
   become stock fallback.
4. Initial recovery is single-flight across chat initialization and an early
   explicit Send. A held visible-history read cannot force the first prompt
   through an unnegotiated route, erase restored output, or later renegotiate
   over the admitted prompt. This does not make sending wait for that HTTP read.
5. Normal/control notifications cannot overwrite the selected experimental
   transport's active state or fail-closed send gate. Existing normal-chat
   owners still own ordinary reconnect/history reconciliation and request
   responses.
6. Clean stock absence no longer produces a permanent banner, even in Verbose
   Mode. Genuine experimental mismatch/uncertainty remains visible and blocked
   as appropriate. No new visible strings or localization keys are introduced.

### Socket and cache policy

For a stock connection, negotiation, server-request advertisement, Project
control calls and ordinary chat traffic share the normal socket. Replacing a
lost socket requires one new ticket/socket, not another disposable probe.

A genuinely capable server still has the existing per-draft recovery socket
in addition to the normal/control socket. It is intentionally not stolen or
shared across different owners: coordinator closure/rebinding must not close
another normal chat or abandon its approvals/clarifications.

There is no host/build/install negative cache. Every fresh recovery attempt
reads the current normal socket's greeting, and every newly opened recovery
socket is validated independently. A new draft can discover a server upgrade
on reconnect. A draft already using the normal transport is not silently
migrated mid-turn.

## Finite acceptance and regression coverage

`test/stock_gateway_compatibility_test.dart` exercises real loopback HTTP and
WebSocket I/O through the production application controller and ChatScreen,
with stock shapes derived from the pinned source. The capable fixture is
explicitly synthetic, not evidence that upstream implements Android v2.

| Criterion | Acceptance |
| --- | --- |
| Stock stored chat | Normal JSON-RPC, one ticket/socket, no create/fork, no v2 methods or permanent banner. |
| Stock fresh draft | One shared socket, one stock create and submit, retained stored identity; no invented v2 journal authority. |
| Held initial history | Explicit first Send negotiates and submits once before the held GET returns; later initialization cannot reset it or clear the newer draft. |
| Socket loss | Resume the stored identity, bounded latest history, exactly one original submit; explicit complete and idle/unknown outcomes stay distinct. |
| Interactive requests | Resumed approval and clarify ownership remains on the normal socket and replies use the exact owning socket/request. |
| Capable greeting | Both greetings pass before experimental `session.open` / versioned submit; existing stored/Project exclusions remain. |
| Control disconnect | Neither a running experimental draft nor an unsafe-advertisement gate is cleared by normal/control state notifications. |
| Upgrade/downgrade | New greeting can enable a later draft; a capability downgrade with unresolved journal entries leaves the journal unchanged and cannot create/resubmit a normal turn. |
| Unsafe advertisement | Reject before opening a recovery socket or writing v2 state; do not relabel it as clean stock absence. |

Related regressions retain server-request routing across separate recovery
sockets, route remount, bounded large-session attach/history, stale-socket
terminal fencing, reconnect resync and fail-closed coordinator/journal behavior.
The pre-change tree reproduces both the extra draft ticket mint and the
permanent stock banner under the same regressions.

## Guarantees not added

Normal reconnect is **reconciliation, never automatic prompt resubmission**.
A socket acknowledgement, replay epoch, `running: false`, idle state, message
count or old transcript prose is not proof that a particular uncertain prompt
completed successfully. Unknown outcomes remain unknown. The existing
`persisted_turn` correlation rules are not weakened.

This change does not add a durable replay ring, exactly-once stock submission,
backend configuration, a canonical-authority adapter or recovery-v2 support to
upstream. It does not guarantee recovery of every missed tool/reasoning event;
normal recovery uses authoritative resume state, replayed open requests and
bounded saved history rather than assuming complete event replay.

Recovery Stop findings (#207 H1/M3), broader Desktop lifecycle findings
(L1/L4/L9), Android background/device verification and independent SPEC/QUALITY
review remain separate integration gates. No release, merge, push or gateway
installation/configuration change is part of this slice.

## Sources

[1] https://hermes-agent.nousresearch.com/docs/developer-guide/programmatic-integration — Official programmatic integration guide
[2] https://raw.githubusercontent.com/NousResearch/hermes-agent/69f73ec5f11f5a945cc864f29c4e2ad2307eaec3/tui_gateway/ws.py — tui_gateway/ws.py
[3] https://raw.githubusercontent.com/NousResearch/hermes-agent/69f73ec5f11f5a945cc864f29c4e2ad2307eaec3/tui_gateway/entry.py — tui_gateway/entry.py
[4] https://raw.githubusercontent.com/NousResearch/hermes-agent/69f73ec5f11f5a945cc864f29c4e2ad2307eaec3/tui_gateway/contracts/liveness.py — tui_gateway/contracts/liveness.py
[5] https://raw.githubusercontent.com/NousResearch/hermes-agent/69f73ec5f11f5a945cc864f29c4e2ad2307eaec3/tui_gateway/contracts/sessions.py — tui_gateway/contracts/sessions.py
[6] https://raw.githubusercontent.com/NousResearch/hermes-agent/69f73ec5f11f5a945cc864f29c4e2ad2307eaec3/tui_gateway/methods_session.py — tui_gateway/methods_session.py
[7] https://raw.githubusercontent.com/NousResearch/hermes-agent/69f73ec5f11f5a945cc864f29c4e2ad2307eaec3/tui_gateway/event_replay.py — tui_gateway/event_replay.py
[8] https://raw.githubusercontent.com/NousResearch/hermes-agent/69f73ec5f11f5a945cc864f29c4e2ad2307eaec3/tui_gateway/contracts/events.py — tui_gateway/contracts/events.py
[9] https://raw.githubusercontent.com/NousResearch/hermes-agent/69f73ec5f11f5a945cc864f29c4e2ad2307eaec3/tui_gateway/prompt_turn.py — tui_gateway/prompt_turn.py
[10] https://raw.githubusercontent.com/NousResearch/hermes-agent/69f73ec5f11f5a945cc864f29c4e2ad2307eaec3/tui_gateway/contracts/prompt_voice.py — tui_gateway/contracts/prompt_voice.py
[11] https://raw.githubusercontent.com/NousResearch/hermes-agent/69f73ec5f11f5a945cc864f29c4e2ad2307eaec3/tui_gateway/contracts/canonical_sessions.py — tui_gateway/contracts/canonical_sessions.py
[12] https://github.com/NousResearch/hermes-agent/issues/130702 — Upstream recovery negotiation discussion
