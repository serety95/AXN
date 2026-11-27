# rails-security — Extended Reference

## Secrets and Credentials

Secrets belong in Rails credentials, environment variables, or a secret manager:

```bash
bin/rails credentials:edit --environment production
```

`config/credentials/production.key` must stay out of version control. Read secrets through
`Rails.application.credentials` or `ENV.fetch` — `ENV[...]` returns `nil` and fails silently
when a variable is missing:

```ruby
# Bad
ENV["STRIPE_SECRET"]

# Good
Rails.application.credentials.dig(:stripe, :secret)
ENV.fetch("STRIPE_SECRET")
```

If a key is ever committed, rotate it. Removing the commit does not un-expose it.

## Untrusted Boundaries

Controller params are not the only entry point. Job arguments, webhook payloads, Action
Cable messages, and Turbo Stream targets all carry outside data:

- Pass record IDs to jobs and re-scope inside `perform`; a queued job runs without the
  original request's session.
- Authorize in `ApplicationCable::Connection` and in each channel's `subscribed`.
- Never build a Turbo Stream target from user input.

```ruby
class ExportJob < ApplicationJob
  def perform(user_id, invoice_id)
    user = User.find(user_id)
    invoice = user.invoices.find(invoice_id) # scoped, not Invoice.find
    # ...
  end
end
```

## Dependency Scanning

Run these when the lockfile changes, and in CI:

```bash
bundle exec bundle-audit check --update
bundle exec brakeman --no-progress
```

Brakeman flags the patterns above statically. Treat new warnings as blocking, and record
deliberate exceptions in `config/brakeman.ignore` with a reason rather than lowering the
confidence threshold.

## Verification Checklist

- [ ] `force_ssl` and `config.hosts` set in production
- [ ] Sensitive parameters filtered from logs
- [ ] Sessions rotated on sign-in and privilege change
- [ ] Every record lookup scoped to the current user or checked by a policy
- [ ] No permit list contains a role, ownership, or account column
- [ ] No raw SQL string interpolation; `order` and `pluck` inputs allowlisted
- [ ] Every `html_safe` and `raw` reviewed
- [ ] CSRF exemptions scoped to specific actions with another auth mechanism
- [ ] Uploads validated against stored bytes, not `blob.content_type`, and fail closed when the object is unavailable
- [ ] Auth endpoints rate-limited; webhook signatures compared in constant time
- [ ] No secrets in version control; master key excluded
- [ ] `bundle-audit` and `brakeman` clean

## Related Skills

- `rails-patterns` — the architectural patterns these controls sit inside
- `security-review` — secure-by-default review patterns across languages
- Ruby security rules (`rules/ruby/security.md`, installed as `rules/ecc/ruby/security.md`)
  — the decisions and when-to-use guidance this skill implements
