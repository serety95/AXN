# database-migrations — Extended Reference

## golang-migrate (Go)

### Workflow

```bash
# Create migration pair
migrate create -ext sql -dir migrations -seq add_user_avatar

# Apply all pending migrations
migrate -path migrations -database "$DATABASE_URL" up

# Rollback last migration
migrate -path migrations -database "$DATABASE_URL" down 1

# Force version (fix dirty state)
migrate -path migrations -database "$DATABASE_URL" force VERSION
```

### Migration Files

```sql
-- migrations/000003_add_user_avatar.up.sql
ALTER TABLE users ADD COLUMN avatar_url TEXT;
CREATE INDEX CONCURRENTLY idx_users_avatar ON users (avatar_url) WHERE avatar_url IS NOT NULL;

-- migrations/000003_add_user_avatar.down.sql
DROP INDEX IF EXISTS idx_users_avatar;
ALTER TABLE users DROP COLUMN IF EXISTS avatar_url;
```

## Zero-Downtime Migration Strategy

For critical production changes, follow the expand-contract pattern:

```
Phase 1: EXPAND
  - Add new column/table (nullable or with default)
  - Deploy: app reads OLD, writes BOTH atomically
  - Drain old-only writers and in-flight transactions
  - Backfill in committed batches, then verify parity

Phase 2: MIGRATE
  - Deploy: app reads from NEW, writes to BOTH
  - Monitor parity and retain dual writes throughout the rollback window

Phase 3: CONTRACT
  - End rollback window; stop backfill and migrate constraints/dependencies
  - Drain non-app old-column readers and their in-flight transactions
  - Deploy: app only uses NEW; drain remaining old-column users
  - Drop old column/table in separate migration
```

### Timeline Example

```
Day 1: Migration adds new_status column (nullable)
Day 1: Deploy app v2 — reads status, writes both columns atomically
Day 2: Drain old-only writers; backfill in batches; require zero mismatches
Day 3: Deploy app v3 — reads new_status, still writes both columns
Day 7: End rollback window; stop backfill; migrate constraints/dependencies
Day 7: Drain non-app old-column readers and their in-flight transactions
Day 7: Deploy app v4 — only uses new_status; drain remaining old-column users
Later: Separate migration drops status after all contract gates pass
```

## Anti-Patterns

| Anti-Pattern | Why It Fails | Better Approach |
|-------------|-------------|-----------------|
| Manual SQL in production | No audit trail, unrepeatable | Always use migration files |
| Editing deployed migrations | Causes drift between environments | Create new migration instead |
| Adding NOT NULL column without default to populated table | Fails because existing rows would contain NULL | Add nullable, backfill, then set NOT NULL |
| Inline index on large table | Blocks writes during build | CREATE INDEX CONCURRENTLY |
| Schema + data in one migration | Hard to rollback, long transactions | Separate migrations |
| Dropping column before removing code | Application errors on missing column | Remove code first, drop column next deploy |
