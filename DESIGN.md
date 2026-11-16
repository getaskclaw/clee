# AskClaw Keep — Design Doc

Keep is a searchable index of the Markdown your AI agents write. Agents keep writing files as they always have; each machine pushes them to one central machine, where Keep indexes them in SQLite so you can search them all. Only items a person flags are written back out as Markdown, so the folder people read stays small.

## Trust model

Keep assumes one user, one central machine, and other machines run by that user that push files to it.

- `source` is the name of the inbox directory a file arrived in. It is a label, not an authenticated identity.
- Everything in the inbox, the DB directory and `$KEEP_OUT` is trusted.
- Keep sets no file permissions. The DB holds the same text as the inbox, so protect both the same way, for example with `umask 077` in the cron jobs.

What Keep does guarantee:

- **Nothing unflagged reaches `$KEEP_OUT`**: Keep writes nothing about an unflagged item there, not even counts or paths.
- **No injection through metadata**: every frontmatter value Keep writes is a single-line JSON string, so a file or directory name cannot add fields or close the frontmatter.
- **Safe file names**: an exported file name is built only from the ID and `[a-z0-9-]`.

## Components

- **Sync (not part of Keep)**: each machine pushes its Markdown one way into `<inbox>/<machine>/` on the central machine, under a name no other machine uses; two machines sharing a name overwrite each other's files. Any tool that writes complete files by rename works, such as this cron line (`-rt` without `-l` skips symlinks):
  `rsync -rt --include='*/' --include='*.md' --exclude='*' ~/hermes-notes/ central:keep-inbox/laptop/`
  Syncthing with a Send Only folder on each machine also works.
- **Inbox**: the record. Keep only reads it, and the DB mirrors it: a file is in Keep exactly while it is in the inbox. Syncthing passes deletions on, so a file deleted on its machine leaves Keep at the next import; rsync without `--delete` does not, so delete such files from the inbox yourself.
- **`keep.db`**: the index, SQLite at `$KEEP_DB`, on a local disk, outside any synced folder. It can be deleted and rebuilt at any time (see Rebuild).
- **`keep` CLI**: one Python 3.9+ file, standard library only, MIT licensed, needing SQLite 3.24+. Installed on the central machine only, and the only writer of the DB.
- **Output folder**: `$KEEP_OUT/Items/`, written only by `keep flag`. It may sit inside a synced folder or an Obsidian vault.

## Settings

| Setting | Default |
|---|---|
| `$KEEP_DB` | `~/.keep/keep.db` |
| `$KEEP_OUT` | No default. `flag` exits 1 if it is unset. |

A leading `~` in either is expanded; a relative path is relative to the current directory.

## Schema

```sql
CREATE TABLE items (
  id          TEXT PRIMARY KEY,  -- first 12 hex digits of SHA-256 of source/path
  source      TEXT NOT NULL,  -- host: the inbox/<machine> directory name
  path        TEXT NOT NULL,  -- file path inside that directory
  agent       TEXT NOT NULL,  -- frontmatter agent, else profiles/<name>/ in path, else ''
  created_at  TEXT NOT NULL,  -- frontmatter created_at, else mtime at first import
  updated_at  TEXT NOT NULL,  -- file mtime when the content last changed
  imported_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  sha256      TEXT NOT NULL,  -- SHA-256 of the file bytes
  body        TEXT NOT NULL,
  UNIQUE (source, path)
);
PRAGMA user_version = 2;
```

- One row per file in the inbox. The ID is computed from `source + "/" + path` (UTF-8), so a file has the same ID in every DB built from the inbox. Two files whose IDs collide (unlikely below millions of files) never mix their rows: the one imported second is skipped (see Import) with the reason `ID <id> is taken by <source>/<path>`.
- Times Keep sets are UTC, `YYYY-MM-DDTHH:MM:SSZ`; a `created_at` from frontmatter is stored as written.

Metadata, set by `import`:

- `agent`: the file's frontmatter `agent`; else `<name>` from the first `profiles/<name>/` in `path`; else empty.
- `created_at`: the file's frontmatter `created_at`; else the file's mtime when its row was added. A new version without the field keeps the row's value.
- `updated_at`: the file's mtime when the row was added or its content (SHA-256) last changed. Touching a file changes nothing.
- `imported_at`: when the row was added.
- `agent` and `created_at` are read again from every new version of the file, not kept from the first; an unchanged file would give the same values.
- **Frontmatter**: only these two fields are read. It is the lines after a first line `---` up to the next `---` line (CR before LF ignored); a first `---` never closed means no frontmatter. Each `key: value` line with the key at the start of the line counts; spaces around the value, and one pair of matching `'` or `"` around it, are removed; an empty value counts as missing. No other YAML (escapes, comments, multi-line values) is understood.

## CLI

| Command | Purpose |
|---|---|
| `keep init` | Create the DB, and any missing directories above it. Safe to rerun. Exits 1 if SQLite is older than 3.24. |
| `keep import <inbox>` | Bring the DB in line with the inbox. |
| `keep search [<term>...] [--source <machine>] [--agent <name>] [--limit <n>]` | List rows, newest `updated_at` first. `<n>` is at least 1; default 20. |
| `keep show <id>` | Print a row as its item file would be. |
| `keep flag <id>` | Write the row to `$KEEP_OUT/Items/` now. Run by a person on the central machine; agents only write files. |

Conventions:

- **Connections**: every statement is its own transaction and waits up to 5 seconds for a lock. Every command except `init` exits 1 if the DB does not exist, and creates nothing.
- **Schema version**: every command, `init` included, exits 1 if the DB's `user_version` is not 2, so a DB from another version of Keep is never misread; rebuild it instead.
- **Exit codes**: 0 on success, 1 on any error (usage errors included), with a message on stderr. Invalid input (unknown ID, missing inbox, unset `$KEEP_OUT`, invalid value) writes nothing. `import` also exits 1 when it skipped a file or found no file to read (see Import). A reader that closes `search`'s output early (`keep search | head -1`) ends it quietly.
- **Encoding**: Keep reads and writes UTF-8, whatever the locale.
- **Output**:
  - `init`, `import` and `flag` print nothing on success.
  - `search` prints one line per row, `id<TAB>updated_at<TAB>source<TAB>path`. No hits prints nothing and exits 0.
  - In every line Keep prints (search results, import's skip messages), tabs, CRs and LFs inside a value print as spaces.
  - `show` prints exactly the item file `flag` would write now.

### Import

- Each directory directly under `<inbox>` is a machine; its name is the `source`. Files directly under `<inbox>` are ignored.
- Every regular file ending in `.md` below a machine directory is read, in dot-directories such as `.claude/` too. Symlinks (machine directories included), FIFOs and other non-regular files are ignored without a message. `path` is the file's path relative to its machine directory. The `body` is the whole file, byte for byte, its own frontmatter included; Keep reads only `agent` and `created_at` from it (see Schema). An empty file gives an empty body.
- A new file adds a row; a file whose SHA-256 changed rewrites its row's `agent`, `created_at`, `updated_at`, `sha256` and `body`; any other file is left alone, even if its mtime changed, so reruns change nothing. A file no longer in the inbox loses its row. rsync `-t` keeps mtimes. A renamed file is a new row with a new ID.
- A file that cannot be read, or whose content or name is not UTF-8, is skipped with one line on stderr, `keep: skipped <file>: <reason>`, and the run goes on. `<file>` is the path Keep opened, `<inbox>/<machine>/<path>`, with bytes that are not UTF-8 shown as `\xNN`; `<reason>` is `not UTF-8` or the system's error text, such as `Permission denied`. A directory that cannot be read is reported the same way. A run that skipped a file deletes no rows of that file's machine (other machines' rows are deleted as usual) and exits 1, so cron reports it, and every later run reports it again. Fix or delete the file on the machine it came from, or the next sync brings it back.
- An inbox in which no file could be read (no machine directories, or no `.md` files in them, as when a mount or sync folder is missing) while the DB has rows deletes nothing and exits 1 with one line on stderr, `keep: no readable .md files in <inbox>; deleted nothing`. To empty Keep, delete `keep.db` and run `keep init`.
- Each file is one statement, so a run that fails midway keeps what it wrote and a rerun does the rest. Run one import at a time (the README's cron line uses `flock`). Overlapping runs cannot corrupt the DB or duplicate rows, but can leave an older version, or drop a row, until the next run.

### Search

- Each argument is one term, spaces included, and must appear in the path or the body, ignoring case (Python's `str.casefold`); all terms must match. So `keep search "disk full"` finds the phrase, and `keep search disk full` finds rows with both words anywhere. Terms are plain substrings: no wildcards, no operators.
- With no terms every row matches, so `keep search` alone lists the most recently changed files.
- Rows are ordered by `updated_at`, newest first, then by source and path. A file whose content changes moves back to the top.
- `--source` keeps the rows whose `source` is exactly `<machine>`; `--agent` keeps the rows whose `agent` is exactly `<name>` (case matters). Given both, a row must match both.

## Flag

1. **Item files**: `keep flag <id>` writes `Items/<id>-<slug>.md` under `$KEEP_OUT`, creating `Items/` if needed. The file is YAML frontmatter followed by the body verbatim. The fields, in order, are `keep_id`, `source`, `path`, `agent`, `created_at`, `updated_at`, `imported_at` and `sha256`, each a JSON string; non-ASCII stays UTF-8, except DEL, U+0080–U+009F, U+FFFE and U+FFFF, which YAML forbids and are written as `\uXXXX`. A body with its own frontmatter therefore gives a file with two `---` blocks; Keep's comes first.
2. **Slug**: made from the file name (`path` after its last `/`) in four steps: each run of characters outside `[A-Za-z0-9]` becomes one `-`; the result is lowercased; it is cut to 40 characters; leading and trailing `-` are removed. File names end in `.md`, so the slug is never empty.
3. **Writing**: the file is written to `Items/.<name>.<pid>.tmp` and renamed into place, so a synced folder never sees half a file. A file's ID never changes, so flagging it again overwrites the same item file, edits included; copy an item file before editing it if the edits must survive. If `flag` fails or is killed, run it again; delete any leftover `.tmp` file. Power loss and OS crashes are out of scope.
4. **Snapshots**: an item file is a copy of the row when it was flagged. Imports never touch it, so it goes stale when its source file changes, and it stays when its source file leaves the inbox; compare its `sha256` with `keep show <id>`, and flag again to refresh it. Editing an item file never changes the DB. `Items/` is the only record of what was flagged: list it to see what was flagged; delete a file to unflag.

## Rebuild

There are no migrations. After a schema change (Keep exits 1 on the old DB) or a lost DB, delete `keep.db` and run `keep init` and `keep import <inbox>`. That gives back every row, IDs and agents included. What changes: `imported_at` is new, and the file's current mtime becomes the `created_at` of a file without one in its frontmatter and the `updated_at` of a file touched since its content last changed. Item files keep pointing at the right rows.

## Acceptance

[`acceptance.sh`](acceptance.sh) is the acceptance test; run it as `PATH=$PWD:$PATH sh acceptance.sh`. It checks the behaviour above, not every sentence (it does not check the SQLite version test in `init`). It needs the `sqlite3` CLI, `sha256sum`, `cmp` and GNU coreutils (`touch`, `env`, `mkfifo`) on Linux. The unreadable-file cases are skipped when run as root. A failing case means either the implementation or this document is wrong.

## Non-goals

- Backups of the DB. Back up the inbox like any folder (the machines that push to it hold copies too); the DB can be rebuilt from it.
- Version history. Each file keeps only its latest version; an older version survives only in an item file flagged before the change.
- Parsing the files beyond frontmatter `agent` and `created_at`: no title or tag fields, no full YAML.
- Concurrent imports (see Import).
- Secret redaction, or sanitizing HTML and images. Bodies are stored and exported verbatim.
- An editor, a note-taking UI, multi-user access, or two-way sync.

## Later (only on demonstrated need)

- Skipping unchanged files by size and mtime, if reading the whole inbox gets slow.
- A full-text index, if scanning every row gets slow.
- Other filters or sort orders.

## Risks

- **Partial files**: a sync tool that writes in place could expose half a file, which import stores until the next run sees the whole file. Use tools that rename into place (rsync and Syncthing do).
- **Unwanted files**: every `.md` file that reaches the inbox is imported, including Syncthing's `*.sync-conflict-*.md` files, its `.stversions/` folder if versioning is on at the central machine, and a vault's `.trash/`. Keep them out in the sync tool, or delete them from the inbox.
- **Scale**: every import reads every file and every search reads every row. That suits one person's notes; see Later.
- **A newer body than the one read**: `flag` exports the row as it is when `flag` runs. If an import changes the row between `keep show` and `keep flag`, the newer body is exported; the item file's `sha256` tells which version it is.
