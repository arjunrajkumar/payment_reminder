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

   Do not ask me to paste secrets into chat. Open the credentials editor and wait while I type them locally.
7. Start the app with bin/rails server and tell me the localhost URL.
```

This gives the agent enough context to install dependencies, prepare the database, verify the app, and guide credential setup without requiring a long manual checklist.

## Xero

Create a Xero OAuth 2.0 app and configure its redirect URI to:

```text
http://localhost:3000/xero/callback
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

OAuth callback URLs are derived from `HOST`, which defaults to `http://localhost:3000` in development. Register `<HOST>/xero/callback` in Xero. For example, start a second local server with:

```bash
HOST=http://localhost:3001 bin/rails server -p 3001 -P tmp/pids/server-3001.pid
```

For local webhook testing, expose your local app with a tunnel and configure the Xero webhook delivery URL to:

```text
https://your-tunnel.example/invoice_sources/webhooks/xero
```

## Stripe

Create a Stripe Connect OAuth application and configure its redirect URI to:

```text
http://localhost:3000/stripe/callback
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

Register `<HOST>/stripe/callback` as the Stripe Connect redirect URI.

PaymentReminder uses the connected Stripe account id returned by OAuth to read invoices through the Stripe API.

For local webhook testing with the Stripe CLI:

```bash
stripe listen --forward-to localhost:3000/invoice_sources/webhooks/stripe
```

After credentials are configured, sign in and open `/account/settings` to connect Xero or Stripe.

## License

PaymentReminder is licensed under the GNU Affero General Public License v3.0. See [LICENSE](LICENSE).
