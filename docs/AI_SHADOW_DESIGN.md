# AI shadow interpretation design

PR 5A adds evidence and evaluation only. AI records never create a
`ConversationAction`, send mail, clear attention, or mutate invoices, customers,
promises, holds, escalations, recipients, or reminder schedules.

## Eligibility

`ConversationAi::Eligibility#decision` accepts a durable, received, inbound
`ConversationMessage` only when it is account-scoped, matched to one canonical
review work unit, and has the current mailbox identity. Draft, sent, spam, trash,
outbound, unmatched, ambiguous, split-invoice, replaced-mailbox, and disabled-mode
messages do not call a provider. Deterministic automatic replies become a
`skipped/no_action` interpretation without a provider call. Empty,
attachment-only, quoted-only, or unreliably parsed bodies become a local
`skipped/human_review` result without a provider call. HTML-only mail is analyzed
from its normalized stored body when authored content is reliable. Parse and
truncation warnings are retained; warnings that make authored-content isolation
unreliable prevent an actionable plan. Attachments are never read.

`ConversationAi::AnalysisRequest.enqueue_for` is called after the Gmail receipt
transaction commits, after manual matching commits, and by bounded reconciliation.
Manual matching therefore changes an otherwise ineligible message into one
eligible analysis identity. The unique analysis key combines source identity,
provider, requested model, semantic prompt, adapter, schema, planner, and approved
guidance revision. Replays converge on that identity. Explicit reanalysis adds a
generation/supersession component and never silently backfills history.

## Lifecycle and ownership

An interpretation moves through:

`pending -> running -> succeeded|failed|canceled|skipped`, with a terminal current
result later able to move to `superseded`. `pending` owns a scheduling token,
generation, bounded attempt count, enqueue timestamp, and next scheduling time.
`AnalysisRequest` reserves scheduling under lock, enqueues after commit, and
records acceptance; false/raised enqueue releases that exact reservation.
`Reconciler` repairs missing acceptance, stale scheduling owners, due retries,
stale provider claims, incomplete finalization, and stale current plans in bounded
SQL batches.

`Analyzer` atomically exchanges the current scheduling generation for a provider
claim token/generation. It snapshots context and creates one `started`
`ConversationAiInvocation`, commits, then calls the provider with no database lock
held. On return it reacquires canonical locks and accepts output only if the
account is still in shadow mode, provider selection is unchanged, and both claim
token and generation still match. A lost claimant may finalize only its invocation
as `superseded`; it cannot persist result, plan, signals, final events, or health.
Each job makes one external request. Retryable normalized failures schedule one of
at most five application attempts with bounded backoff; request/configuration,
refusal, unsupported-model, and malformed-output failures terminate safely.

Mode disable cancels queued work. An in-flight response remains auditable but
cannot become current or create follow-on records. Re-enabling affects only newly
eligible messages or explicit reanalysis. A newer message, manual reply, handled
state, owner move, provider change, or reanalysis never rewrites history; the old
plan is marked stale/superseded and the newest eligible inbound result is current.

## Lock order

Every finalization or ownership-sensitive decision uses the existing canonical
order:

1. Gmail mailbox/thread advisory lock when a provider thread participates.
2. `Receivables::AccountLock`.
3. Review-work-unit conversations, then messages, each in ID order.
4. Source message.
5. Interpretation.
6. Invocation.
7. Plan.
8. Customer AI signal, profile, and guidance revisions in ID order.

The external HTTP request is always outside this lock set. Scheduling does not
hold Gmail or work-unit locks while talking to Solid Queue.

## Prompt boundary

`ConversationMessages::AuthoredContent.extract` produces a bounded,
transport-neutral snapshot and warnings without altering the stored message.
`ConversationAi::ContextBuilder` includes only account timezone, source receipt
time and subject, newly authored text, trusted From/To/CC/Reply-To headers, opaque
keys and a bounded chronological excerpt, invoice identifier, customer name,
extraction warnings, and the exact active approved guidance revision.

It excludes mutable invoice facts, URLs, attachments, BCC, OAuth/API secrets, raw
provider payloads, account-user data, unrelated records, and all other accounts.
Every customer block is explicitly delimited as untrusted data. Quoted or
forwarded content is labelled separately and cannot evidence executable values.
System product policy outranks approved communication-style guidance, which in
turn outranks customer text.

`ConversationAi::Prompt` owns one provider-independent semantic prompt.
`OutputSchema` owns one conservative strict JSON Schema shared by OpenAI and
Anthropic. Interpretations record semantic prompt, provider-adapter, result
schema, planner, catalog/template, provider, requested model, canonical input
digest, guidance revision ID, and guidance digest. Adapters use native structured
output, no tools, no web/file search, no code execution, no agent loop, no hidden
reasoning, and no retained provider conversation.

## Deterministic shadow planning

`ConversationAi::Result` rejects unknown keys, oversized values, unsupported
language/actions, invalid basis-point confidence, and evidence absent from the
allowed snapshot. `ConversationAi::Planner` consumes only that validated result.
Exactly one intent, reliable authored content, supported language, current matched
context, overall and intent confidence at or above the versioned 8,500-bps
threshold, required authored evidence, valid values, and successful
`ConversationActions::Catalog.validate!` are all required to propose:

| Intent | Catalog action |
| --- | --- |
| `payment_promise` | `record_payment_promise` |
| `question_due_date` | `answer_due_date` |
| `question_payment_status` | `answer_payment_status` |
| `question_outstanding_amount` | `answer_outstanding_amount` |
| `resend_invoice` | `resend_invoice` |
| `add_recipient/permanent` | `add_recipient/future_reminders` |
| `add_recipient/cc_current_reply` | `add_recipient/cc_current_reply` |
| `dispute` | `open_dispute` |
| `other_requires_person` | `other` |

Unrelated and automatic mail produces `no_action`. Ambiguous, low-confidence,
unsupported-language, missing-value, attachment-only, stale, dispute-uncertain,
and multi-intent results produce `human_review`. Proposed free text remains audit
evidence; the plan retains only Catalog-safe non-factual reply fields. Planning
persists `ConversationAiPlan`, never `ConversationAction`.

## Customer feedback and guidance

`CustomerAi::SignalRecorder` accepts an AI-proposed signal only when trusted
RFC `In-Reply-To`/`References` evidence identifies one exact earlier outbound
message in the same locked review work unit. Gmail thread membership alone is
insufficient. Signals remain untrusted observations and cannot change a profile.

`CustomerAi::GuidanceDecision` lets an authorized user reject a signal or edit and
approve a bounded style-only revision. Approval creates an append-only
`CustomerAiGuidanceRevision` and atomically swaps the profile's one active
revision; concurrent or stale signed snapshots fail. Allowed guidance is limited
to tone, supported language, salutation, concision, communication notes, and
phrases to avoid. It cannot express invoice facts, recipients, delivery,
authorization, reminder, cooldown, promise, dispute, hold, escalation, or
collection policy. In-flight analysis remains bound to the revision and digest it
snapshotted.

## Human evaluation and reporting

`ConversationAi::EvaluationRecorder` verifies a signed, expiring token binding
account, work unit, interpretation, plan, and version. It appends a
correct/incorrect/unsure verdict, optional corrected intent/action/arguments and
note, and immutable actor snapshot. Exact idempotent replay returns the same row;
a correction appends a row that supersedes the prior evaluation without deleting
it. Concurrent submissions serialize on the interpretation.

Reports use only the latest non-superseded human evaluation. Correct and incorrect
form the accuracy denominator; unsure and unreviewed are shown separately.
Silence, payment, generic thanks, and absence of human action are never inferred
as ground truth. Volume, lifecycle, intent, planner, signal, and evaluation
metrics remain comparable by provider, requested/returned model, semantic prompt,
adapter, schema, and planner version.
