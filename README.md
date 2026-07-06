# PaidJar

AI accounts-receivable inbox that gets freelancers and small teams paid faster — run by you or your agent.

## Tech Stack

- Ruby 3.4.5
- Rails 8.1.3
- SQLite
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
Please set up PaidJar locally.

1. Read README.md and AGENTS.md first.
2. Make sure Ruby 3.4.5 is active. If the system Ruby is used by mistake, switch to the project Ruby with mise, asdf, rbenv, or the local tool available on this machine.
3. Run bin/setup.
4. Run bin/rails db:prepare.
5. Run bin/rails test and tell me whether it passes.
6. If I want Xero connected, help me configure Rails credentials with:

   xero:
     client_id: my-xero-client-id
     client_secret: my-xero-client-secret
     redirect_uri: http://localhost:3000/xero/callback

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
  redirect_uri: http://localhost:3000/xero/callback
```

## License

PaidJar is licensed under the GNU Affero General Public License v3.0. See [LICENSE](LICENSE).
