# PaymentReminder

Self-hosted accounts receivable for freelancers and small teams.

PaymentReminder connects to Xero or Stripe, turns imported invoices into a prioritized
receivables list, sends scheduled reminders from each account's own Gmail address, and imports
relevant customer replies and messages sent manually from that mailbox. A
separate platform-admin console gives the person operating the installation a view across every
account.

![PaymentReminder receivables list](docs/ui-north-star/after-home-inbox.png)

PaymentReminder is working, early-stage software. Invoice sync, outbound reminders, screened Gmail
ingestion, and an account-user conversation Inbox with human review and threaded manual replies are
implemented. Optional OpenAI or Anthropic analysis can interpret eligible messages in shadow mode
for human evaluation; it cannot send, approve, or execute anything. See the
[capability audit](docs/CAPABILITY_AUDIT.md) for the exact current boundary.

## What it does

- Creates isolated accounts with email-code authentication or Xero sign-in.
- Imports invoices from Xero or Stripe and builds local customers from the contact details embedded
  in those invoices, without writing accounting records or moving money.
- Prioritizes receivables and rates customers as Good, Normal, or Bad debtors from completed
  payment history.
- Lets account owners and admins manage reminder recipients, debtor thresholds, Gmail delivery,
  and sender identity; each user controls their own notification preferences.
- Schedules debtor-specific reminders before and after an invoice is due, with durable delivery
  history, idempotency, retries, and fresh provider checks before sending.
- Polls Gmail about every 15 minutes, imports relevant inbound replies and manually sent mail, and
  places unmatched or ambiguous relevant messages in a human-review Inbox without changing Gmail
  labels or read state.
- Lets account users review or manually match imported conversations and send a verified, threaded
  Gmail reply from the connected account.
- Lets an account administrator opt into provider-configured AI shadow analysis. Structured
  interpretations, deterministic shadow plans, human evaluations, and human-approved
  customer-specific style guidance remain audit evidence only.
- Tracks payment promises and follow-ups in the domain; platform administrators can operate that
  flow while the customer-facing capture UI is still to be built.
- Supports multiple accounts and users while keeping every normal application request scoped to
  the selected account.
- Gives the installation operator a protected Madmin console for all accounts, users, providers,
  invoices, reminders, promises, and failures, with a dedicated ledger for Madmin mutations.

Not yet exposed to ordinary users: team invitations and role management, account switching,
one-off reminders, payment-promise capture, customer and invoice detail pages, search, AI-generated
reply sending, AI approval mode, or automated reply actions. These boundaries are documented as latent or not built—not
presented as shipped features.

## Run it locally

### Requirements

- Ruby 3.4.5
- MySQL 8
- Bundler
- A modern browser

Node.js 22 and the Stripe CLI are only needed when changing or uploading the Stripe App package.
Google, Xero, Stripe, SES, and Sentry credentials are optional for basic local development.

### Setup

Fork the repository on GitHub, then clone your fork:

```bash
git clone https://github.com/YOUR_GITHUB_USERNAME/payment_reminder.git
cd payment_reminder
bin/setup --skip-server
```

`bin/setup` installs the gems, prepares the database, and clears old temporary files. Without
`--skip-server`, it starts `bin/dev` for you.

The default development database connection expects MySQL's `/tmp/mysql.sock`, a `root` user,
and no password. Use `DATABASE_URL` when your MySQL installation differs:

```bash
DATABASE_URL=mysql2://root:password@127.0.0.1:3306/paid_jar_development \
  bin/setup --skip-server
```

Prefix `bin/dev` with the same development URL when starting the server. Do not export that URL
globally: Rails tests need a separate disposable test database.

Before starting a permanent fork or adding provider secrets, replace the upstream encrypted
credentials with a set owned by your fork. Contributors to the upstream installation should skip
this replacement and obtain its existing key through the maintainer instead.

```bash
git rm config/credentials.yml.enc
bin/rails credentials:edit
git add config/credentials.yml.enc
```

Never commit the generated `config/master.key`; back it up securely. The
[configuration guide](docs/CONFIGURATION.md) explains this one-time fork step and every supported
setting.

Start the app:

```bash
bin/dev
```

When using the database override above, start it with:

```bash
DATABASE_URL=mysql2://root:password@127.0.0.1:3306/paid_jar_development bin/dev
```

Open [http://localhost:3000/signup/new](http://localhost:3000/signup/new). The bare root currently
redirects signed-out visitors to the upstream marketing site until a fork changes that branding
behavior.

In development, the verification screen displays the six-character code and Letter Opener captures
sign-in email locally instead of sending it. Create an account, enter the code, and finish the owner
profile.

Read the [development guide](docs/DEVELOPMENT.md) for database troubleshooting, background-job
behavior, the full test suite, Stripe App development, and an optional coding-agent setup prompt.

## Use the app

1. Create an account with email, or configure Xero and use Xero signup.
2. Open **Settings** in the account-scoped workspace.
3. Connect Xero or install the Stripe App, then select **Resync** for the invoice source.
4. Review imported receivables and add any extra reminder recipients.
5. Connect Gmail, send the built-in test email, and choose the sender name.
6. Review debtor thresholds, then explicitly enable the default automatic reminder sequences.
7. In production, keep the Solid Queue worker running so syncs, webhooks, reminders, promise
   follow-ups, and recurring maintenance are processed.

The receivables list starts empty: this repository does not ship demo invoices or seed customer
data. Connect Xero or Stripe to populate it.

Each account lives under a generated numeric path such as `/1`. Authorization still verifies the
signed-in user's membership in that exact account; the path itself is not an access control.
Account owners and admins can change account-wide settings, while members can view account data and
manage their own notification preferences. Team management and an account switcher are not yet
available in the regular UI.

## Run your own instance

PaymentReminder is a Rails application, not a single self-contained appliance. A production
installation needs:

- the web process;
- a separate `bin/jobs` Solid Queue process;
- MySQL 8 for the primary, cache, queue, and cable databases;
- stable Rails credentials and `RAILS_MASTER_KEY`;
- HTTPS and a correct public `HOST`;
- SMTP delivery when using email-code authentication or account notifications;
- optional Xero, Stripe, and Google applications for their respective features.

The repository includes a production Dockerfile and Kamal configuration. The checked-in
`config/deploy.yml`, hosted domains, image registry, server addresses, and Stripe manifest belong
to the upstream installation: replace them before running any deployment command from a fork.

Start with the [self-hosting and operations guide](docs/SELF_HOSTING.md). It covers the fork
checklist, required processes, Docker and Kamal, databases, secrets, upgrades, backups, health
checks, and monitoring. The [going-live checklist](docs/GOING_LIVE_CHECKLIST.md) records the
upstream hosted service's provider work; use it as a review aid, not as copy-paste configuration
for another domain.

## Configure integrations

All provider integrations are optional independently, but they unlock different parts of the
product:

| Integration | Purpose | Required for |
| --- | --- | --- |
| Xero | Read invoices and their embedded customer details; receive invoice webhooks | Xero-backed receivables |
| Stripe App | Read invoices; consume connected-account events for supported public Apps | Stripe-backed receivables |
| Gmail / Google Workspace | Send reminders and screen relevant mailbox activity with `gmail.send` and `gmail.readonly` | Customer reminders and screened Gmail import |
| SMTP / Amazon SES | Send installation-wide application email | Email-code authentication and notifications |
| OpenAI or Anthropic | Strict structured interpretation in opt-in shadow mode | Optional AI evaluation |
| Sentry | Report application failures and recurring-job check-ins | Optional monitoring |

Create credentials owned by your fork, set the public host, and then register matching callback
and webhook URLs with each provider. Use these guides:

- [Configuration and secrets](docs/CONFIGURATION.md)
- [Xero, Stripe, Gmail, and system email](docs/INTEGRATIONS.md)
- [Production operations and Sentry](docs/SELF_HOSTING.md)

Provider secrets from the official hosted service are never distributed with the source.

## Platform administrator

The global admin is designed for the app developer or hosted-service operator. It is separate from
an account's `owner` or `admin` role and is mounted at the unscoped `/madmin` path.

An allowlisted platform administrator can see every account, the users and identities under those
accounts, customers, invoices, source connections, reminder history, payment promises, webhooks,
sessions, failures, and other operational records. The console also provides explicit actions to
impersonate an active user, manage access and roles, refresh sources and debtor ratings, run an
account's reminder scheduler, send a one-off reminder, operate payment promises, disconnect
providers, retry webhook processing, and revoke sessions or sign-in codes.
Terminally failed Gmail screening receipts can also be inspected and explicitly requeued without
exposing generic edit or delete controls.

High-risk provider-owned records do not get unrestricted raw edit/delete controls, and platform
admin access cannot bypass Xero, Stripe, or Google consent. Secrets and sensitive token material
are omitted from the panel. Operator mutation requests that finish through the panel's normal
redirect flow are written to an admin event ledger.

See [Platform administration](docs/PLATFORM_ADMIN.md) for setup, the complete action list, safety
boundaries, and the exact distinction between a platform operator and an account owner.

## Documentation

- [Development](docs/DEVELOPMENT.md)—local setup, first run, tests, and Stripe App development.
- [Configuration](docs/CONFIGURATION.md)—new-fork credentials, supported settings, and secrets.
- [Integrations](docs/INTEGRATIONS.md)—Xero, Stripe, Gmail, system email, callbacks, and webhooks.
- [Self-hosting and operations](docs/SELF_HOSTING.md)—Docker, Kamal, jobs, backups, upgrades, and
  monitoring.
- [Platform administration](docs/PLATFORM_ADMIN.md)—global visibility, support actions, and audit
  controls.
- [Capability audit](docs/CAPABILITY_AUDIT.md)—all available, latent, and not-built behavior plus
  the verified runtime dependencies.
- [Going-live checklist](docs/GOING_LIVE_CHECKLIST.md)—external launch work for the official hosted
  installation.
- [Security policy](SECURITY.md)—supported versions and private vulnerability reporting.
- [Contributing](CONTRIBUTING.md)—development workflow and pull-request checks.

## Technology

PaymentReminder uses Ruby 3.4.5, Rails 8.1, MySQL 8, Hotwire, Importmap, Propshaft, Solid Cache,
Solid Queue, Solid Cable, Puma, Thruster, Madmin, Minitest, Capybara, Selenium, Docker, and Kamal.
It intentionally does not require Redis or a JavaScript build step for the Rails application.

## Contributing

Issues and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) and keep the
project's tenant boundaries, provider permissions, delivery idempotency, and user-facing feature
claims intact. Never include credentials, customer data, or provider payloads in an issue or test
fixture. Report suspected vulnerabilities privately through [SECURITY.md](SECURITY.md), not in a
public issue.

## License

PaymentReminder is open-source software licensed under the [GNU Affero General Public License
v3.0](LICENSE). If you modify and operate it as a network service, review the license before
launching your fork.
