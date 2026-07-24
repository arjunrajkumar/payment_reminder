# PaymentReminder capability and operations audit

This document records the capabilities found during the July 2026 codebase audit. It distinguishes
between behavior available in the product, domain behavior that exists but is not exposed to an
ordinary user, and operator behavior exposed through the platform-admin panel.

## Status key

- **Available** means a user or platform administrator has a production route or scheduled job for
  the behavior.
- **Latent** means the underlying model, job, or mailer exists, but an ordinary user cannot initiate
  the complete workflow.
- **Not built** means the repository contains no complete implementation of the behavior.

## User-facing capabilities

### Public access, signup, and authentication

- **Available:** signed-out requests to the application root redirect to the official hosted
  marketing site; the privacy policy, terms, and health endpoint are served by the Rails app.
- **Available:** create an account with an email address, verify it with a six-character one-time
  code, complete the account-owner profile, and sign out.
- **Available:** sign up or sign in with Xero OpenID Connect. A Xero signup creates the
  PaymentReminder account and starts the first invoice sync.
- **Available:** sign in later with a 15-minute email code. Requests are rate-limited and codes are
  single-use.
- **Available:** the app records browser sessions and associated external identities.
- **Latent:** one identity can be associated with users in multiple accounts, but there is no
  account switcher, invitation flow, or team-management UI.

### Accounts and roles

- **Available:** each account is created with a system user and a verified owner.
- **Available:** `owner`, `admin`, `member`, and `system` roles exist. Owner and admin users can
  mutate account-wide settings, customer recipients, invoice-source connections and refreshes,
  Gmail delivery, and debtor ratings. Members can view account data and manage their own
  notification preferences.
- **Available:** account URLs are scoped by a generated numeric external account identifier, and
  access requires an active user membership for that exact account. The path is not treated as a
  secret or authorization boundary.
- **Latent:** user deactivation and all four roles are supported in the domain, but ordinary users
  cannot invite, edit, promote, demote, deactivate, or remove teammates.
- **Latent:** `Account#active?` always returns true; account suspension is not implemented.

### Accounting integrations and invoice synchronization

- **Available:** connect, reconnect, disconnect, and manually refresh Xero. A recurring job considers
  every refreshable active or errored source every six hours.
- **Available:** install the Stripe App, choose the PaymentReminder account that should receive the
  installation, and manually refresh Stripe invoices. A PaymentReminder account holds one Stripe
  source/mode, so live and ordinary test installations use separate accounts.
- **Available:** receive signed Xero webhooks and public-App connected-account Stripe webhooks,
  persist their processing state, and refresh the affected invoice. Stripe reads invoices and
  events only; it does not create accounts, change invoices, or move money.
- **Available:** imported customers and invoices keep their provider identifiers, amounts,
  currencies, status, due and payment dates, provider status, and provider invoice/PDF links when
  supplied.
- **Available:** provider invoice details are refreshed immediately before a reminder or promise
  follow-up is sent, so a newly paid or voided invoice is not chased using stale local state.
- **Not built:** a local Stripe disconnect button. Stripe uninstall and access revocation happen in
  Stripe's Installed Apps settings; on the supported public connected-account path, the
  deauthorization webhook then marks the source disconnected.

### Invoice and customer workspace

- **Available:** view a paginated invoice list ordered by collection priority, with customer name,
  debtor rating, amount payable, due timing, invoice status, and reminder history.
- **Available:** reminder emails include the provider-hosted invoice link when the provider supplies
  one. Hosted invoice and PDF URLs are retained with imported provider data, but there is no
  ordinary-user invoice-detail page exposing both links.
- **Available:** view the email address synchronized from the accounting provider.
- **Available:** account owners and admins can add or remove extra reminder recipients. Invalid
  synchronized addresses are shown but excluded from delivery; valid addresses are normalized and
  deduplicated.
- **Available:** account users have a paginated conversation Inbox with attention and review
  filters, canonical invoice conversations, unmatched sender identity, and a chronological
  message/event timeline.
- **Available:** the Inbox shows proposed actions with immutable revisions and lets account users
  edit human-visible proposal content, approve or reject the exact current revision, and retain the
  decision actor, time, and rationale. Approval records a decision only; it does not execute an
  action or send a message.
- **Available:** account users can place multiple independent invoice collection holds and release
  each one explicitly. Active holds visibly pause scheduled reminders and payment-promise
  follow-ups while leaving the manual reply composer available.
- **Available:** account users can open, resolve, and reopen conversation escalations. Pending
  action approvals and open escalations remain Inbox attention work until they are decided or
  resolved; a hold by itself is visibly badged but does not permanently require attention.
- **Not built:** a dedicated customer profile, invoice detail page, search, user-entered invoice
  editing, or accounting-provider write-back.

### Debtor ratings

- **Available:** every account has Good Debtor, Normal Debtor, and Bad Debtor segments.
- **Available:** a customer's rating is recalculated after invoice synchronization or by an owner or
  admin using **Refresh ratings**.
- **Available:** the calculation considers up to the 12 most recent completed outcomes. It requires
  at least three outcomes; otherwise the customer is Normal. An invoice paid by its due date counts
  as on time and an uncollectible invoice counts as not on time. Draft, open, overdue, and void
  invoices do not count as completed payment outcomes.
- **Available:** owners and admins can change the Good and Bad on-time-rate thresholds in 5%
  increments. The Good threshold must remain above the Bad threshold; Normal is the range between
  them.

### Gmail delivery, reminders, and notifications

- **Available:** an owner or admin can connect or reconnect a Gmail or Google Workspace account,
  send a test email, set the sender display name, disconnect Gmail, and enable or disable automatic
  reminders. OAuth includes `https://www.googleapis.com/auth/gmail.send`, restricted
  `https://www.googleapis.com/auth/gmail.readonly`,
  `https://www.googleapis.com/auth/userinfo.email`,
  `https://www.googleapis.com/auth/userinfo.profile`, and a stable Google account ID.
- **Available:** each account has persisted reminder stages and tones for each debtor rating. The
  hourly scheduler finds invoices due for a stage and sends through the account's Gmail connection.
- **Available:** delivery is recorded in a conversation-message ledger before sending and finalized with
  the provider message/thread identifier or a failure reason. Temporary provider errors use bounded
  retries, and pending deliveries older than two hours are reconciled to failed.
- **Available:** a roughly 15-minute Gmail History poll creates durable message receipts, with a
  seven-day screened initial sync and an overlapping recovery scan for expired cursors. Relevant
  inbound customer mail and manually sent Gmail mail are imported; unrelated content is ignored at
  receipt level. Imported manual mail participates in the 48-hour cooldown.
- **Available:** automatic, spam, unmatched, ambiguous, and parse-problem messages are persisted as
  account-user review work. Users can review a Gmail-thread work unit, manually match it to a
  customer or invoice when safe, and send a verified threaded reply from an invoice conversation.
  Gmail state is never modified; raw MIME and attachments are not retained.
- **Available:** users can independently opt in to emails when a reminder succeeds and when the last
  overdue stage requires manual follow-up.
- **Available:** an active collection hold, active payment promise, or successful outbound
  conversation message in the previous 48 hours suppresses an otherwise-due automatic stage. The
  suppression is persisted so the same stage is not retried later.

The default reminder stages are:

| Debtor rating | Before due | After due |
| --- | --- | --- |
| Good | 3 days, friendly | 3 days, neutral; 10 days, final |
| Normal | 7 days, friendly; 1 day, direct | 3 days, direct; 7 days, firm; 14 days, final |
| Bad | 14, 7, 3, and 1 days, direct | 1 day, firm; 5 days, final |

## Exact automatic-reminder constraints

An automatic reminder is eligible only when all of the following are true:

1. Automatic reminders are enabled for the account.
2. The account has an active Gmail connection, the configured sender address exactly matches the
   connected Gmail address, and the connection has usable credentials.
3. The invoice's accounting source can be refreshed and the refreshed invoice is still open with a
   positive amount due.
4. The customer's current segment has the requested persisted schedule stage.
5. The invoice due date matches that stage on the current calendar date exactly.
6. At least one valid synchronized or additional customer email address exists.
7. The stage has not already been delivered or suppressed, and another outbound delivery for the
   invoice is not pending.
8. The invoice has no active collection hold or active payment promise and has not had a successful
   outbound message within the previous 48 hours.

There is intentionally no catch-up scan: if the scheduler does not run on an exact stage date, that
stage is skipped rather than sent late. A persisted failed scheduled-reminder stage also blocks an
automatic attempt for the same stage. These are existing, test-covered product rules, not incidental
queue behavior.

## Implemented but latent capabilities

### Payment promises

The payment-promise lifecycle is implemented in the domain but has no ordinary-user capture flow:

- **Latent for users:** record a customer's promise against an invoice. Recording a newer promise
  supersedes the invoice's previous active promise.
- **Available after a promise exists:** an active promise suppresses automatic reminders.
- **Available after a promise exists:** its follow-up date is the promised date plus one day. An
  hourly job checks due promises, refreshes the invoice, marks the promise fulfilled when paid (or
  when an open invoice has a zero balance), cancels it when the invoice is otherwise no longer
  outstanding, or sends a Gmail follow-up when it remains outstanding.
- **Available after a promise exists:** follow-up messages use the same valid-recipient, active-Gmail,
  48-hour cooldown, pending-delivery, durable-ledger, retry, and stale-delivery protections as other
  outbound messages. Automatic reminders must be enabled for the follow-up to send.
- **Available after a promise exists:** any active invoice collection hold pauses follow-up
  refresh and delivery without fulfilling, cancelling, superseding, or failing the promise. Once
  every hold is released, a still-active due promise is reconsidered by the hourly scheduler.
- **Latent for users:** explicitly fulfill, cancel, supersede, or immediately enqueue a follow-up.

The new manual recorder creates the received customer-reply ledger entry required by the domain and
then records the promise transactionally. It does not pretend that an email was ingested.

### Conversation and reply types

The application has a provider-neutral conversation foundation exposed through the account-user
Inbox. A `Conversation` groups one logical accounts-receivable case, with one canonical conversation
for each invoice and support for account-only unmatched conversations. Every conversation message
belongs to a conversation, while provider thread identifiers remain on individual messages so
multiple provider threads can belong to the same case.

Conversation creation, resolution, and reopening are recorded as immutable audit facts with system,
user, or future AI actor attribution. This event ledger does not execute actions or change invoices,
promises, or email delivery state.

### Human-approved deterministic action execution

The account-user Inbox now exposes the transport-neutral review foundation:

- `ConversationAction` stores the proposal lifecycle and the exact approved or rejected revision.
- `ConversationActionRevision` stores append-only proposal evidence, including the invoice and
  customer context at the time of each revision, human-visible summary/rationale, structured
  arguments, and proposed reply content.
- `CollectionHold` is the source of truth for invoice-level automated-collection safety. Multiple
  active holds coexist, each is released separately, and historical stage suppressions remain after
  release.
- `ConversationEscalation` stores open/resolved human-review work independently from holds.
- Every transition writes a concise event to the existing append-only conversation ledger.

Approval now durably creates one execution for the exact approved revision. Initial execution and
action-reply delivery each use a database-backed scheduling reservation with bounded attempts,
backoff, ownership generations, and stale-owner recovery. Replaced jobs and claim tokens cannot
write effects, replies, events, escalations, or terminal state.

Rails validates a strict action catalog before approval, refreshes provider invoice state outside
database transactions when facts are required, and revalidates ownership and current authorization
under the established lock order. The deterministic local-effect phase commits before a separate,
replay-safe reply-reservation phase. Reconciliation can therefore resume after either commit
without applying a payment promise, recipient update, or dispute hold twice, and a reply problem
cannot roll the local effect back.

Implemented commands record a payment promise, answer due-date/payment-status/outstanding-amount
questions, resend a safe provider-hosted invoice URL, add a future reminder recipient or one-time
CC, place a dispute hold and escalation, or route unsupported `other` work to a person. Rails owns
all factual wording; proposal text is retained as untrusted approval evidence and is never the
source of invoice facts.

Reviewers can append a revision that corrects the allowlisted structured arguments and bounded
non-factual greeting or closing. Arbitrary proposed subject/body prose remains historical evidence
and cannot control facts or side effects. Preview and reservation use the same composition path;
completed history displays the immutable reserved message rather than recomputing current facts.

Action replies preserve the verified customer recipient, Gmail thread, RFC reply headers, mailbox
identity, credential generation, immutable message identity, bounded scheduling/delivery attempts,
and Gmail SENT reconciliation used by manual replies. Definite failure and uncertain handoff are
distinct. Uncertain delivery is never retried automatically, and later Gmail SENT import repairs
execution state without erasing the earlier uncertainty audit. Delivery-failure escalation evidence
is separate from the command's dispute escalation, so repair never releases the dispute hold.
Decision and reply actor snapshots retain historical identity after a user is removed.

AI classification, prompt/model calls, shadow-mode planning, automatic execution allowlists,
customer-specific learning, and daily summaries are **not** implemented.

### Future customer-specific AI learning boundary

The action/revision/decision, hold, escalation, message, and event records preserve evidence for a
future AI evaluation workflow, but PaymentReminder does not yet learn or change behavior per
customer.

A future PR 5/5B design must use bounded, customer-scoped strategy-insight candidates rather than
one unbounded free-text memory field. Every candidate must cite immutable evidence IDs such as
customer messages, action revisions, human edits/decisions, executed actions, and later outcomes;
record confidence, model version, prompt version, creation time, and provenance; and follow a
candidate → human-approved/rejected → retired/superseded lifecycle. AI must never silently activate,
edit, or delete durable guidance.

Only active, human-approved insight versions may later enter planning context, and every AI proposal
must record the exact insight IDs and versions it read. Changed context before approval or execution
must require re-planning or renewed approval. Explicit customer statements and human corrections
outweigh inferred outcomes; payment after an email is correlation, not proof that the wording caused
payment. Planning context must remain bounded. Learned tone, wording, or timing can never override
provider invoice facts, disputes, collection holds, cooldowns, recipient validation, or
deterministic execution policy. Customer identity remains provider-scoped, so insights must not be
merged across `Customer` records without a separate identity-merging feature.

`ConversationMessage` supports these kinds:

- `scheduled_reminder` and `manual_reminder` for outbound collection messages;
- `promise_follow_up` for an overdue payment-promise follow-up;
- `customer_reply` for the manually recorded inbound source of a payment promise;
- `customer_email` for imported inbound email and `manual_email` for mail sent directly in Gmail;
- `due_date_answer`, `payment_status_answer`, `outstanding_amount_answer`, `invoice_resend`,
  `payment_promise_acknowledgement`, `recipient_update_acknowledgement`, and
  `dispute_acknowledgement` for approved deterministic responses.

Scheduled reminders, operator-initiated manual reminders, promise follow-ups, manually recorded
customer replies, and screened Gmail imports have complete producers. Gmail ingestion is
deterministic and contains no automatic email understanding, AI classification/response pipeline,
or automatic customer response pipeline. Human review, manual matching, and verified threaded
manual replies are available in the account-user Conversation Inbox.

### Other latent operations

- Invoice schedules are persisted and validated, but ordinary users cannot add, remove, or edit
  individual stages and tones.
- The application has durable records for webhook events, delivery failures, reminder
  suppressions, sessions, external identities, provider data, and synchronization errors, but no
  user-facing diagnostic console.
- Ordinary users have no one-off reminder, failed-stage retry, or free-form manual payment-promise
  UI outside approved deterministic actions.

## Platform administrator panel

The Madmin panel is an operator console for the developer or hosted-service administrator, not an
account-level customer admin. It is mounted at `/madmin` without an account URL prefix and is
protected by a separate, fail-closed allowlist that combines `PLATFORM_ADMIN_EMAIL_ADDRESSES` with
Rails credentials under `platform_admin.email_addresses`. An account owner is not automatically a
platform admin.

### Global visibility

A platform admin can browse all records across all tenants, including:

- accounts and the users and identities associated with them;
- customers, additional recipient addresses, debtor segments, and imported invoices;
- Xero and Stripe invoice sources, sync status/errors, and webhook events;
- Gmail connection status and configured sender identity;
- schedules, reminders, suppressions, conversation-message delivery state, and payment promises;
- notification subscriptions and sessions.

Sensitive values are deliberately omitted from the admin resources: decrypted OAuth access and
refresh tokens, raw provider token payloads, Stripe installation-claim digests/tokens, magic-link
codes, raw provider invoice records, and signed webhook payloads. Email content and recipient lists
are excluded from indexes and search but remain visible on the individual message record for support
and delivery diagnosis. Operational records imported from providers are read-only through generic
CRUD so an admin cannot casually break tenant or provider relationships.

### Currently exposed administration

- Edit an account's business/reminder settings.
- Edit Good and Bad debtor thresholds and persisted reminder schedules.
- Edit or remove additional customer recipients.
- Edit a user's display name, role (`owner`, `admin`, or `member`), and notification preferences.
- Suspend or restore an active human user's access, revoke another browser session, and revoke an
  outstanding magic link.
- Browse delivery failures, source failures, webhooks, suppressions, promises, sessions, and their
  associations across accounts.
- Browse durable Gmail screening receipts and their processing state, and manually requeue a
  terminally failed receipt. Receipts remain read-only outside that purpose-built retry action.
- Browse the durable platform-admin event ledger. Redirecting POST/PATCH/PUT/DELETE requests handled
  by Madmin record the signed-in administrator, action, target record, affected account when known,
  timestamp, and names of changed fields without copying submitted values or secrets. Validation
  failures rendered in place are not currently recorded, and mutations made through ordinary
  account controllers while impersonating are not individually written to this ledger. A Gmail
  receipt retry whose enqueue step raises records a dedicated failure event with only the error
  class.
- Refresh all debtor ratings in an account or refresh one customer; run today's reminder scheduler
  for one account.
- Queue a Xero or Stripe invoice refresh, disconnect an invoice source, and retry a pending or failed
  webhook event. Xero disconnect also requests provider-side revocation; the Stripe operator action
  changes local state but does not replace uninstalling the App in Stripe.
- Disconnect an account's Gmail connection, which also disables automatic reminders.
- Send a one-off reminder for an outstanding invoice. This explicit operator override refreshes the
  provider invoice first and still requires an active matching Gmail sender, at least one valid
  recipient, and no other pending delivery. It is allowed even when automatic reminders are off and
  does not apply the stage-date, active-promise, or 48-hour automatic-reminder suppression rules.
- Record a customer's payment promise with an operator note, mark an active promise fulfilled or
  cancelled, and enqueue its normal due-follow-up check.
- Act as any active human user. Impersonation selects that user's exact account, shows a persistent
  banner, and can be stopped to return to the operator console. It does not expose system users or
  turn an inactive user into an active one. The platform-admin identity retains account-admin
  authorization while impersonating, so this is support mode rather than a faithful simulation of
  the selected user's permissions.

Generic create/update/delete is intentionally blocked for high-risk and provider-owned records.
Platform operations use the application's domain methods and jobs so validation, tenant integrity,
provider freshness checks, delivery idempotency, and retry behavior continue to apply.

The panel does not create or delete customer accounts, create users, reassign sign-in identities,
or rewrite imported customer/invoice/provider state through raw forms. Those operations need
deliberate domain workflows; impersonation is not a substitute for a provider-side data edit.

### Operations that still require provider consent

Platform-admin status cannot bypass OAuth or act as a provider account owner. A real provider user
must still approve:

- connecting or reconnecting Xero;
- installing or authorizing Stripe for an account;
- connecting or reconnecting the Gmail/Google Workspace sender.

After valid credentials already exist, a platform admin may use an explicit operator action or
impersonation to request a sync, test delivery, adjust app settings, or send through that existing
connection. Stripe uninstall/revocation still happens in Stripe. Provider-side permissions,
organization access, security policies, and consent screens remain authoritative.

## Critical runtime and data dependencies

### Application runtime

- Ruby 3.4.5, Rails 8, MySQL 8, the database schema, and stable Rails encryption/signing keys.
  Changing encryption keys without a migration makes stored OAuth credentials unusable.
- The web process plus Solid Queue workers for both `default` and `webhooks` queues.
- Solid Cache and Solid Cable where configured, and durable storage for MySQL and application
  secrets.
- A correct HTTPS `HOST`, DNS/TLS, outbound network access, and production email delivery (for
  sign-in codes and internal notification messages).

### Required recurring work

| Job | Production schedule | Purpose |
| --- | --- | --- |
| Invoice-source refresh | Every 6 hours | Refresh Xero/Stripe invoices and debtor ratings |
| Invoice-reminder scheduler | Every hour | Enqueue stages due on the current date |
| Payment-promise scheduler | Hourly at minute 20 | Enqueue follow-ups for due active promises |
| Pending-message reconciler | Hourly at minute 40 | Fail deliveries left pending for more than 2 hours |
| Gmail inbound poll | Every 15 minutes | Enqueue mailbox History synchronization |
| Pending Gmail receipt processor | Every 15 minutes | Recover stalled receipts and enqueue due processing |

All six jobs have Sentry cron-monitor check-ins when Sentry is configured. `/up` checks only the web
process; it does not prove that queue workers or recurring jobs are healthy.

### Provider dependencies

- Xero client credentials, registered signup/sign-in/connection callback URLs, webhook signing key,
  tenant access, rotating refresh tokens, and reachable Xero APIs.
- Stripe App ID, install URL when using public install-link distribution, app request signing
  secrets, live/test platform secret keys, distinct live/test webhook signing secrets, configured
  connected-account event destinations for real-time updates, and the required read-only App
  permissions.
- Google OAuth client credentials, an approved callback URL, canonical Google identity scopes,
  Gmail send and readonly scopes, a usable refresh token, and an account sender address that
  exactly matches the connected Gmail identity.
- Amazon SES or another configured Rails mail transport for authentication and account-user
  notifications. Customer collection messages are delivered through the account's Gmail
  connection, not SES.

### Data invariants

- Each account needs a unique external account identifier, exactly one of each debtor segment, and
  its persisted default schedules.
- Every customer, segment, invoice source, and invoice association must remain inside one account;
  every imported invoice must have a customer.
- Database unique indexes, foreign keys, row locks, delivery ownership IDs, and queue concurrency
  limits are part of reminder idempotency. They are not optional performance details.

## Confirmed defects corrected in this audit

- Fixed account selection being overwritten after authentication, which could show the first
  membership instead of the account selected by the URL; authorization now verifies the exact
  account/user membership.
- Added owner/admin guards for account-wide mutations while preserving a member's ability to edit
  their own notification preferences.
- Made Stripe embedded onboarding show an explicit eligible-account selector and reject tampered or
  unauthorized account IDs instead of silently choosing the first account.
- Reworked the customer-segment migration to create and backfill segments before enforcing required
  foreign keys, and added a forward repair for missing segments, cross-account segment references,
  missing account external IDs, missing invoice customers, and orphan schema columns.
- Added account/customer validation for required external IDs and same-account invoice-source and
  segment relationships.
- Serialized refresh-job and webhook processing per invoice source, locked Xero rotating-token
  refresh, and persisted source errors when refresh or webhook processing fails.
- Made one-time-code consumption atomic so concurrent requests cannot consume the same magic link.
- Added network timeouts to Gmail OAuth HTTP requests.
- Fixed generated account-name ordinals such as 21st, 22nd, and 23rd and tightened suffix matching.
- Returned actionable validation errors for invalid HTML signup submissions.
- Corrected the privacy policy to disclose that generated outbound message content is stored in the
  delivery ledger.
- Removed test gems from the production container bundle and documented all six recurring-job
  monitors.

## Remaining product, policy, and operations gaps

These items were found during review but were not silently changed because they require product,
privacy, security, or deployment decisions:

- There is no AI extraction, automated answer generation, or AI-response approval workflow. The
  ordinary-user accounts-receivable Inbox supports deterministic human review, manual matching,
  and user-authored threaded replies.
- Provider synchronization intentionally preserves an existing customer email when a later provider
  payload has a blank email. This may retain a stale recipient, but existing tests define the
  behavior and it needs an explicit product decision.
- Exact-date scheduling has no catch-up, and a failed scheduled stage is not automatically retried
  after its bounded job retries. The platform manual-reminder path provides an operator escape hatch
  without changing that policy.
- Operator-sent manual reminders are visible in the global conversation-message ledger but do not appear
  in the ordinary user's scheduled reminder-history component.
- Unexpected Gmail delivery exceptions are currently recorded as terminal failures, as required by
  existing tests; changing retry classification needs a deliberate reliability policy.
- Sessions use a permanent signed cookie and have no explicit maximum age, rotation UI, or
  user-facing session revocation screen.
- There is no workspace time zone, delivery window, holiday calendar, or per-customer contact
  preference. Reminder dates use the application's current date.
- All valid reminder recipients are placed on one outbound message. Whether recipients should be
  isolated in separate messages or hidden with BCC is a privacy/product decision.
- The hourly scheduler scans every account and every schedule. Larger deployments may need batching,
  database-driven due work, or additional queue backpressure.
- There is no customer account switcher, team/invite UI, profile editing, account suspension,
  account deletion/export, or self-service data-retention workflow.
- The current Stripe webhook router requires a connected-account `account` identifier. Private-App
  ordinary-account events omit it, so private installs can refresh manually or every six hours but
  do not have a supported real-time webhook/deauthorization path yet.
- The platform-admin allowlist is static configuration. Operator mutations have a dedicated,
  append-only admin event ledger for Madmin requests, but impersonated account mutations are not
  individually logged. There is no separate admin MFA, step-up prompt, or built-in session expiry.
  Access to production admin credentials, database records, and logs must still be tightly
  controlled and paired with an explicit retention policy.
- Content Security Policy and allowed-host hardening remain deployment work. The checked-in Kamal
  configuration also needs an explicit production decision on end-to-end SSL, backups and restore
  drills, domain/IP values, secret rotation, and worker-health alerting.
