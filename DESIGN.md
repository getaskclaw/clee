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

- One row per file in the inbox. The ID is computed from `source + "/" + path` (UTF-8), so a file has the same ID in every DB built from the inbox. Two files whose IDs collide (unlikely below millions of files) make `import` fail rather than mix their rows.
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
| `keep search [<term>...] [--source <machine>] [--limit <n>]` | List rows, newest `updated_at` first. `<n>` is at least 1; default 20. |
| `keep show <id>` | Print a row as its item file would be. |
| `keep flag <id>` | Write the row to `$KEEP_OUT/Items/` now. Run by a person on the central machine; agents only write files. |

Conventions:

- **Connections**: every statement is its own transaction and waits up to 5 seconds for a lock. Every command except `init` exits 1 if the DB does not exist, and creates nothing.
- **Schema version**: every command, `init` included, exits 1 if the DB's `user_version` is not 2, so a DB from another version of Keep is never misread; rebuild it instead.
- **Exit codes**: 0 on success, 1 on any error (usage errors included), with a message on stderr. Invalid input (unknown ID, missing inbox, unset `$KEEP_OUT`, invalid value) writes nothing. `import` also exits 1 when it skipped a file (see Import).
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
- A file that cannot be read, or whose content or name is not UTF-8, is skipped with one line on stderr, `keep: skipped <file>: <reason>`, and the run goes on. `<file>` is the path Keep opened, `<inbox>/<machine>/<path>`, with bytes that are not UTF-8 shown as `\xNN`; `<reason>` is `not UTF-8` or the system's error text, such as `Permission denied`. A directory that cannot be read is reported the same way. A run that skipped anything deletes no rows and exits 1, so cron reports it, and every later run reports it again. Fix or delete the file on the machine it came from, or the next sync brings it back.
- Each file is one statement, so a run that fails midway keeps what it wrote and a rerun does the rest. Run one import at a time (the README's cron line uses `flock`). Overlapping runs cannot corrupt the DB or duplicate rows, but can leave an older version, or drop a row, until the next run.

### Search

- Each term must appear in the path or the body, ignoring case (Python's `str.casefold`); all terms must match. Terms are plain substrings: no wildcards, no operators.
- With no terms every row matches, so `keep search` alone lists the most recently changed files.
- Rows are ordered by `updated_at`, newest first, then by source and path. A file whose content changes moves back to the top.
- `--source` keeps one machine's rows. There is no agent filter; an agent's name is in its files' paths or frontmatter, so search for it.

## Flag

1. **Item files**: `keep flag <id>` writes `Items/<id>-<slug>.md` under `$KEEP_OUT`, creating `Items/` if needed. The file is YAML frontmatter followed by the body verbatim. The fields, in order, are `keep_id`, `source`, `path`, `agent`, `created_at`, `updated_at`, `imported_at` and `sha256`, each a JSON string; non-ASCII stays UTF-8, except DEL, U+0080–U+009F, U+FFFE and U+FFFF, which YAML forbids and are written as `\uXXXX`. A body with its own frontmatter therefore gives a file with two `---` blocks; Keep's comes first.
2. **Slug**: made from the file name (`path` after its last `/`) in four steps: each run of characters outside `[A-Za-z0-9]` becomes one `-`; the result is lowercased; it is cut to 40 characters; leading and trailing `-` are removed. File names end in `.md`, so the slug is never empty.
3. **Writing**: the file is written to `Items/.<name>.<pid>.tmp` and renamed into place, so a synced folder never sees half a file. A file's ID never changes, so flagging it again overwrites the same item file, edits included; copy an item file before editing it if the edits must survive. If `flag` fails or is killed, run it again; delete any leftover `.tmp` file. Power loss and OS crashes are out of scope.
4. **Snapshots**: an item file is a copy of the row when it was flagged. Imports never touch it, so it goes stale when its source file changes, and it stays when its source file leaves the inbox; compare its `sha256` with `keep show <id>`, and flag again to refresh it. Editing an item file never changes the DB. `Items/` is the only record of what was flagged: list it to see what was flagged; delete a file to unflag.

## Rebuild

There are no migrations. After a schema change (Keep exits 1 on the old DB) or a lost DB, delete `keep.db` and run `keep init` and `keep import <inbox>`. That gives back every row, IDs and agents included. What changes: `imported_at` is new, and the file's current mtime becomes the `created_at` of a file without one in its frontmatter and the `updated_at` of a file touched since its content last changed. Item files keep pointing at the right rows.

## Acceptance

The script below is the acceptance test; it checks the behaviour above, not every sentence (it does not check the SQLite version test in `init`). It needs `keep` on `PATH`, the `sqlite3` CLI, `sha256sum`, `cmp` and GNU coreutils (`touch`, `env`, `mkfifo`) on Linux. The unreadable-file cases are skipped when run as root. A failing case means either the implementation or this document is wrong. Search results are counted through a file, so a failing `search` stops the script instead of hiding behind a pipe.

```sh
#!/bin/sh
# acceptance.sh — exits non-zero on the first failure
set -eu
T=$(mktemp -d); I=$T/inbox
export KEEP_DB=$T/db/sub/keep.db KEEP_OUT=$T/out
n()   { sqlite3 "$KEEP_DB" "SELECT count(*) FROM items WHERE $1"; }
q()   { sqlite3 "$KEEP_DB" "SELECT $1 FROM items WHERE $2"; }
idof() { q id "path='$1'"; }
no()  { rc=0; sh -c "$1" >/dev/null 2>"$T/err" || rc=$?   # stderr kept in $T/err
        [ "$rc" -eq 1 ] || { echo "FAIL, want exit 1, got $rc: $1"; exit 1; }; }
hits() { keep search "$@" >"$T/hits"; h=$(wc -l <"$T/hits"); }  # keeps search's exit code
put() { mkdir -p "$(dirname "$I/$1")"; printf '%s\n' "$2" >"$I/$1"; }

# init creates missing directories, is safe to rerun, and refuses other schemas
keep init; keep init; [ -f "$KEEP_DB" ]
sqlite3 "$T/old.db" "CREATE TABLE items (id INTEGER PRIMARY KEY)"
no "KEEP_DB='$T/old.db' keep init"; no "KEEP_DB='$T/old.db' keep search"
sqlite3 "$T/old.db" "PRAGMA user_version = 1"; no "KEEP_DB='$T/old.db' keep search"

# import: source is the machine directory; *.md only, empty files and
# dot-directories too; the ID comes from source/path
for i in $(seq 20); do put "vps1/logs/row-$i.md" "row $i"; done
put vps2/a.md "部署完成，数据库迁移成功"
put vps2/b.md "see foo-bar and a:b, done_ok, été"
put vps2/notes.txt "not markdown"; : >"$I/vps2/empty.md"; put stray.md "no machine"
put vps2/.claude/memo.md x
keep import "$I"
[ "$(n 1)" -eq 24 ]; [ "$(n "source='vps1' AND path LIKE 'logs/row-%.md'")" -eq 20 ]
[ "$(n "source='vps2' AND path='empty.md' AND body=''")" -eq 1 ]
[ "$(n "source='vps2' AND path='.claude/memo.md'")" -eq 1 ]
[ "$(idof a.md)" = "$(printf vps2/a.md | sha256sum | cut -c1-12)" ]

# one row per source and path, holding the latest version; reruns add nothing
keep import "$I"; [ "$(n 1)" -eq 24 ]
put vps2/c.md "version-one"; keep import "$I"; c=$(idof c.md)
put vps2/c.md "version-two"; keep import "$I"; keep import "$I"
hash=$(sha256sum <"$I/vps2/c.md" | cut -d' ' -f1)
[ "$(n "path='c.md'")" -eq 1 ]; [ "$(idof c.md)" = "$c" ]
[ "$(n "id='$c' AND body LIKE 'version-two%' AND sha256='$hash'")" -eq 1 ]
hits version-one; [ "$h" -eq 0 ]; hits version-two; [ "$h" -eq 1 ]
: >"$I/vps2/c.md"; keep import "$I"; [ "$(n "id='$c' AND body=''")" -eq 1 ]
put vps1/same.md "same"; put vps3/same.md "same"; keep import "$I"
[ "$(n "path='same.md'")" -eq 2 ]

# a file gone from the inbox loses its row; back again, it has the same ID
s3=$(q id "source='vps3'"); rm "$I/vps3/same.md"; keep import "$I"
[ "$(n "source='vps3'")" -eq 0 ]
put vps3/same.md "same"; keep import "$I"; [ "$(q id "source='vps3'")" = "$s3" ]

# a skipped file is named on stderr and import exits 1; the rest still
# imports, and nothing is deleted
printf 'ok\377\n' >"$I/vps2/bin.md"; printf '\000nul\n' >"$I/vps2/nul.md"
bad=$I/vps2/$(printf 'bad\377').md; printf x >"$bad"; rm "$I/vps2/empty.md"
no "keep import '$I'"; grep -qxF "keep: skipped $I/vps2/bin.md: not UTF-8" "$T/err"
grep -qxF "keep: skipped $I/vps2/bad\\xff.md: not UTF-8" "$T/err"
[ "$(wc -l <"$T/err")" -eq 2 ]
[ "$(n "path='bin.md'")" -eq 0 ]; [ "$(n "path='nul.md'")" -eq 1 ]
[ "$(n "path='empty.md'")" -eq 1 ]
rm "$I/vps2/bin.md" "$bad"; keep import "$I"; [ "$(n "path='empty.md'")" -eq 0 ]
if [ "$(id -u)" -ne 0 ]; then                   # root can read anything
  put vps2/locked/x.md x; keep import "$I"
  put vps2/noread.md x; chmod 000 "$I/vps2/noread.md" "$I/vps2/locked"
  no "keep import '$I'"
  grep -qxF "keep: skipped $I/vps2/noread.md: Permission denied" "$T/err"
  grep -qxF "keep: skipped $I/vps2/locked: Permission denied" "$T/err"
  [ "$(n "path='locked/x.md'")" -eq 1 ]
  chmod 700 "$I/vps2/locked"; rm -r "$I/vps2/noread.md" "$I/vps2/locked"
  keep import "$I"; [ "$(n "path='locked/x.md'")" -eq 0 ]
fi

# symlinks and other non-regular files are ignored without a message
before=$(n 1); ln -s a.md "$I/vps2/link.md"; mkfifo "$I/vps2/fifo.md"
ln -s ../vps1 "$I/vps2/sub"; ln -s vps1 "$I/vps9"
keep import "$I" 2>"$T/err"; [ ! -s "$T/err" ]; [ "$(n 1)" -eq "$before" ]

# invalid input writes nothing; only init creates a DB
no "keep import '$T/missing'"; no "keep show 000000000000"; no "keep flag 000000000000"
no "keep search x --limit 0"; no "env -u KEEP_OUT keep flag $c"
no "keep search --bogus"; no "keep show"
no "KEEP_DB='$T/none/keep.db' keep search"; [ ! -e "$T/none" ]
[ "$(n 1)" -eq "$before" ]; [ ! -e "$KEEP_OUT" ]

# search: CJK, punctuation, wildcards, case, text after a NUL, no hits, no terms
hits 数据库;        [ "$h" -eq 1 ]
hits 部署;          [ "$h" -eq 1 ]
hits foo-bar;       [ "$h" -eq 1 ]
hits a:b;           [ "$h" -eq 1 ]
hits FOO-BAR ok;    [ "$h" -eq 1 ]
hits ÉTÉ;           [ "$h" -eq 1 ]
hits _;             [ "$h" -eq 1 ]
hits %%;            [ "$h" -eq 0 ]
hits nul;           [ "$h" -eq 1 ]
hits AND;           hits '"'
hits row --limit 5; [ "$h" -eq 5 ]
hits same --source vps3; [ "$h" -eq 1 ]
hits;               [ "$h" -eq 20 ]             # every row, default limit

# newest first: an old row whose content changed comes back to the top
put vps2/b.md "b again"; touch -d '2030-01-01 00:00:00 UTC' "$I/vps2/b.md"
keep import "$I"; hits
printf '%s\t2030-01-01T00:00:00Z\tvps2\tb.md\n' "$(idof b.md)" >"$T/want"
head -1 "$T/hits" | cmp - "$T/want"

# metadata: created_at is the mtime at first import when the frontmatter has
# none; updated_at is the mtime when the content last changed (a touch alone
# changes nothing); imported_at is set when the row is added
am() { q "agent||'|'||created_at" "path='$1'"; }
[ "$(n "imported_at GLOB '20[0-9][0-9]-[01][0-9]-[0-3][0-9]T*Z'")" -eq "$(n 1)" ]
put vps1/m.md m1; touch -d '2026-01-02 03:04:05 UTC' "$I/vps1/m.md"; keep import "$I"
m=$(idof m.md); [ "$(am m.md)" = "|2026-01-02T03:04:05Z" ]
[ "$(q updated_at "id='$m'")" = 2026-01-02T03:04:05Z ]
touch -d '2026-02-03 04:05:06 UTC' "$I/vps1/m.md"; keep import "$I"
[ "$(q updated_at "id='$m'")" = 2026-01-02T03:04:05Z ]
sqlite3 "$KEEP_DB" "UPDATE items SET imported_at='2000-01-01T00:00:00Z' WHERE id='$m'"
put vps1/m.md m2; touch -d '2026-03-04 05:06:07 UTC' "$I/vps1/m.md"
keep import "$I"; keep import "$I"
[ "$(am m.md)|$(q updated_at "id='$m'")" = "|2026-01-02T03:04:05Z|2026-03-04T05:06:07Z" ]
[ "$(n "id='$m' AND source='vps1' AND body LIKE 'm2%' AND imported_at LIKE '2000-%'")" -eq 1 ]

# agent: the frontmatter's agent, else <name> from profiles/<name>/ in the
# path, else empty; agent and created_at are read again from each new version
p=.hermes/profiles/scout; put "vps1/$p/notes/p.md" p; put vps1/profiles/x.md x
printf '%s\n' --- 'agent: "ranger"' "created_at: '2025-12-31T23:59:59Z'" --- q >"$I/vps1/$p/q.md"
printf '%s\n' text --- 'agent: x' --- >"$I/vps1/nf.md"; printf '%s\n' --- 'agent: x' >"$I/vps1/un.md"
keep import "$I"
[ "$(q agent "path='$p/notes/p.md'")" = scout ]
[ "$(am "$p/q.md")" = "ranger|2025-12-31T23:59:59Z" ]
[ "$(n "path IN ('profiles/x.md', 'nf.md', 'un.md') AND agent=''")" -eq 3 ]
printf '%s\n' --- 'agent: warden' --- q2 >"$I/vps1/$p/q.md"; keep import "$I"
[ "$(am "$p/q.md")" = "warden|2025-12-31T23:59:59Z" ]
printf '%s\n' --- 'created_at: 2026-06-01T00:00:00Z' '  agent: nested' --- q3 >"$I/vps1/$p/q.md"
keep import "$I"; [ "$(am "$p/q.md")" = "scout|2026-06-01T00:00:00Z" ]

# show: Keep's frontmatter, then the file byte for byte (its own frontmatter,
# CRLF and a missing final newline included); non-ASCII stays as UTF-8,
# characters YAML forbids are escaped
printf '%s\r\n' --- 'agent: scout' --- >"$I/vps2/fm.md"; printf 'no final newline' >>"$I/vps2/fm.md"
keep import "$I"; keep show "$(idof fm.md)" >"$T/show"
tail -n +11 "$T/show" | cmp - "$I/vps2/fm.md"
grep -qx "sha256: \"$(q sha256 "path='fm.md'")\"" "$T/show"; grep -qxF 'agent: "scout"' "$T/show"
put vps1/日志😀.md x; put "vps1/del$(printf '\177').md" x; keep import "$I"
keep show "$(idof 日志😀.md)" >"$T/show"; grep -qxF 'path: "日志😀.md"' "$T/show"
keep show "$(q id "path LIKE 'del%'")" >"$T/show"; grep -qxF 'path: "del\u007f.md"' "$T/show"

# flag writes the item file now, exactly what show printed; imports leave it
# alone; flagging again rewrites it
put "vps1/Disk: Full!.md" "disk full on db-1"; keep import "$I"
id=$(idof 'Disk: Full!.md'); f=$KEEP_OUT/Items/$id-disk-full-md.md
keep show "$id" >"$T/show"; keep flag "$id"; cmp "$f" "$T/show"
[ "$(sed -n '2,9p' "$f" | cut -d: -f1 | tr '\n' ' ')" = "keep_id source path agent created_at updated_at imported_at sha256 " ]
put "vps1/Disk: Full!.md" "disk full again"; keep import "$I"; cmp "$f" "$T/show"
keep flag "$id"; [ "$(grep -c 'disk full again' "$f")" -eq 1 ]
[ "$(ls -A "$KEEP_OUT/Items")" = "$id-disk-full-md.md" ]

# slug: runs outside [A-Za-z0-9] become -, then lowercased, cut to 40
put "vps1/notes/Quarterly Review — Churn & Retention 2026 Final.md" qr; keep import "$I"
s=$(idof 'notes/Quarterly Review — Churn & Retention 2026 Final.md'); keep flag "$s"
[ -f "$KEEP_OUT/Items/$s-quarterly-review-churn-retention-2026-fi.md" ]

# a failing flag exits 1
: >"$T/notadir"; no "KEEP_OUT='$T/notadir' keep flag $id"

# a file or directory name cannot inject frontmatter or split a search line
put "vps1
evil: 1/x
---
evil: 2.md" body; keep import "$I"
j=$(q id "path LIKE 'x%'")
keep flag "$j"
[ "$(grep -c '^evil:' "$KEEP_OUT"/Items/"$j"-*.md)" -eq 0 ]
hits evil; [ "$h" -eq 1 ]; [ "$(cut -f1 "$T/hits")" = "$j" ]

# rebuild from the inbox: the same rows, IDs and agents included; created_at
# from frontmatter survives, the mtime fallback becomes the current mtime
rows="SELECT id, source, path, agent, sha256, body FROM items ORDER BY id"
sqlite3 "$KEEP_DB" "$rows" >"$T/before"
rm "$KEEP_DB"; keep init; keep import "$I"
sqlite3 "$KEEP_DB" "$rows" | cmp - "$T/before"
[ "$(am "$p/q.md")" = "scout|2026-06-01T00:00:00Z" ]
[ "$(am m.md)|$(q updated_at "id='$m'")" = "|2026-03-04T05:06:07Z|2026-03-04T05:06:07Z" ]

echo "all acceptance cases passed"
```

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
