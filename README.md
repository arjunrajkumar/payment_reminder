# PaymentReminder

AI accounts-receivable inbox that gets freelancers and small teams paid faster — run by you or your agent.

## Tech Stack

- Ruby 3.4.5
- Rails 8.1.3
- MySQL 8
- Hotwire: Turbo and Stimulus
- Importmap for JavaScript
- Propshaft for assets
- Solid Cache, Solid Queue, and Solid Cable
- Puma web server
- Kamal and Docker for deployment
- Minitest, Capybara, and Selenium for testing

## Development

This app uses Ruby 3.4.5 and Rails 8.1.3.

```bash
bin/setup
bin/rails db:prepare
bin/rails server
```

## AI-assisted setup

If you use a local coding agent like Codex or Claude Code, you can clone this repo, open the folder in the agent, and paste this:

```text
Please set up PaymentReminder locally.

1. Read README.md and AGENTS.md first.
2. Make sure Ruby 3.4.5 is active. If the system Ruby is used by mistake, switch to the project Ruby with mise, asdf, rbenv, or the local tool available on this machine.
3. Run bin/setup.
4. Run bin/rails db:prepare.
5. Run bin/rails test and tell me whether it passes.
6. If I want Xero connected, help me configure Rails credentials with:

   xero:
     client_id: my-xero-client-id
     client_secret: my-xero-client-secret
     webhook_signing_key: my-xero-webhook-signing-key

   If I want Stripe connected, help me configure Rails credentials with:

   stripe:
     client_id: my-stripe-connect-client-id
     secret_key: my-stripe-secret-key
     webhook_signing_secret: whsec_my-stripe-webhook-secret

   If I want Gmail delivery for invoice reminders, follow the Gmail section in this README and help me configure Rails credentials with:

   google:
     client_id: my-google-oauth-client-id
     client_secret: my-google-oauth-client-secret

   Do not ask me to paste secrets into chat. Open the credentials editor and wait while I type them locally.
7. Start the app with bin/rails server and tell me the localhost URL.
```

This gives the agent enough context to install dependencies, prepare the database, verify the app, and guide credential setup without requiring a long manual checklist.

## Production launch

Before opening the hosted service to customers, complete the [external going-live checklist](docs/GOING_LIVE_CHECKLIST.md) for DNS, Amazon SES, Google OAuth verification, Xero, Stripe, backups, and monitoring.

## Error and scheduled-job monitoring

PaymentReminder supports optional [Sentry for Rails](https://docs.sentry.io/platforms/ruby/guides/rails/). Set `SENTRY_DSN` in the production runtime to enable exception reporting. No events are sent when the variable is absent.

The official Kamal deployment reads the DSN from encrypted Rails credentials. Add it with `bin/rails credentials:edit`:

```yaml
sentry:
  dsn: https://your-sentry-dsn
```

Self-hosters using another deployment system can inject `SENTRY_DSN` directly. `SENTRY_TRACES_SAMPLE_RATE` controls performance sampling and defaults to `0.05`. Default PII collection is disabled; do not add OAuth tokens, email contents, or customer financial data to Sentry context.

The Solid Queue worker reports expected-schedule check-ins for these critical recurring jobs:

- `schedule-invoice-reminders`: every hour, with a 10-minute check-in grace period and a 30-minute maximum runtime.
- `refresh-invoice-sources`: every six hours, with a 15-minute check-in grace period and a 15-minute maximum runtime.

Sentry creates or updates these cron monitors when the jobs first run. Configure Sentry alerts for missed and failed check-ins as well as application issues. These monitors require the production Solid Queue process (`bin/jobs`) to be running; the Rails `/up` endpoint only checks the web process.

## Xero

Create a Xero OAuth 2.0 app and register all three redirect URIs:

```text
http://localhost:3000/xero/callback
http://localhost:3000/signup/xero/callback
http://localhost:3000/session/xero/callback
```

Then edit Rails credentials:

```bash
bin/rails credentials:edit
```

Add:

```yaml
xero:
  client_id: your-client-id
  client_secret: your-client-secret
  webhook_signing_key: your-webhook-signing-key
```

OAuth callback URLs are derived from `HOST`, which defaults to `http://localhost:3000` in development. Register `<HOST>/xero/callback`, `<HOST>/signup/xero/callback`, and `<HOST>/session/xero/callback` in Xero. For example, start a second local server with:

```bash
HOST=http://localhost:3001 bin/rails server -p 3001 -P tmp/pids/server-3001.pid
```

For local webhook testing, expose your local app with a tunnel and configure the Xero webhook delivery URL to:

```text
https://your-tunnel.example/invoice_sources/webhooks/xero
```

## Stripe

PaymentReminder is a Stripe Connect **Extension**: it connects to an existing Standard Stripe account and reads invoice information without creating accounts, moving money, or modifying Stripe data. Register the Connect integration as an Extension and use OAuth with the `read_only` scope. If the Connect application is currently classified as a Platform, contact Stripe to change its integration type before launch.

In Stripe Connect settings, enable OAuth for Standard accounts and configure the redirect URI:

```text
http://localhost:3000/stripe/callback
```

For production, register the public HTTPS callback instead, for example:

```text
https://payment-reminder.example/stripe/callback
```

Then edit Rails credentials:

```bash
bin/rails credentials:edit
```

Add:

```yaml
stripe:
  client_id: your-connect-client-id
  secret_key: your-stripe-secret-key
  webhook_signing_secret: whsec_your-webhook-secret
```

The client ID and secret key must belong to the same Stripe mode: use sandbox values together or live values together. PaymentReminder uses the connected account ID returned by OAuth with the platform secret key and a `Stripe-Account` header; the deprecated OAuth access token is not used for invoice API requests.

In **Workbench → Webhooks**, create an event destination that listens to **Connected accounts**, not events on the PaymentReminder Stripe account. Set its endpoint to `<HOST>/invoice_sources/webhooks/stripe` and select:

- `invoice.created`
- `invoice.updated`
- `invoice.finalized`
- `invoice.paid`
- `invoice.voided`
- `invoice.marked_uncollectible`
- `account.application.deauthorized`

Reveal that destination's signing secret and store it as `stripe.webhook_signing_secret`. Sandbox, live, and Stripe CLI destinations each have different signing secrets.

For a signing-secret rotation, configure both secrets temporarily:

```yaml
stripe:
  webhook_signing_secrets:
    - whsec_old
    - whsec_new
```

For local webhook testing with the Stripe CLI:

```bash
stripe listen \
  --events invoice.created,invoice.updated,invoice.finalized,invoice.paid,invoice.voided,invoice.marked_uncollectible,account.application.deauthorized \
  --forward-connect-to localhost:3000/invoice_sources/webhooks/stripe
```

Use the `whsec_...` value printed by that command only for local CLI testing. After credentials are configured, sign in and open `/account/settings` to connect Xero or Stripe. See [Stripe OAuth for Standard accounts](https://docs.stripe.com/connect/oauth-standard-accounts), [Connect webhooks](https://docs.stripe.com/connect/webhooks), and [Stripe currencies](https://docs.stripe.com/currencies).

## System email

PaymentReminder uses installation-wide system email for sign-in codes and internal notifications. This is separate from account-owned Gmail delivery, which is only used to send invoice reminders to customers.

The official hosted installation uses [Amazon Simple Email Service (SES)](https://aws.amazon.com/ses/) with these defaults:

- AWS Region: `us-east-1`
- Sending domain: `paymentreminderemails.com`
- From address: `PaymentReminder <support@paymentreminderemails.com>`
- Application link host: `app.paymentreminderemails.com`

To configure Amazon SES for production:

1. Open Amazon SES in the `us-east-1` Region and create a domain identity for `paymentreminderemails.com`.
2. Enable Easy DKIM and publish the DNS records supplied by SES. Cloudflare users must set CNAME records to **DNS only**.
3. Request production access if the SES account is still in the sandbox. While sandboxed, SES can only send to verified recipient addresses.
4. From **SMTP settings**, create dedicated SMTP credentials for PaymentReminder. SES SMTP credentials are Region-specific and are not the same as regular AWS access keys.
5. Open the Rails credentials editor:

```bash
bin/rails credentials:edit
```

6. Add the dedicated SES SMTP credentials. Do not use regular AWS access keys:

```yaml
ses:
  smtp_username: your-ses-smtp-username
  smtp_password: your-ses-smtp-password
```

The application reads these values directly from encrypted Rails credentials when it generates a system email. Kamal only supplies `RAILS_MASTER_KEY` to the running containers, as it already does for the application's other encrypted credentials.

Self-hosters can override `MAILER_HOST`, `MAILER_PROTOCOL`, `MAILER_DOMAIN`, `MAILER_FROM_ADDRESS`, `SES_SMTP_ADDRESS`, and `SES_SMTP_PORT`. The default SES endpoint is `email-smtp.us-east-1.amazonaws.com` on port `587` with STARTTLS.

## Gmail reminder delivery

PaymentReminder can send customer invoice reminders from a Gmail or Google Workspace account owned by each PaymentReminder account. The connected address becomes the reminder `From` address; the sender name can be customized in Settings.

When upgrading an existing installation, apply the database changes first:

```bash
bin/rails db:migrate
```

The migration disables existing automatic reminders. Connect Gmail, send a test email, and then explicitly enable automatic reminders again so invoices are not sent from an unverified address.

### 1. Create the Google OAuth application

1. Create or select a project in the [Google Cloud Console](https://console.cloud.google.com/).
2. Enable the [Gmail API](https://console.cloud.google.com/apis/library/gmail.googleapis.com).
3. Configure the Google Auth Platform consent screen and audience:
   - Choose **Internal** if the Google Cloud project and every sender belong to the same Google Workspace organization.
   - Choose **External** for personal Gmail accounts or senders from different organizations. While the app is in Testing, add every Gmail account that will connect as a test user.
4. Create an OAuth client with the **Web application** application type.
5. Add the exact callback URL for every environment under **Authorized redirect URIs**.

For local development, the callback is:

```text
http://localhost:3000/gmail/callback
```

For a production installation, replace the domain with the public HTTPS URL:

```text
https://payment-reminder.example/gmail/callback
```

PaymentReminder requests these scopes during connection:

- `email`
- `profile`
- `https://www.googleapis.com/auth/gmail.send`

The `gmail.send` scope is only used to send invoice reminders. It does not grant PaymentReminder access to read the connected mailbox.

> [!IMPORTANT]
> Google OAuth apps with an External audience and Testing status issue refresh tokens that expire after seven days when Gmail scopes are requested. That is useful for local testing, but not reliable for automatic reminders. For a long-running installation, publish the OAuth app to Production and complete Google's verification requirements if they apply to your audience.

See Google's documentation for [OAuth app audiences and publishing status](https://support.google.com/cloud/answer/15549945?hl=en) and [OAuth verification](https://support.google.com/cloud/answer/13463073?hl=en).

### 2. Add the Google credentials

Open the Rails credentials editor:

```bash
bin/rails credentials:edit
```

Add the OAuth client credentials:

```yaml
google:
  client_id: your-google-client-id
  client_secret: your-google-client-secret
```

Do not commit decrypted credentials or share them in an issue. Preserve the Rails master key when backing up or moving an installation; it is required to decrypt saved OAuth tokens.

OAuth callback URLs are generated as `<HOST>/gmail/callback`. `HOST` defaults to `http://localhost:3000` in development and must exactly match an authorized redirect URI in Google Cloud, including its scheme, host, port, path, and trailing slash behavior. For example, to use port 3001:

```bash
HOST=http://localhost:3001 bin/rails server -p 3001 -P tmp/pids/server-3001.pid
```

### 3. Connect and verify Gmail

1. Start or restart PaymentReminder after saving the credentials.
2. Sign in and open **Settings** (`/account/settings`).
3. Select **Connect Gmail**, choose the address that should send reminders, and approve access.
4. Select **Send test email** to verify delivery to the signed-in user's email address.
5. Set the sender name, enable automatic invoice reminders, and save the reminder settings.

Each PaymentReminder account has its own Gmail connection. Access and refresh tokens are encrypted at rest, and background jobs refresh access automatically. If Google access is revoked or can no longer be refreshed, automatic reminders are disabled until an account owner reconnects Gmail.

Production installations must run the Solid Queue worker so scheduled reminders are processed:

```bash
bin/jobs
```

### Troubleshooting

- **`redirect_uri_mismatch`**: Copy the callback generated from `HOST` into Google Cloud exactly. A different scheme, port, path, or trailing slash is a different URI to Google.
- **Access blocked or denied**: For an External app in Testing, add the connecting Gmail address as a test user. Also confirm that the Gmail API is enabled and the consent screen includes the requested scopes.
- **Gmail disconnects after seven days**: The Google OAuth app is likely External and still in Testing. Publish it to Production for long-lived refresh tokens.
- **Connection shows an error**: Use **Reconnect Gmail** in Settings. This is normally required after the user revokes access, changes relevant Google security settings, or the refresh token expires.
- **Google credentials are missing**: Confirm that `google.client_id` and `google.client_secret` exist in the Rails credentials for the environment running the app, then restart it.

Connected Gmail is only used for customer invoice reminders. Sign-in links and internal notifications continue to use the installation-wide Action Mailer configuration, which production installations must configure separately.

## License

PaymentReminder is licensed under the GNU Affero General Public License v3.0. See [LICENSE](LICENSE).
