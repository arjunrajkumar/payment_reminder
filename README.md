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

## Xero

Create a Xero OAuth 2.0 app and configure its redirect URI to:

```text
http://localhost:3000/xero/callback
```

Then set:

```bash
XERO_CLIENT_ID=...
XERO_CLIENT_SECRET=...
XERO_REDIRECT_URI=http://localhost:3000/xero/callback
```

## License

PaidJar is licensed under the GNU Affero General Public License v3.0. See [LICENSE](LICENSE).
