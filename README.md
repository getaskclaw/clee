# AskClaw Keep

A searchable index of the Markdown your AI agents write.

Agents keep writing Markdown files as usual. Each machine pushes them to one central machine, where Keep indexes them in SQLite so you can search all of it. Only the items you flag are written back out as plain Markdown, so the folder you read stays small.

## How it works

1. Each machine pushes its Markdown one way to `inbox/<machine>/` on the central machine with rsync from cron (not part of Keep). Give every machine its own name.
2. `keep import inbox` mirrors the inbox: one row per `.md` file (dot-directories such as `.claude/` included), holding its latest content along with its machine, path, agent (the frontmatter's `agent`, else `<name>` from `profiles/<name>/` in the path), creation time (the frontmatter's `created_at`, else the mtime at first import), last content change, import time and content hash. A file removed from the inbox loses its row. Reruns change nothing. A file it cannot read (or whose mtime is past year 9999) is named on stderr, that machine's rows are not deleted, and the run exits 1; fix it on the machine it came from. A machine directory with no readable `.md` file, while Keep has rows from it, keeps those rows, is named on stderr, and the run exits 1; other machines import as usual. An inbox with no readable files at all (a missing mount, say) deletes nothing and exits 1, on the first import too.
3. `keep search` lists the most recently changed files, or the ones matching your terms (each argument is one substring, so quote a phrase), optionally for one machine (`--source`) or agent (`--agent`).
4. On the central machine, you run `keep flag <id>` to write a snapshot of that item as a Markdown file right away: exactly what `keep show <id>` prints. Flag it again to refresh it after the file changes. Agents only write files.

The inbox is the record: Keep only reads it, and the database can be deleted and rebuilt from it with the same IDs.

## Install

Keep is a single Python file with no dependencies, installed on the central machine only. It needs Python 3.9+ with SQLite 3.24+ (`keep init` checks this).

```sh
git clone https://github.com/getaskclaw/keep
install -m 755 keep/keep ~/.local/bin/keep
```

## Usage

On each machine, from cron, with a name unique to that machine in place of `laptop`:

```sh
rsync -rt --include='*/' --include='*.md' --exclude='*' ~/hermes-notes/ central:keep-inbox/laptop/
```

rsync does not pass deletions on; delete files from the inbox to drop them from Keep.

On the central machine:

```sh
export KEEP_OUT=~/notes/keep        # where flagged Markdown goes (required by flag)

keep init
keep import ~/keep-inbox            # source = machine directory name
keep search                         # most recently changed first
keep search churn retention         # both words
keep search "disk full"             # the phrase
keep search --agent scout           # one agent's files
keep show 3f9a1c0b7e21              # IDs come from search
keep flag 3f9a1c0b7e21              # writes $KEEP_OUT/Items/3f9a1c0b7e21-q4-churn-md.md
```

Run `keep import` from cron, one at a time: `flock -n ~/.keep/import.lock keep import ~/keep-inbox`. `ls $KEEP_OUT/Items` shows what you have flagged; delete a file to unflag it. Flagging again overwrites the file. Read the output with any editor; pointing an Obsidian vault at it works but is optional.

## What it is not

- Not a sync tool. Machines push files; Keep only reads them.
- Not a note-taking app or two-way sync. Editing an item file never changes the database.
- Not a backup tool. Back up the inbox like any folder (see Rebuild and Non-goals in DESIGN.md).
- Not multi-user. Keep assumes one person and machines that person runs.
- Not a secret store. Keep sets no file permissions, and flagged items are exported verbatim; do not log credentials.

Design and schema: [DESIGN.md](DESIGN.md). Acceptance test: [acceptance.sh](acceptance.sh).

## License

MIT. See [LICENSE](LICENSE).
