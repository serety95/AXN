# UI Widget to Database Attribute Mapping

## 1. Widget Mapping Table

| Figma Widget | Semantic Type | Recommended PostgreSQL Type | Nullability & Default | Constraints & Modeling Notes |
| :--- | :--- | :--- | :--- | :--- |
| Short text input | Short string | `VARCHAR(N)` or `TEXT` | `NOT NULL` if `*` | Add `CHECK (length(trim(col)) > 0)` for required text |
| Textarea / rich notes | Long text | `TEXT` | `NULL` or `NOT NULL DEFAULT ''` | Store sanitized plain text or Markdown; avoid unbounded HTML |
| Email input | Email address | `CITEXT` or `VARCHAR(254)` | `NOT NULL` | `UNIQUE` if account/contact key; validate format at boundary |
| Phone input | E.164 phone | `VARCHAR(20)` | `NULL` / `NOT NULL` | Normalize to E.164 (`+15551234567`); keep raw display optional |
| Number / stepper | Integer / decimal | `INTEGER` / `NUMERIC(p,s)` | `NOT NULL DEFAULT 0` | Add `CHECK (col >= 0)` when UI forbids negatives (e.g., qty) |
| Currency / price | Monetary amount | `NUMERIC(12,2)` + `CHAR(3)` | `NOT NULL DEFAULT 0.00` | Never use `FLOAT`; pair with `currency_code` (e.g., `'USD'`) |
| Date picker | Calendar date | `DATE` | `NULL` / `NOT NULL` | No timezone; add range `CHECK` if UI enforces `end >= start` |
| Datetime / schedule | Instant in time | `TIMESTAMPTZ` | `NOT NULL DEFAULT now()` | Always store UTC (`TIMESTAMPTZ`), format in client TZ |
| Toggle / checkbox | Boolean flag | `BOOLEAN` | `NOT NULL DEFAULT false` | Prefer explicit defaults matching the Figma initial toggle state |
| Single-select / radio | Closed state or lookup | `TEXT` + `CHECK` or `FK` | `NOT NULL` | Use `CHECK (status IN (...))` for fixed states; `FK` if admin-managed |
| Multi-select / tag chips | `M:N` association | Junction table `(a_id, b_id)` | Composite PK `(a_id, b_id)` | Never store comma-separated strings; index reverse FK `b_id` |
| File / image upload | Object-storage ref | Child table (`attachments`) | `storage_key TEXT NOT NULL` | Store `storage_key`, `file_name`, `mime_type`, `byte_size` |
| Repeatable subform / rows | `1:N` child entity | Child table (`parent_id FK`) | `NOT NULL` + `line_no INT` | Preserve UI row ordering with `line_no` / `sort_order` |
| Status badge / stepper | Workflow state | `TEXT` + `CHECK` (+ history) | `NOT NULL DEFAULT '<init>'` | Add `*_status_history` table if UI displays audit timeline |

## 2. Lookup Table vs Enum vs JSONB Decision Matrix

| Criterion | `TEXT` + `CHECK` / SQL `ENUM` | Lookup Table (`*_types` / `tags`) | `JSONB` Column |
| :--- | :--- | :--- | :--- |
| Values change at runtime via Admin UI? | No (code/migration) | **Yes** | Yes (unstructured) |
| Needs extra attributes (color, icon, label, sort)? | No | **Yes** | Only if not queried/joined |
| Filtered, grouped, or joined in SQL queries? | **Yes** | **Yes** | Avoid for core FKs/filters |
| Per-tenant custom fields / sparse widget prefs? | No | No | **Yes** (with schema validation) |
