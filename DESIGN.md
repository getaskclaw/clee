**Term:** design doc. It records a decided design (components, schema, interfaces, rules) plus the build order, whereas "architecture" covers only the structure and "plan/roadmap" only the sequencing.

# AskClaw Keep — Design Doc

## Components
- **`keep.db`**: SQLite in WAL mode with FTS5, the single source of truth. It lives outside the vault and outside any synced folder.
- **`keep` CLI**: the only write path for agents.
- **Datasette**: read-only browsing of the raw rows.
- **Promotion job**: `keep promote`, run by cron, writes Markdown into the vault.
- **Obsidian vault**: small, and holds only promoted files.

## Schema
```sql
CREATE TABLE items (
  id      INTEGER PRIMARY KEY AUTOINCREMENT,  -- never reused
  type    TEXT NOT NULL,   -- log | report | note
  source  TEXT NOT NULL,   -- agent name
  project TEXT,
  created TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  status  TEXT NOT NULL DEFAULT 'new',  -- new | flagged | promoted
  title   TEXT,
  body    TEXT NOT NULL
);
CREATE INDEX items_created ON items(created);
CREATE INDEX items_project ON items(project, created);
CREATE VIRTUAL TABLE items_fts USING fts5(
  title, body, content='items', content_rowid='id');
-- plus insert/update/delete triggers to keep the FTS index in sync
```

## CLI
| Command | Purpose |
|---|---|
| `keep init` | Create the DB, set WAL and `busy_timeout` |
| `keep add --type --source [--project] [--title] [--flag]` | Insert a row (body from stdin), print the ID |
| `keep search <query> [--project] [--type]` | FTS search |
| `keep show <id>` | Print a row |
| `keep flag <id>` | Mark a row for promotion |
| `keep promote [--date] [--dry-run]` | Export to the vault |
| `keep browse` | Launch Datasette |

## Promotion rules
1. **Flagged reports** go to `Reports/<id>-<slug>.md` with the full body and `keep_id` in the frontmatter. They are written once, then the row's status becomes `promoted`.
2. **Daily digest** goes to `Daily/YYYY-MM-DD.md`: counts by project and type, plus the titles of that day's reports.
3. **Project digest** goes to `Projects/<project>.md`: the last 14 days of reports and flagged items.
4. **Logs and notes** are never promoted unless flagged.
5. **Links**: every listed item links back to its row at `http://localhost:8001/keep/items/<id>`.
6. **Regeneration**: digests use fixed paths and are overwritten on each run, so promotion is idempotent. Humans annotate in their own notes, not in digests.

## Milestones
1. **MVP**: `init`, `add`, `search`, `show`, `browse`, with agents switched to `keep add`. The vault stops flooding.
2. **Promotion**: `flag`, `promote`, flagged reports and the daily digest, run from cron.
3. **Polish**: project digests, a one-off import of the existing Markdown backlog, nightly `sqlite3 .backup`, and a retention prune for old logs.

## Risks
- **Write contention**: mitigated by WAL, `busy_timeout=5000` and one short transaction per `add`.
- **Agents still writing Markdown**: make `keep add` a one-liner, and use the phase 3 importer as a sweep.
- **Noisy vault**: promotion is flag-only plus digests; widen it only on demonstrated need.
- **Dead links**: IDs are never reused, and `keep show <id>` works when Datasette is down.
- **Lost human edits**: reports are write-once and digests are documented as generated.
- **Data loss or corruption**: keep the DB off network and sync drives, and back it up nightly.