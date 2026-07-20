# PaymentReminder external going-live checklist

Last reviewed: 18 July 2026

This checklist covers work that must be completed outside the PaymentReminder repository before the hosted service is opened to customers. It focuses on provider dashboards, DNS, public policies, credentials, webhooks, backups, and monitoring.

Do not paste credentials, verification tokens, webhook secrets, or the Rails master key into this document, an issue, or chat.

## Production values

Use these exact production URLs when a provider asks for them:

| Purpose | Production value |
| --- | --- |
| Marketing homepage | `https://www.paymentreminderemails.com` |
| Application | `https://app.paymentreminderemails.com` |
| Privacy policy | `https://app.paymentreminderemails.com/privacy` |
| Terms of service | `https://app.paymentreminderemails.com/terms` |
| Gmail OAuth callback | `https://app.paymentreminderemails.com/gmail/callback` |
| Xero OAuth callback | `https://app.paymentreminderemails.com/xero/callback` |
| Xero signup callback | `https://app.paymentreminderemails.com/signup/xero/callback` |
| Xero sign-in callback | `https://app.paymentreminderemails.com/session/xero/callback` |
| Xero webhook | `https://app.paymentreminderemails.com/invoice_sources/webhooks/xero` |
| Stripe OAuth callback | `https://app.paymentreminderemails.com/stripe/callback` |
| Stripe Connect webhook | `https://app.paymentreminderemails.com/invoice_sources/webhooks/stripe` |
| System-email sender | `PaymentReminder <support@paymentreminderemails.com>` |
| Amazon SES Region | `us-east-1` |

`HOST` must remain `https://app.paymentreminderemails.com` in production because the application derives provider callback URLs from it.

## 1. Domain, DNS, and public pages

- [ ] Confirm `www.paymentreminderemails.com` serves the marketing homepage over HTTPS.
- [ ] Confirm `app.paymentreminderemails.com` serves the Rails application over HTTPS.
- [ ] Confirm Cloudflare's SSL/TLS mode matches the origin configuration. Prefer **Full (strict)** after origin HTTPS and a valid origin certificate are configured; do not switch modes until the origin is ready.
- [ ] Confirm `https://app.paymentreminderemails.com/up` returns a successful response.
- [ ] Make `support@paymentreminderemails.com` a real, monitored mailbox or forwarder.
- [ ] Publish the privacy policy and terms at the exact URLs in the table above.
- [ ] Ensure the policies and homepage are accessible without signing in.
- [ ] Link the privacy policy and terms from the marketing homepage and the application.
- [ ] Ensure the homepage clearly explains that PaymentReminder connects to Gmail only to send reminders and connects to Xero or Stripe to import invoice information.
- [ ] Confirm the operator name, support address, data practices, and deletion/contact instructions in the policies are accurate.
- [ ] Have the policies reviewed for the jurisdictions in which the service will be offered.
- [ ] Review existing SPF and DMARC records before adding email-provider DNS records. A domain must have no more than one SPF TXT record.

Keep provider verification records in DNS after approval. Removing a Search Console or DKIM record can cause ownership or email authentication to be lost later.

## 2. Amazon SES system email

PaymentReminder uses SES only for application email such as sign-in codes and internal notifications. Customer invoice reminders continue to use each account's connected Gmail address.

### SES account and sending identity

- [ ] Sign in to the intended production AWS account with MFA enabled.
- [ ] Select the `us-east-1` Region in Amazon SES.
- [ ] Create a domain identity for `paymentreminderemails.com`.
- [ ] Enable Easy DKIM.
- [ ] Publish all three SES DKIM CNAME records in DNS. In Cloudflare, make them **DNS only**, not proxied.
- [ ] Wait until the SES identity and DKIM status both show verified/successful.
- [ ] Request SES production access and describe the use case as user-requested transactional authentication and account-notification email.
- [ ] Confirm the account is out of the SES sandbox before testing with arbitrary recipient addresses.
- [ ] Check the approved daily sending quota and maximum send rate.

AWS documentation: [create and verify an identity](https://docs.aws.amazon.com/ses/latest/dg/creating-identities.html), [manage Easy DKIM](https://docs.aws.amazon.com/ses/latest/dg/send-email-authentication-dkim-easy-managing.html), and [request production access](https://docs.aws.amazon.com/ses/latest/dg/request-production-access.html).

### SES SMTP credentials

- [ ] In **SES → SMTP settings**, create dedicated SMTP credentials for PaymentReminder.
- [ ] Do not reuse the Inventory History SMTP credentials or normal AWS access keys.
- [ ] Add the generated values using `bin/rails credentials:edit`:

```yaml
ses:
  smtp_username: your-region-specific-smtp-username
  smtp_password: your-region-specific-smtp-password
```

- [ ] Store a recoverable copy in the approved password manager.
- [ ] Test a real sign-in email after deployment.
- [ ] Inspect the received message headers and confirm DKIM and DMARC pass.

SES SMTP credentials are Region-specific and the SMTP password is not an AWS secret access key. See [Obtaining Amazon SES SMTP credentials](https://docs.aws.amazon.com/ses/latest/dg/smtp-credentials.html).

### SES reputation and alerts

- [ ] Enable the account-level suppression list for both bounces and complaints.
- [ ] Configure bounce and complaint notifications through SNS, event publishing, or feedback forwarding.
- [ ] Create CloudWatch alarms for bounce rate, complaint rate, rejects, and sending failures.
- [ ] Confirm AWS account and operational notification emails are monitored.
- [ ] Add an AWS Budget alert so unexpected usage is visible.
- [ ] Decide whether to configure a custom MAIL FROM subdomain such as `bounce.paymentreminderemails.com`. If enabled, publish the exact MX and SPF records supplied by SES.

AWS requires senders to monitor bounces and complaints. See [monitoring SES sending activity](https://docs.aws.amazon.com/ses/latest/dg/monitor-sending-activity.html), [SES notifications](https://docs.aws.amazon.com/ses/latest/dg/monitor-sending-activity-using-notifications-sns.html), and [custom MAIL FROM domains](https://docs.aws.amazon.com/ses/latest/dg/mail-from.html).

## 3. Google Search Console and Gmail OAuth

Google Search Console does not configure Gmail. It proves ownership of `paymentreminderemails.com` for the Google Cloud OAuth verification process.

### Verify the domain in Search Console

- [ ] Use a Google account that is also an **Owner or Editor** of the Google Cloud project.
- [ ] In [Google Search Console](https://search.google.com/search-console), add a **Domain property** for `paymentreminderemails.com` without `https://` or `www`.
- [ ] Publish the Search Console DNS TXT record.
- [ ] Complete ownership verification and keep the DNS record published.

Google requires an owner/editor of the Cloud project to verify every OAuth authorized domain. See [Google's OAuth domain verification requirements](https://support.google.com/cloud/answer/13464321?hl=en) and [Search Console domain properties](https://support.google.com/webmasters/answer/34592?hl=en).

### Configure the Google Cloud project

- [ ] Create or select the production Google Cloud project.
- [ ] Keep project owner, editor, support, and developer-contact email addresses current.
- [ ] Enable the Gmail API.
- [ ] In **Google Auth Platform → Branding**, configure:
  - App name: `PaymentReminder`
  - User support email: the monitored support address
  - Homepage: `https://www.paymentreminderemails.com`
  - Privacy policy: `https://app.paymentreminderemails.com/privacy`
  - Terms of service: `https://app.paymentreminderemails.com/terms`
  - Authorized domain: `paymentreminderemails.com`
- [ ] Confirm the homepage describes the product and links to the same privacy policy submitted to Google.
- [ ] Select an **External** audience unless every connecting sender belongs to one Google Workspace organization controlled by this project.
- [ ] While testing, add only the necessary test users.
- [ ] Create a **Web application** OAuth client.
- [ ] Add this exact authorized redirect URI: `https://app.paymentreminderemails.com/gmail/callback`.
- [ ] Under **Data Access**, declare only the scopes used by the application:
  - `email`
  - `profile`
  - `https://www.googleapis.com/auth/gmail.send`
- [ ] Add the production client ID and client secret using `bin/rails credentials:edit`:

```yaml
google:
  client_id: your-production-google-client-id
  client_secret: your-production-google-client-secret
```

The `gmail.send` scope is classified as sensitive, not restricted. It allows sending but does not allow PaymentReminder to read the mailbox. See [Gmail API scopes](https://developers.google.com/workspace/gmail/api/auth/scopes).

### Submit OAuth verification

- [ ] Move the OAuth app toward **In production** rather than relying on Testing status for real users.
- [ ] Prepare a concise scope justification explaining that `gmail.send` sends invoice reminders chosen and configured by the account owner.
- [ ] Record the complete authorization flow, including the consent screen, Gmail connection, test email, sender shown in settings, and disconnect flow.
- [ ] Provide reviewer access and test instructions that do not require private verbal coordination.
- [ ] Confirm the privacy policy explains how Google user data is accessed, used, stored, protected, and deleted.
- [ ] Submit sensitive-scope verification in the Google Cloud Verification Center.
- [ ] Resolve every branding, domain, scope, or policy finding.
- [ ] Do not invite public users until the production OAuth consent screen is approved and no unverified-app warning appears.

Google's current requirements are documented in [OAuth app branding](https://support.google.com/cloud/answer/15549049?hl=en), [sensitive-scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification), and [app homepage requirements](https://support.google.com/cloud/answer/13807376?hl=en).

### Gmail production smoke test

- [ ] Connect a Gmail or Google Workspace account that is not the Cloud project owner.
- [ ] Confirm the callback returns to PaymentReminder without `redirect_uri_mismatch`.
- [ ] Send the built-in Gmail test email and confirm its visible From address.
- [ ] Disconnect Gmail in PaymentReminder and confirm automation is disabled.
- [ ] Reconnect and confirm automatic reminders remain off until explicitly enabled.

## 4. Xero developer setup

### Create and configure the Xero app

- [ ] Sign in to the [Xero Developer portal](https://developer.xero.com/app/manage).
- [ ] Create or open the production PaymentReminder OAuth 2.0 app using the authorization-code flow.
- [ ] Set the application/company URL to `https://www.paymentreminderemails.com`.
- [ ] Register `https://app.paymentreminderemails.com/xero/callback`, `https://app.paymentreminderemails.com/signup/xero/callback`, and `https://app.paymentreminderemails.com/session/xero/callback` as OAuth redirect URIs.
- [ ] Generate a production client secret and add the client ID and secret using `bin/rails credentials:edit`:

```yaml
xero:
  client_id: your-xero-client-id
  client_secret: your-xero-client-secret
  webhook_signing_key: your-xero-webhook-key
```

- [ ] Confirm the app requests only the scopes used by PaymentReminder: OpenID profile/email, read-only invoices, read-only contacts, and offline access.
- [ ] Confirm the public privacy policy and terms satisfy the current Xero Developer Platform terms.

Xero requires an HTTPS production redirect URI and recommends minimum scopes. See [Xero's authorization-code flow](https://developer.xero.com/documentation/guides/oauth2/auth-flow) and [Developer Platform terms](https://developer.xero.com/xero-developer-platform-terms-conditions).

### Configure Xero webhooks

- [ ] In the Xero app, create an **Invoice** webhook subscription for create and update events.
- [ ] Set the delivery URL to `https://app.paymentreminderemails.com/invoice_sources/webhooks/xero`.
- [ ] Copy the Xero Webhook Key into `xero.webhook_signing_key` in Rails credentials.
- [ ] Start and pass Xero's **Intent to receive** validation.
- [ ] Confirm the webhook status shows `OK`.
- [ ] Connect a Xero demo organization, update an invoice, and confirm Xero reports a successful webhook delivery.
- [ ] Monitor the Xero developer email address: Xero retries failed webhooks for up to 24 hours and can disable the subscription.

See [Xero webhooks and Intent to receive](https://developer.xero.com/documentation/best-practices/data-integrity/overview).

### Confirm Xero launch capacity

- [ ] Check the app's current tier and connection allowance in the Xero Developer portal.
- [ ] Treat the Starter tier's current five-connection maximum as a closed-beta limit.
- [ ] Add a payment method and move to Core before inviting a sixth Xero organization.
- [ ] Review Xero usage and connection reports before each broader launch phase.
- [ ] Plan certification/Plus-tier work before an App Store listing or launch beyond Core capacity.
- [ ] Review Xero's current restrictions on AI/ML use of API data before adding any model training or AI data processing.

Current tiers and limits are listed on [Xero Developer pricing](https://developer.xero.com/pricing) and [OAuth 2.0 API limits](https://developer.xero.com/documentation/guides/oauth2/limits).

## 5. Stripe Connect Extension

Stripe should remain hidden or clearly unavailable until every item in this section is complete.

### Confirm the Connect integration type and OAuth access

- [ ] In **Connect settings → Availability**, confirm PaymentReminder is registered as an **Extension**, not a Platform.
- [ ] If it is currently classified as a Platform, contact Stripe to change the integration selection before inviting users.
- [ ] Confirm OAuth onboarding is enabled for Standard accounts.
- [ ] Confirm the authorization screen grants `read_only` access.
- [ ] Confirm PaymentReminder does not create Stripe accounts, modify invoices, create payments, or move connected-account funds.

PaymentReminder reads existing Standard-account invoices, so it is an Extension and requests `read_only`. Stripe reserves `read_only` for Extensions; new payment Platforms follow a different Connect onboarding model. See [Stripe's OAuth reference](https://docs.stripe.com/connect/oauth-reference), [OAuth changes for Standard accounts](https://docs.stripe.com/connect/oauth-changes-for-standard-platforms), and [OAuth with Standard accounts](https://docs.stripe.com/connect/oauth-standard-accounts).

### Configure Stripe live mode

- [ ] Activate the production Stripe account and complete all requested business verification.
- [ ] Complete the Connect profile, branding, support details, website, privacy policy, and terms.
- [ ] Enable the Extension's OAuth integration in **live mode**.
- [ ] Register the exact live redirect URI: `https://app.paymentreminderemails.com/stripe/callback`.
- [ ] Copy the live Connect client ID and live secret key into Rails credentials. Never mix sandbox and live values:

```yaml
stripe:
  client_id: your-live-connect-client-id
  secret_key: your-live-stripe-secret-key
  webhook_signing_secret: your-live-connect-webhook-secret
```

The webhook signing secret is added after the live event destination is created. Never paste any of these values into this checklist.

### Register the live Connect webhook

- [ ] In **Stripe Workbench → Webhooks**, create an HTTPS event destination.
- [ ] Select **Connected accounts** as the event source; do not select events on the PaymentReminder Stripe account.
- [ ] Record the API version selected for the destination so webhook payload changes can be reviewed deliberately.
- [ ] Set its URL to `https://app.paymentreminderemails.com/invoice_sources/webhooks/stripe`.
- [ ] Subscribe only to the events currently handled by PaymentReminder:
  - `invoice.created`
  - `invoice.updated`
  - `invoice.finalized`
  - `invoice.paid`
  - `invoice.voided`
  - `invoice.marked_uncollectible`
  - `account.application.deauthorized`
- [ ] Reveal the live endpoint signing secret and store it as `stripe.webhook_signing_secret`.
- [ ] Restart or deploy PaymentReminder after saving the signing secret.
- [ ] Confirm a connected Standard test account produces successful `2xx` deliveries in Workbench.
- [ ] Confirm duplicate delivery of the same Stripe event does not create duplicate webhook records or jobs.
- [ ] During signing-secret rotation, configure `stripe.webhook_signing_secrets` with both active secrets, verify delivery, and then remove the expired secret.
- [ ] Monitor Workbench for failed deliveries after launch.

Stripe requires HTTPS in live mode, Connect webhooks must explicitly listen to connected-account events, and each sandbox, live, or CLI destination has its own signing secret. See [Connect webhooks](https://docs.stripe.com/connect/webhooks), [Workbench event destinations](https://docs.stripe.com/workbench/event-destinations), and [webhook signature verification](https://docs.stripe.com/webhooks).

### Stripe production smoke tests

- [ ] Connect a live Standard account that is not the PaymentReminder platform account.
- [ ] Confirm the consent screen displays read-only access and returns to `https://app.paymentreminderemails.com/stripe/callback`.
- [ ] Confirm the initial import includes every invoice page for an account with more than 100 invoices.
- [ ] Import a two-decimal invoice such as USD and confirm `25050` minor units are displayed as `250.50`.
- [ ] Import a zero-decimal invoice such as JPY and confirm `25050` minor units are displayed as `25050`, not `250.50`.
- [ ] Mark an open test invoice paid and confirm its `invoice.paid` delivery updates PaymentReminder before the next reminder run.
- [ ] Change an amount or due date and confirm `invoice.updated` refreshes the invoice.
- [ ] Void and mark test invoices uncollectible and confirm both states synchronize.
- [ ] Disconnect Stripe from PaymentReminder and confirm the OAuth connection is removed in Stripe.
- [ ] Reconnect, then deauthorize PaymentReminder from the connected Stripe account and confirm `account.application.deauthorized` marks the PaymentReminder source disconnected.
- [ ] Confirm automatic reminders remain disabled until Gmail and the intended accounting source are connected and verified.

## 6. Hosting, data, and operational services

### Production accounts and access

- [ ] Enable MFA on Cloudflare, AWS, Google Cloud, Xero Developer, Stripe, GitHub, Docker Hub, and the hosting provider.
- [ ] Store recovery codes in the password manager.
- [ ] Remove unused owners, API keys, OAuth clients, webhook endpoints, registry tokens, and SSH keys.
- [ ] Ensure billing and security notifications for every provider go to a monitored address.
- [ ] Add spending alerts wherever the provider supports them.

### Database and secret recovery

- [ ] Configure automatic encrypted MySQL backups outside the database server.
- [ ] Include the primary and queue databases; include all four Rails databases if the backup system works at the MySQL-server level.
- [ ] Set a retention schedule and test a restore into an isolated database.
- [ ] Store `config/master.key` in the password manager and a separate recovery location.
- [ ] Confirm the Rails master key, database backup, and provider credentials are not all recoverable from only one machine.
- [ ] Restrict MySQL network access to the exact web/job server IPs or a private network.
- [ ] Confirm adequate disk-space monitoring on the database, web, and job servers.

### Monitoring and incident notification

- [ ] Add external HTTPS monitoring for the homepage, application, and `/up` endpoint.
- [ ] Create a Sentry project using the Ruby/Rails platform and copy its production DSN.
- [ ] Add the DSN using `bin/rails credentials:edit`:

```yaml
sentry:
  dsn: your-production-sentry-dsn
```

- [ ] Deploy the application and verify a test exception reaches the correct Sentry project and `production` environment.
- [ ] Confirm the `schedule-invoice-reminders` monitor appears after the hourly reminder scheduler first runs.
- [ ] Confirm the `refresh-invoice-sources` monitor appears after the six-hour invoice-source scheduler first runs.
- [ ] Configure Sentry notifications for missed, timed-out, and error check-ins on both monitors.
- [ ] Configure issue alerts for new and regressed production errors.
- [ ] Configure a threshold alert for repeated Gmail authentication failures (`provider:gmail`, `operation:invoice_reminder_delivery`).
- [ ] Configure alerts for repeated `InvoiceSources::Xero::OauthClient::Error` and `InvoiceSources::Stripe::OauthClient::Error` retry events.
- [ ] Trigger a controlled test failure or temporarily pause a non-customer test worker and confirm the intended operator receives the alert; restore normal operation immediately afterward.
- [ ] Confirm Sentry events do not contain OAuth tokens, email bodies, recipient addresses, or invoice financial data.
- [ ] Monitor Solid Queue failed executions separately; a successful scheduler check-in proves that scheduling completed, not that every child refresh or reminder delivery succeeded.
- [ ] Subscribe to AWS, Google Cloud, Xero, Stripe, Cloudflare, and hosting-provider status/security notifications.
- [ ] Document who can disable automatic reminders if a provider or synchronization incident occurs.

PaymentReminder sends Sentry cron check-ins only from the production Solid Queue jobs. The `/up` endpoint can remain healthy while the job server is stopped, which is why both external uptime monitoring and scheduled-job check-ins are required. See [Sentry's Rails integration](https://docs.sentry.io/platforms/ruby/guides/rails/) and [Cron Monitoring](https://docs.sentry.io/product/crons/).

## 7. Final external smoke test

Complete this in production before opening signup broadly:

- [ ] DNS resolves correctly and every public endpoint has a valid HTTPS certificate.
- [ ] Homepage, privacy policy, terms, support mailbox, and application are publicly reachable.
- [ ] A new user can request and receive an SES sign-in code.
- [ ] The SES message passes DKIM and DMARC checks.
- [ ] A non-owner Google account can connect Gmail without an unverified-app warning and receive the test email.
- [ ] A Xero demo organization can connect, import invoices, and deliver a verified webhook update.
- [ ] A live Standard Stripe account can grant read-only access, import invoices, deliver a verified Connect webhook update, and disconnect cleanly.
- [ ] The production job worker processes queued mail and scheduled refresh jobs.
- [ ] External monitoring and provider alerts reach the intended operator.
- [ ] A database restore and Rails master-key recovery have been rehearsed.
- [ ] Record the date, operator, and evidence for each completed provider test.

## Launch gate

Because Stripe is currently offered in the product interface and public copy, Sections 1–7 must all be complete before launch. If Section 5 is not complete, hide Stripe from both the interface and public copy rather than publishing a partially configured connection.
