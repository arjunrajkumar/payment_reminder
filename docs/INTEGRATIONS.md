# PaymentReminder integrations

PaymentReminder separates invoice import, customer reminder delivery, and installation-wide
application email:

| Integration | Direction | Purpose |
| --- | --- | --- |
| Xero | Read-only import plus webhooks | Invoices and the customer details embedded in them |
| Stripe App | Read-only import plus supported connected-account events | Invoices, provider links, payment state |
| Gmail / Google Workspace | Send and readonly OAuth | Customer reminders and screened Gmail import |
| SMTP / Amazon SES | Outbound SMTP | Sign-in codes and notifications from the installation |

Configure only the services needed by the installation. Prefer isolated provider applications and
credentials for development and production where the provider supports that workflow. Never reuse
or request secrets from the official hosted PaymentReminder service.

Before starting, set a stable public `HOST` and create fork-owned Rails credentials using
[Configuration](CONFIGURATION.md).

## Xero

PaymentReminder offers email authentication separately. The Xero integration supports Xero-based
signup and sign-in, connecting an organization, importing sales invoices and the customer details
embedded in them, manual and recurring refresh, signed invoice webhooks, reconnect, and disconnect.
It requests:

- `openid`
- `profile`
- `email`
- `accounting.invoices.read`
- `accounting.contacts.read`
- `offline_access`

PaymentReminder does not write invoices or contacts back to Xero. Although the current OAuth scope
set includes `accounting.contacts.read`, synchronization builds local customers from the Contact
data embedded in invoice responses rather than calling Xero's Contacts endpoint directly.

### Register the Xero application

Create an OAuth 2.0 app in the Xero Developer portal and register all three redirect URIs for each
environment:

```text
<HOST>/xero/callback
<HOST>/signup/xero/callback
<HOST>/session/xero/callback
```

For the default local server these are:

```text
http://localhost:3000/xero/callback
http://localhost:3000/signup/xero/callback
http://localhost:3000/session/xero/callback
```

Add the Xero values to Rails credentials:

```bash
bin/rails credentials:edit
```

```yaml
xero:
  client_id: your-xero-client-id
  client_secret: your-xero-client-secret
  webhook_signing_key: your-xero-webhook-signing-key
```

Do not add placeholder values: the UI considers a client ID and secret to be configured and will
attempt the OAuth flow.

### Configure Xero webhooks

Create an invoice webhook subscription with this delivery URL:

```text
<HOST>/invoice_sources/webhooks/xero
```

Copy the subscription's Webhook Key into `xero.webhook_signing_key`. Complete Xero's
intent-to-receive validation and verify a real invoice update reaches the endpoint successfully.

For local testing, expose the Rails server through an HTTPS tunnel and register the tunnel URL. The
webhook endpoint is global and unscoped; PaymentReminder verifies the signature and routes each
event to the connected Xero tenant.

### Use Xero in PaymentReminder

After restarting the app:

1. Sign up with Xero, or create an email account and open its **Settings** page.
2. Select **Connect** in the Xero row and approve the organization.
3. Select **Resync** to import invoices immediately.
4. Check the source state and last error in Settings if synchronization fails.

A production worker considers every refreshable active or errored invoice source every six hours.
Xero refresh tokens rotate; keep the Rails encryption key stable and do not operate multiple
releases against different keys.

For a second local port, register that port with Xero and set `HOST` consistently:

```bash
HOST=http://localhost:3001 bin/rails server -p 3001 -P tmp/pids/server-3001.pid
```

## Stripe App

Stripe integration uses a Stripe App with `stripe_api_access_type: platform`, not the legacy
Connect Extension OAuth flow. It requests only `invoice_read` and `event_read`. PaymentReminder
uses the publisher account's server-side platform key with the installed account's
`Stripe-Account` header; it does not receive per-install OAuth access/refresh tokens, create
accounts, change invoices, or move money.

The complete real-time webhook path in this release is designed for a public or externally tested
Stripe App whose event destinations deliver connected-account events with an `account` identifier.

### Self-hosting boundary

The checked-in manifest identifies the official public PaymentReminder Stripe App and its hosted
origin. A fork must create an App under a Stripe account the fork operator controls and change:

- `id` and, when appropriate, `distribution_type`;
- `allowed_redirect_uris`;
- `PAYMENT_REMINDER_ORIGIN`;
- `ui_extension.content_security_policy.connect-src`.

The App's Settings view must send signed Stripe account context to the fork's
`POST <HOST>/stripe/app/onboarding_claims` endpoint. Do not replace that with an unsigned account
ID. The Stripe user opening that view must be a built-in Administrator or Super Administrator.
After continuing to PaymentReminder, the signed-in user must be an owner or admin of the selected
destination account.

A private App has different distribution/install behavior from a public marketplace App and does
not use the upstream public install link. Start a private installation from the App's embedded
Stripe Settings view. The ordinary **Connect Stripe** link inside PaymentReminder is wired to the
public `install_url` flow, so a private-App fork must either hide/adapt that link or document that
operators start in Stripe. Turnkey distribution of one self-hosted App across unrelated Stripe
accounts is outside this release.

A private App can use embedded Settings to create the local source and then use manual and
six-hour refreshes. Its ordinary-account webhook events do not carry the connected-account
identifier expected by the current handler, so they are ignored. Real-time invoice updates and
deauthorization for that private-App path are not supported until the webhook routing is adapted.

### Upload the App and collect credentials

Install the Stripe CLI and Apps plugin, then sign in to the Stripe account that will own the App:

```bash
stripe login
stripe plugin install apps
cd stripe-app
npm ci
stripe apps upload
```

App IDs are globally unique. If a fork maintains a separate development App, give it a unique ID.
Stripe external tests are created from an uploaded version of the same App in its owning account;
they do not require a second Stripe account or App.

Collect:

- the App ID;
- the App request signing secret (`absec_...`);
- the external-test/public install link if that distribution type uses one;
- the publisher account's test and live secret keys;
- a distinct signing secret for each live/test webhook destination.

The server-side Stripe keys and signing secrets must never appear in `stripe-app/`, JavaScript,
Git, an issue, or a browser response.

### Configure Rails

```bash
bin/rails credentials:edit
```

```yaml
stripe:
  app_id: your-stripe-app-id
  install_url: https://marketplace.stripe.com/apps/install/link/your-install-link
  signing_secrets:
    - absec_your-app-signing-secret
  secret_keys:
    live: sk_live_your-platform-key
    test: sk_test_your-platform-key
  webhook_signing_secrets:
    live:
      - whsec_your-live-webhook-secret
    test:
      - whsec_your-test-webhook-secret
```

Copy `install_url` exactly from Stripe when using install-link distribution. Keep all currently
valid App request secrets in `signing_secrets` during a rotation and all currently valid webhook
secrets in the matching live/test list.

The legacy Connect Extension's OAuth `client_id`, OAuth client secret, and per-install tokens are
not used by this flow.

### Configure public-App event destinations

For a public or externally tested App, create separate endpoints for live and ordinary test mode,
both listening to events on connected accounts:

```text
Live: <HOST>/invoice_sources/webhooks/stripe
Test: <HOST>/invoice_sources/webhooks/stripe/test
```

Subscribe to:

- `invoice.created`
- `invoice.updated`
- `invoice.finalized`
- `invoice.paid`
- `invoice.voided`
- `invoice.marked_uncollectible`
- `account.application.authorized`
- `account.application.deauthorized`

The live endpoint verifies only `webhook_signing_secrets.live`; the test endpoint verifies only
`webhook_signing_secrets.test`. Stripe CLI, test, live, and future Sandbox destinations each have
different secrets.

This release supports live mode and the developer account's ordinary test mode. The checked-in
manifest deliberately keeps `sandbox_install_compatible` false; do not enable it until isolated
Sandbox keys, installs, and webhooks are supported through the complete flow.

One PaymentReminder account can have only one Stripe source and mode. Use separate
PaymentReminder accounts when testing ordinary test mode alongside live mode.

### Local Stripe testing

The embedded Settings view accepts only an HTTPS PaymentReminder origin. Expose the local Rails
server through an HTTPS tunnel and use a development or extended manifest with:

```text
allowed redirect URI: https://your-tunnel.example/stripe/callback
PAYMENT_REMINDER_ORIGIN: https://your-tunnel.example
connect-src: https://your-tunnel.example/stripe/app/onboarding_claims
```

Keep those local values out of the production manifest. For the public/connected-account path,
forward events with:

```bash
HOST=https://your-tunnel.example bin/dev
```

The `HOST` value must match the tunnel origin so the backend returns an HTTPS onboarding URL that
the embedded extension accepts. In another terminal, forward events with:

```bash
stripe listen \
  --events invoice.created,invoice.updated,invoice.finalized,invoice.paid,invoice.voided,invoice.marked_uncollectible,account.application.authorized,account.application.deauthorized \
  --forward-connect-to localhost:3000/invoice_sources/webhooks/stripe/test
```

Store the printed `whsec_...` only in local test webhook credentials. After Rails and the App are
configured, use the App's Stripe Settings view to start onboarding. On PaymentReminder's onboarding
page, sign in or create an account and select the destination you administer, then select
**Resync** in PaymentReminder Settings.

Do not use `--forward-connect-to` as evidence that private ordinary-account webhooks work. A
private App's normal `--forward-to` events require a routing change in PaymentReminder before that
real-time path is supported.

On the supported public connected-account path, uninstalling the App in Stripe revokes access and
sends `account.application.deauthorized`. PaymentReminder does not currently expose an
ordinary-user Stripe disconnect button; the provider remains authoritative. Private-App
deauthorization is subject to the unsupported webhook path described above.

Useful Stripe references:

- [Stripe App permissions](https://docs.stripe.com/stripe-apps/reference/permissions)
- [Authenticate Stripe Dashboard requests](https://docs.stripe.com/stripe-apps/build-backend)
- [Stripe App events](https://docs.stripe.com/stripe-apps/events)
- [Install links](https://docs.stripe.com/stripe-apps/install-links)
- [Distribution options](https://docs.stripe.com/stripe-apps/distribution-options)
- [Webhook signature verification](https://docs.stripe.com/webhooks/signature)

## Gmail reminder delivery and screened import

Each PaymentReminder account can connect one Gmail or Google Workspace mailbox. Its address becomes
the customer reminder From address; an account owner or admin can customize the visible sender
name. PaymentReminder also polls Gmail approximately every 15 minutes to import relevant customer
replies and messages sent manually from the connected mailbox.

PaymentReminder requests the canonical
`https://www.googleapis.com/auth/gmail.send`,
`https://www.googleapis.com/auth/gmail.readonly`,
`https://www.googleapis.com/auth/userinfo.email`, and
`https://www.googleapis.com/auth/userinfo.profile` scopes. The stable Google account subject
identifies the mailbox even if its address changes. Gmail readonly is a restricted Google scope; a
hosted deployment that stores Gmail data may require Google OAuth verification and a security
assessment.

The first successful connection screens messages from the previous seven days. Later polls use the
Gmail History API's `messageAdded` changes, so already-read and archived replies are still found.
If a history cursor expires, PaymentReminder performs a time-bounded overlapping recovery scan and
then catches up from a fresh history baseline. Durable per-message receipts let individual fetches
retry independently after the mailbox cursor advances.

Only mail with an exact Gmail/RFC thread, known customer address, or exact invoice reference is
imported as a conversation message. Unrelated mailbox content is not copied into PaymentReminder.
Relevant automatic replies, spam, unmatched, ambiguous, and malformed messages remain marked for
human review in the account-user Inbox. Users can review or manually match a Gmail-thread work unit
and send a verified threaded reply from an invoice conversation. PaymentReminder does not change
Gmail labels or read state, and does not store raw MIME or attachment bodies. Gmail push
notifications and automatic actions are not implemented. When an account administrator separately
enables AI shadow mode, eligible matched inbound content may be sent to the configured OpenAI or
Anthropic provider as described below.

Invoice collection holds are enforced independently of Gmail. The scheduler, queued-job preflight,
locked reservation, and final automated-delivery handoff all recheck active holds. A due scheduled
stage skipped during a hold receives its normal durable suppression receipt and is not sent
retroactively after release; later stages keep their original dates. Payment-promise follow-ups
pause without resolving the promise and are reconsidered after every hold is released. Human
threaded replies remain available during a hold. Once a Gmail provider request has passed the final
delivery handoff, it cannot be recalled.

Action approval durably queues one deterministic Rails command for the exact approved revision.
When invoice facts are needed, PaymentReminder refreshes the single provider invoice before it
re-enters the locked execution transaction. Rails—not proposal text—selects the command, validates
ownership and authorization, derives invoice facts, chooses the verified recipient, and renders the
versioned reply.

Execution scheduling and action-reply scheduling are durable outboxes with bounded attempts,
backoff, ownership generations, and recurring stale-owner/orphan recovery. The local command effect
commits in its own fenced phase before reply reservation. A disconnected mailbox, unsafe thread,
process crash, or queue failure therefore cannot undo an already recorded promise, recipient
change, dispute hold, or escalation.

Approved action replies use the existing Gmail delivery ledger and preserve provider thread ID,
`In-Reply-To`, `References`, mailbox identity, credential generation, sender, recipient, subject,
body, stable RFC Message-ID, and immutable approving-user snapshot. Definite delivery failure,
uncertain provider handoff, and later Gmail SENT reconciliation remain separate durable outcomes.
Unknown delivery is not retried automatically. Current database SENT evidence is authoritative over
stale failed state; it can upgrade a failed or unconfirmed execution without removing historical
failure events or resolving the command's dispute escalation.

Dispute execution commits an invoice collection hold and human escalation before any
acknowledgement delivery begins. The hold is released only through the existing explicit human
control.

### OpenAI and Anthropic shadow interpretation

OpenAI and Anthropic are optional server-side integrations. Configure one or both using the API-key
and explicit model variables in [Configuration](CONFIGURATION.md). An account administrator must
then select an available provider and enable shadow mode; configuration alone does not analyze
messages, and enabling does not backfill historical mail.

For each eligible, durably matched inbound message, PaymentReminder extracts a bounded authored
portion, excludes quoted history from executable evidence, and sends a labelled untrusted context
snapshot. The snapshot can include subject and authored body, bounded trusted delivery headers,
small recent-message excerpts from the same account review work unit, account time zone,
customer/invoice identifiers, and an active human-approved customer style-guidance revision.
Attachments, raw MIME, OAuth tokens, API keys, raw accounting payloads, and other accounts' data
are excluded.

The OpenAI Responses adapter and Anthropic Messages adapter each use the provider's native strict
JSON-schema output mode, one HTTP attempt per application attempt, no tools, and no hidden SDK
retry loop. PaymentReminder validates the normalized result again in Rails before a deterministic
shadow planner maps it to the existing action catalog. Sanitized request/response evidence,
provider/model versions, request IDs, usage, latency, and failure classifications are retained
without authorization secrets.

Provider output is evaluation evidence only. It creates no `ConversationAction`, sends no email,
changes no invoice or recipient, and does not affect reminders, holds, disputes, promises, or
escalations. A person may record correct/incorrect/unsure feedback. AI-proposed customer
communication preferences remain untrusted signals until a person edits and approves a bounded
style-only guidance revision. Approval mode, automatic execution, cross-customer learning,
attachments/vision, and daily summaries are not implemented.

### Create the Google OAuth application

1. Create or select a Google Cloud project.
2. Enable the Gmail API.
3. Configure the Google Auth Platform consent screen and audience.
4. Choose **Internal** only when the project and every sender are in the same controlled Google
   Workspace organization. Otherwise choose **External**.
5. While an External application is in Testing, add every connecting mailbox as a test user.
6. Create a **Web application** OAuth client.
7. Add the exact callback URI for every environment.

Local callback:

```text
http://localhost:3000/gmail/callback
```

Production callback:

```text
<HOST>/gmail/callback
```

Requested scopes:

```text
https://www.googleapis.com/auth/userinfo.email
https://www.googleapis.com/auth/userinfo.profile
https://www.googleapis.com/auth/gmail.send
https://www.googleapis.com/auth/gmail.readonly
```

An External Google OAuth app in Testing normally issues refresh tokens with a seven-day lifetime
when Gmail scopes are requested. That is useful for local testing but not reliable for automatic
reminders. For a long-running installation, move the OAuth application to Production and complete
Google's verification requirements when they apply.

Google references:

- [Gmail API scopes](https://developers.google.com/workspace/gmail/api/auth/scopes)
- [Synchronize a mail client](https://developers.google.com/workspace/gmail/api/guides/sync)
- [Gmail history.list](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.history/list)
- [Gmail threads](https://developers.google.com/workspace/gmail/api/guides/threads)
- [OAuth audiences and publishing status](https://support.google.com/cloud/answer/15549945?hl=en)
- [OAuth verification](https://support.google.com/cloud/answer/13463073?hl=en)

### Configure Rails

```bash
bin/rails credentials:edit
```

```yaml
google:
  client_id: your-google-oauth-client-id
  client_secret: your-google-oauth-client-secret
```

OAuth callback URLs must match exactly, including scheme, host, port, path, and trailing slash.
When changing the local port, open the app through that port and register its callback with Google:

```bash
HOST=http://localhost:3001 bin/rails server -p 3001 -P tmp/pids/server-3001.pid
```

### Connect and verify Gmail

1. Restart PaymentReminder after saving credentials.
2. Sign in and open **Settings** inside the account.
3. Select **Connect Gmail**, choose the sending mailbox, and approve access.
4. Select **Send test email**; it sends to the signed-in identity's email address.
5. Set the sender name and review the debtor thresholds and documented default reminder behavior.
6. Explicitly enable automatic invoice reminders.

The sender address must exactly match the connected Gmail address. OAuth tokens are encrypted at
rest and refreshed by the application. The mailbox cursor is opaque and is preserved across a
reconnection to the same Google identity; choosing another Google account starts a new seven-day
screening baseline. When Google access is revoked or an authentication refresh
fails, the Gmail connection enters an errored state and delivery pauses. Temporary rate limits,
server errors, and timeouts retry without marking the connection errored. The automatic-reminder
preference remains unchanged in the error case, so reconnecting the mailbox can resume delivery
without a separate re-enable step. Choosing **Disconnect Gmail** explicitly disables automatic
reminders. An explicit disconnect clears credentials, provider identity, and synchronization state.

### Gmail troubleshooting

- **`redirect_uri_mismatch`**: copy the callback from the environment into Google Cloud exactly.
- **Access blocked or denied**: enable the Gmail API, confirm the consent scopes, and add the sender
  as a test user while an External app remains in Testing.
- **Disconnects after seven days**: the OAuth app is probably External and still in Testing; move it
  to Production for long-lived refresh tokens.
- **Connection error**: use **Reconnect Gmail** after access is revoked, Google security settings
  change, or the refresh token expires.
- **Credentials missing**: confirm `google.client_id` and `google.client_secret` exist in the
  credentials for the running environment, then restart.

## System email

System email is installation-wide and separate from Gmail reminder delivery. Configure it for
production email-code signup/sign-in and internal reminder notifications; Gmail does not replace
it. An intentionally Xero-only installation with notifications disabled can boot and authenticate
without SMTP, but the email-code flows will not work.

The checked-in production configuration uses SMTP with Amazon SES-oriented defaults:

```text
address: email-smtp.us-east-1.amazonaws.com
port: 587
authentication: login
STARTTLS: enabled
```

Create dedicated SMTP credentials in the selected SES Region. SES SMTP credentials are
region-specific and are not normal AWS API access keys.

Store them in Rails credentials:

```yaml
ses:
  smtp_username: your-smtp-username
  smtp_password: your-smtp-password
```

Set the fork's public mail identity and endpoint with:

```text
MAILER_HOST=receivables.example.com
MAILER_PROTOCOL=https
MAILER_DOMAIN=example.com
MAILER_FROM_ADDRESS=PaymentReminder <support@example.com>
SES_SMTP_ADDRESS=email-smtp.us-east-1.amazonaws.com
SES_SMTP_PORT=587
```

The `ses` credential key is historical but is also where the checked-in SMTP adapter reads the
username and password when a compatible non-SES SMTP endpoint is selected. Review and test the
adapter before relying on another provider.

For SES production:

1. Verify a sending domain and enable DKIM.
2. Publish the provider's DNS records.
3. Leave the SES sandbox or verify every recipient used during testing.
4. Configure bounce and complaint handling and monitor sending reputation.
5. Send a real sign-in email and verify SPF, DKIM, and DMARC results.

Development does not need SMTP: Letter Opener captures application email locally, and the
verification screen shows the development code.

## Integration safety checklist

- Prefer isolated provider registrations and secrets for development and production when the
  provider supports that workflow.
- Register only callbacks and webhook destinations controlled by the installation.
- Grant only the documented Xero, Stripe, and Gmail permissions.
- Keep production `HOST` on HTTPS and match provider URLs exactly.
- Verify every webhook signature and keep live/test Stripe endpoints separate.
- Preserve the Rails master key and credential contents; together they make stored OAuth tokens
  decryptable.
- Test provider revocation, reconnect, a fresh invoice sync, a Gmail test message, and system email
  before inviting users.
- Run `bin/jobs` continuously in production.
- Never copy provider payloads, email content, customer data, or secrets into issues or logs.

Next: review [Self-hosting and operations](SELF_HOSTING.md) and configure the
[platform administrator](PLATFORM_ADMIN.md).
