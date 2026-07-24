# PaymentReminder configuration

This guide explains the settings a fork owns. Provider-specific registration steps are in
[Integrations](INTEGRATIONS.md), and production process/deployment settings are in
[Self-hosting and operations](SELF_HOSTING.md).

## Create credentials for a new fork

The repository commits `config/credentials.yml.enc`, but it intentionally does not commit the
matching `config/master.key`. That encrypted file belongs to the upstream installation and a new
fork cannot decrypt it.

After installing the bundle, replace it with credentials owned by your fork:

```bash
bundle install
git rm config/credentials.yml.enc
bin/rails credentials:edit
git add config/credentials.yml.enc
```

Rails creates a new `config/master.key` and a new encrypted credentials file. Commit the encrypted
file if the fork needs shared configuration, but never commit `config/master.key`. Store the master
key in a password manager or secrets system and provide it to production as `RAILS_MASTER_KEY`.

Back up the master key and preserve the credential values for the lifetime of the installation.
The master key decrypts the credentials; PaymentReminder's Active Record encryption keys are
derived through the application key generator from the `secret_key_base` inside those credentials.
Losing the master key makes the credentials unavailable, while recreating credentials with a new
`secret_key_base` makes saved Xero and Gmail OAuth tokens unreadable. A deliberate master-key
rotation must re-encrypt the same credential contents rather than regenerate them.

Contributors working on the upstream repository should obtain the existing master key through the
maintainer's approved secret-sharing process instead of replacing the shared encrypted file.

## Credentials shape

Only add the sections for features the installation uses. Never enter the example values literally.

```yaml
platform_admin:
  email_addresses:
    - operator@example.com

google:
  client_id: your-google-oauth-client-id
  client_secret: your-google-oauth-client-secret

xero:
  client_id: your-xero-client-id
  client_secret: your-xero-client-secret
  webhook_signing_key: your-xero-webhook-signing-key

stripe:
  app_id: your-stripe-app-id
  install_url: https://marketplace.stripe.com/apps/install/link/your-install-link
  signing_secrets:
    - absec_your-stripe-app-signing-secret
  secret_keys:
    live: sk_live_your-platform-key
    test: sk_test_your-platform-key
  webhook_signing_secrets:
    live:
      - whsec_your-live-webhook-secret
    test:
      - whsec_your-test-webhook-secret

ses:
  smtp_username: your-smtp-username
  smtp_password: your-smtp-password

sentry:
  dsn: https://your-sentry-dsn

# Used by the checked-in Kamal secret loader. Despite the historical name,
# config/database.yml passes this value as the paid_jar database user's password.
mysql_root_password: your-application-database-password
```

The Google OAuth application must enable the Gmail API and declare
`https://www.googleapis.com/auth/userinfo.email`,
`https://www.googleapis.com/auth/userinfo.profile`,
`https://www.googleapis.com/auth/gmail.send`, and
`https://www.googleapis.com/auth/gmail.readonly`. The restricted Gmail readonly scope may require
OAuth verification and a security assessment for hosted deployments that store Gmail data. See
[Integrations](INTEGRATIONS.md) for the exact behavior and Google references.

Keep overlapping Stripe App and webhook signing secrets in the relevant array during a rotation.
Remove an old secret only after Stripe has stopped using it.

## Environment variables

These are the production settings a self-hoster is most likely to change:

| Variable | Purpose | Default or requirement |
| --- | --- | --- |
| `RAILS_MASTER_KEY` | Decrypt Rails credentials; those credentials contain the key material used for record encryption | Required in production |
| `HOST` | Public application origin used for OAuth callbacks and provider links | Use the exact HTTPS origin |
| `DB_HOST` | MySQL server address | `127.0.0.1` in production |
| `MYSQL_ROOT_PASSWORD` | Password for the configured `paid_jar` database user | Required by the checked-in production DB config |
| `MAILER_HOST` | Default host for Action Mailer URL helpers; current templates do not emit app links | Upstream hosted domain |
| `MAILER_PROTOCOL` | Default scheme for Action Mailer URL helpers | `https` |
| `MAILER_DOMAIN` | SMTP HELO domain | Upstream hosted domain |
| `MAILER_FROM_ADDRESS` | Installation-wide From name and address | Upstream support address |
| `SES_SMTP_ADDRESS` | SMTP server | Amazon SES `us-east-1` endpoint |
| `SES_SMTP_PORT` | SMTP port | `587` |
| `PLATFORM_ADMIN_EMAIL_ADDRESSES` | Optional comma/space-separated global operator allowlist | Empty; combined with the credentials list when set |
| `SENTRY_DSN` | Enables Sentry error and job-monitor reporting | Disabled when absent |
| `SENTRY_TRACES_SAMPLE_RATE` | Sentry performance sample rate | `0.05` |
| `RAILS_LOG_LEVEL` | Production log verbosity | `info` |
| `RAILS_MAX_THREADS` | Web and database pool sizing input | App-specific defaults |
| `WEB_CONCURRENCY` | Puma worker count | `1` |
| `JOB_CONCURRENCY` | Solid Queue process count | `1` |
| `CONVERSATION_AI_PROVIDER` | Optional installation default AI provider (`openai` or `anthropic`); an account administrator still chooses and enables shadow mode | Empty |
| `OPENAI_API_KEY` | OpenAI server API key used only when OpenAI is selected | Required for configured OpenAI shadow analysis |
| `OPENAI_MODEL` | Explicit OpenAI model identifier; no “latest” model is hard-coded | Required with `OPENAI_API_KEY` |
| `ANTHROPIC_API_KEY` | Anthropic server API key used only when Anthropic is selected | Required for configured Anthropic shadow analysis |
| `ANTHROPIC_MODEL` | Explicit Anthropic model identifier; no “latest” model is hard-coded | Required with `ANTHROPIC_API_KEY` |

`DATABASE_URL` is the simplest development/test override for the narrow local defaults in
`config/database.yml`. The production configuration uses four named databases, so deployment
operators normally configure `DB_HOST` and the checked-in database role or adapt
`config/database.yml` deliberately instead of relying on one `DATABASE_URL`.

## AI shadow analysis

AI is off for every account by default. To make a provider available, set both its API key and
explicit model variable, restart the web and job processes, and then let an account administrator
choose that provider and enable **Shadow** in Settings. Missing keys or models fail closed.

Shadow analysis sends a bounded snapshot of one eligible inbound message to the selected provider:
the newly authored text and subject, limited delivery headers, a small recent-message excerpt,
bounded customer/invoice identity context, the account time zone, and the active human-approved
customer style-guidance revision when one exists. It does not send OAuth tokens, provider API keys,
raw MIME, attachments, account-user data, hidden BCC lists, or raw accounting-provider payloads.

Both adapters request strict JSON-schema output and expose no tools. API keys remain process
secrets and are never written to product records. PaymentReminder retains a bounded, sanitized
request envelope, structured response, usage, provider request ID, latency, and failure category
for audit and evaluation; authorization headers are excluded.

This release is shadow only. It cannot send a message, create or approve a deterministic action,
alter an invoice, place a hold, add a recipient, or otherwise execute provider output. Customer
style guidance becomes active only after a person reviews and approves or authors a bounded
revision. Approval mode, automatic execution, and daily summaries are not implemented.

## Public host and callback URLs

Set `HOST` to the application origin without a trailing slash:

```text
https://receivables.example.com
```

Register these routes under that public origin:

| Purpose | Path |
| --- | --- |
| Gmail OAuth callback | `<HOST>/gmail/callback` |
| Xero connection callback | `<HOST>/xero/callback` |
| Xero signup callback | `<HOST>/signup/xero/callback` |
| Xero sign-in callback | `<HOST>/session/xero/callback` |
| Xero webhook | `<HOST>/invoice_sources/webhooks/xero` |
| Stripe App callback | `<HOST>/stripe/callback` |
| Stripe onboarding claims | `<HOST>/stripe/app/onboarding_claims` |
| Stripe live webhook | `<HOST>/invoice_sources/webhooks/stripe` |
| Stripe test webhook | `<HOST>/invoice_sources/webhooks/stripe/test` |

`HOST` directly drives the Xero and Stripe redirect/onboarding URLs. The Gmail callback URL is
generated from the public request host, so the proxy and `HOST` should present the same origin.
Webhook destinations are fixed application routes that the operator registers with the providers.
Provider dashboards compare callback URLs exactly: scheme, host, port, path, and trailing slash
must match.

## What belongs where

- Store OAuth client secrets, webhook signing keys, SMTP credentials, Stripe secret keys, AI API
  keys, Sentry DSNs, and the platform-admin allowlist in encrypted credentials or the deployment's
  secret manager.
- Store public origins, ports, log levels, concurrency, and public mail identity in environment
  variables.
- Never put provider secrets in `stripe-app/`, client-side JavaScript, Docker images, issues, logs,
  or screenshots.
- Do not copy the upstream hosted service's encrypted credentials, Stripe App secrets, provider
  registrations, domains, or deployment hosts into a fork.

Next: configure [Xero, Stripe, Gmail, and system email](INTEGRATIONS.md), then review
[self-hosting and operations](SELF_HOSTING.md).
