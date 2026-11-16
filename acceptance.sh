#!/bin/sh
# acceptance.sh — exits non-zero on the first failure
set -eu
T=$(mktemp -d); I=$T/inbox; S=$T
trap 'chmod -R u+rwx "$T"; rm -rf "$T" "$S"' EXIT
export CLEE_DB=$T/db/sub/clee.db CLEE_OUT=$T/out
n()   { sqlite3 "$CLEE_DB" "SELECT count(*) FROM items WHERE $1"; }
q()   { sqlite3 "$CLEE_DB" "SELECT $1 FROM items WHERE $2"; }
idof() { q id "path='$1'"; }
no()  { rc=0; sh -c "$1" >/dev/null 2>"$T/err" || rc=$?   # stderr kept in $T/err
        [ "$rc" -eq 1 ] || { echo "FAIL, want exit 1, got $rc: $1"; exit 1; }; }
hits() { clee search "$@" >"$T/hits"; h=$(wc -l <"$T/hits"); }  # keeps search's exit code
put() { mkdir -p "$(dirname "$I/$1")"; printf '%s\n' "$2" >"$I/$1"; }

# init creates missing directories, is safe to rerun, and refuses other schemas
clee init; clee init; [ -f "$CLEE_DB" ]
sqlite3 "$T/old.db" "CREATE TABLE items (id INTEGER PRIMARY KEY)"
no "CLEE_DB='$T/old.db' clee init"; no "CLEE_DB='$T/old.db' clee search"
sqlite3 "$T/old.db" "PRAGMA user_version = 1"; no "CLEE_DB='$T/old.db' clee search"

# import: source is the machine directory; *.md only, empty files and
# dot-directories too; the ID comes from source/path
for i in $(seq 20); do put "vps1/logs/row-$i.md" "row $i"; done
put vps2/a.md "部署完成，数据库迁移成功"
put vps2/b.md "see foo-bar and a:b, done_ok, été"
put vps2/notes.txt "not markdown"; : >"$I/vps2/empty.md"; put stray.md "no machine"
put vps2/.claude/memo.md x
clee import "$I"
[ "$(n 1)" -eq 24 ]; [ "$(n "source='vps1' AND path LIKE 'logs/row-%.md'")" -eq 20 ]
[ "$(n "source='vps2' AND path='empty.md' AND body=''")" -eq 1 ]
[ "$(n "source='vps2' AND path='.claude/memo.md'")" -eq 1 ]
[ "$(idof a.md)" = "$(printf vps2/a.md | sha256sum | cut -c1-12)" ]

# one row per source and path, holding the latest version; reruns add nothing
clee import "$I"; [ "$(n 1)" -eq 24 ]
put vps2/c.md "version-one"; clee import "$I"; c=$(idof c.md)
put vps2/c.md "version-two"; clee import "$I"; clee import "$I"
hash=$(sha256sum <"$I/vps2/c.md" | cut -d' ' -f1)
[ "$(n "path='c.md'")" -eq 1 ]; [ "$(idof c.md)" = "$c" ]
[ "$(n "id='$c' AND body LIKE 'version-two%' AND sha256='$hash'")" -eq 1 ]
hits version-one; [ "$h" -eq 0 ]; hits version-two; [ "$h" -eq 1 ]
: >"$I/vps2/c.md"; clee import "$I"; [ "$(n "id='$c' AND body=''")" -eq 1 ]
put vps1/same.md "same"; put vps3/same.md "same"; clee import "$I"
[ "$(n "path='same.md'")" -eq 2 ]

# a file gone from the inbox loses its row; back again, it has the same ID
put vps3/other.md other; clee import "$I"
s3=$(q id "source='vps3' AND path='same.md'"); rm "$I/vps3/same.md"; clee import "$I"
[ "$(n "source='vps3'")" -eq 1 ]
put vps3/same.md "same"; clee import "$I"; [ "$(q id "source='vps3' AND path='same.md'")" = "$s3" ]

# a machine directory with no readable .md file, while the DB has rows from
# it, keeps those rows and import exits 1; other machines import as usual
# (a new empty machine is no error); a machine directory deleted from the
# inbox loses its rows
put vps1/gone.md gone; clee import "$I"; rm "$I/vps1/gone.md"; put vps1/new.md new
mv "$I/vps3" "$T/vps3"; mkdir "$I/vps3" "$I/vps8"; no "clee import '$I'"
[ "$(cat "$T/err")" = "clee: no readable .md files in $I/vps3; deleted nothing from it" ]
[ "$(n "source='vps3'")" -eq 2 ]; [ "$(n "path='gone.md'")" -eq 0 ]; [ "$(n "path='new.md'")" -eq 1 ]
rmdir "$I/vps3" "$I/vps8"; clee import "$I"; [ "$(n "source='vps3'")" -eq 0 ]
mv "$T/vps3" "$I/vps3"; rm "$I/vps1/new.md"; clee import "$I"
[ "$(q id "source='vps3' AND path='same.md'")" = "$s3" ]

# a skipped file is named on stderr and import exits 1; the rest still
# imports, and nothing is deleted from that machine; other machines are
printf 'ok\377\n' >"$I/vps2/bin.md"; printf '\000afternul\n' >"$I/vps2/zero.md"
bad=$I/vps2/$(printf 'bad\377').md; printf x >"$bad"; rm "$I/vps2/empty.md"
rm "$I/vps1/same.md"
no "clee import '$I'"; grep -qxF "clee: skipped $I/vps2/bin.md: not UTF-8" "$T/err"
grep -qxF "clee: skipped $I/vps2/bad\\xff.md: not UTF-8" "$T/err"
[ "$(wc -l <"$T/err")" -eq 2 ]
[ "$(n "path='bin.md'")" -eq 0 ]; [ "$(n "path='zero.md'")" -eq 1 ]
[ "$(n "path='empty.md'")" -eq 1 ]; [ "$(n "source='vps1' AND path='same.md'")" -eq 0 ]
rm "$I/vps2/bin.md" "$bad"; clee import "$I"; [ "$(n "path='empty.md'")" -eq 0 ]
if [ "$(id -u)" -ne 0 ]; then                   # root can read anything
  put vps2/locked/x.md x; clee import "$I"
  put vps2/noread.md x; chmod 000 "$I/vps2/noread.md" "$I/vps2/locked"
  no "clee import '$I'"
  grep -qxF "clee: skipped $I/vps2/noread.md: Permission denied" "$T/err"
  grep -qxF "clee: skipped $I/vps2/locked: Permission denied" "$T/err"
  [ "$(n "path='locked/x.md'")" -eq 1 ]
  chmod 700 "$I/vps2/locked"; rm -r "$I/vps2/noread.md" "$I/vps2/locked"
  clee import "$I"; [ "$(n "path='locked/x.md'")" -eq 0 ]
fi

# an ID already taken by another file: the file is skipped, naming both
put vps2/clash.md x; cl=$(printf vps2/clash.md | sha256sum | cut -c1-12)
sqlite3 "$CLEE_DB" "INSERT INTO items(id, source, path, agent, created_at,
  updated_at, sha256, body) VALUES ('$cl', 'vps2', 'ghost.md', '', '', '', '', '')"
no "clee import '$I'"
grep -qxF "clee: skipped $I/vps2/clash.md: ID $cl is taken by vps2/ghost.md" "$T/err"
[ "$(n "id='$cl' AND path='ghost.md'")" -eq 1 ]
sqlite3 "$CLEE_DB" "DELETE FROM items WHERE id='$cl'"; clee import "$I"
[ "$(n "id='$cl' AND path='clash.md'")" -eq 1 ]; rm "$I/vps2/clash.md"; clee import "$I"

# an inbox with no readable .md files deletes nothing and exits 1
mkdir -p "$T/void/vps1"; before=$(n 1); no "clee import '$T/void'"
[ "$(cat "$T/err")" = "clee: no readable .md files in $T/void; deleted nothing" ]
[ "$(n 1)" -eq "$before" ]
CLEE_DB=$T/first.db clee init; no "CLEE_DB='$T/first.db' clee import '$T/void'"
[ "$(cat "$T/err")" = "clee: no readable .md files in $T/void; deleted nothing" ]

# a file whose mtime is past year 9999 is skipped; the rest still imports
# (needs a filesystem that keeps such mtimes, such as tmpfs)
S=$(mktemp -d -p /dev/shm 2>/dev/null) || S=$T
mkdir "$S/vps1"; echo ok >"$S/vps1/ok.md"; : >"$S/vps1/far.md"; : >"$S/vps1/huge.md"
touch -d @300000000000 "$S/vps1/far.md"; touch -d @4611686018427387904 "$S/vps1/huge.md" || :
if [ "$(stat -c %Y "$S/vps1/far.md" "$S/vps1/huge.md" | tr '\n' ' ')" = "300000000000 4611686018427387904 " ]; then
  CLEE_DB=$T/far.db clee init; no "CLEE_DB='$T/far.db' clee import '$S'"
  printf 'clee: skipped %s/vps1/%s.md: mtime out of range\n' "$S" far "$S" huge | cmp - "$T/err"
  [ "$(sqlite3 "$T/far.db" "SELECT path FROM items")" = ok.md ]
else echo "skipped the mtime case: no filesystem here keeps such mtimes"
fi

# an argument that is not UTF-8 is one line on stderr, not a traceback
for cmd in "search" "search --source" "show" "import"; do
  no "clee $cmd 'x$(printf '\377')'"
  [ "$(cat "$T/err")" = "clee: argument is not UTF-8: x\\xff" ]
done

# symlinks and other non-regular files are ignored without a message
before=$(n 1); ln -s a.md "$I/vps2/link.md"; mkfifo "$I/vps2/fifo.md"
ln -s ../vps1 "$I/vps2/sub"; ln -s vps1 "$I/vps9"
clee import "$I" 2>"$T/err"; [ ! -s "$T/err" ]; [ "$(n 1)" -eq "$before" ]

# invalid input writes nothing; only init creates a DB
no "clee import '$T/missing'"; no "clee show 000000000000"; no "clee flag 000000000000"
no "clee search x --limit 0"; no "clee search --limit abc"; no "env -u CLEE_OUT clee flag $c"
no "clee search --bogus"; no "clee show"
no "CLEE_DB='$T/none/clee.db' clee search"; [ ! -e "$T/none" ]
[ "$(n 1)" -eq "$before" ]; [ ! -e "$CLEE_OUT" ]

# search: CJK, punctuation, wildcards, case, text after a NUL, phrases,
# no hits, no terms
hits 数据库;        [ "$h" -eq 1 ]
hits 部署;          [ "$h" -eq 1 ]
hits foo-bar;       [ "$h" -eq 1 ]
hits a:b;           [ "$h" -eq 1 ]
hits FOO-BAR ok;    [ "$h" -eq 1 ]
hits ÉTÉ;           [ "$h" -eq 1 ]
hits _;             [ "$h" -eq 1 ]
hits %%;            [ "$h" -eq 0 ]
hits afternul;      [ "$h" -eq 1 ]
hits 'see foo';     [ "$h" -eq 1 ]             # one argument: one substring
hits 'foo see';     [ "$h" -eq 0 ]
hits foo see;       [ "$h" -eq 1 ]             # several arguments: all match
hits 'done_ok, ÉTÉ'; [ "$h" -eq 1 ]
hits AND;           hits '"'
hits row --limit 5; [ "$h" -eq 5 ]
hits same --source vps3; [ "$h" -eq 1 ]
hits;               [ "$h" -eq 20 ]             # every row, default limit
clee search --limit 1000 2>"$T/err" | :; [ ! -s "$T/err" ]  # closed pipe: quiet

# newest first: an old row whose content changed comes back to the top
put vps2/b.md "b again"; touch -d '2030-01-01 00:00:00 UTC' "$I/vps2/b.md"
clee import "$I"; hits
printf '%s\t2030-01-01T00:00:00Z\tvps2\tb.md\n' "$(idof b.md)" >"$T/want"
head -1 "$T/hits" | cmp - "$T/want"

# metadata: created_at is the mtime at first import when the frontmatter has
# none; updated_at is the mtime when the content last changed (a touch alone
# changes nothing); imported_at is set when the row is added
am() { q "agent||'|'||created_at" "path='$1'"; }
[ "$(n "imported_at GLOB '20[0-9][0-9]-[01][0-9]-[0-3][0-9]T*Z'")" -eq "$(n 1)" ]
put vps1/m.md m1; touch -d '2026-01-02 03:04:05 UTC' "$I/vps1/m.md"; clee import "$I"
m=$(idof m.md); [ "$(am m.md)" = "|2026-01-02T03:04:05Z" ]
[ "$(q updated_at "id='$m'")" = 2026-01-02T03:04:05Z ]
touch -d '2026-02-03 04:05:06 UTC' "$I/vps1/m.md"; clee import "$I"
[ "$(q updated_at "id='$m'")" = 2026-01-02T03:04:05Z ]
sqlite3 "$CLEE_DB" "UPDATE items SET imported_at='2000-01-01T00:00:00Z' WHERE id='$m'"
put vps1/m.md m2; touch -d '2026-03-04 05:06:07 UTC' "$I/vps1/m.md"
clee import "$I"; clee import "$I"
[ "$(am m.md)|$(q updated_at "id='$m'")" = "|2026-01-02T03:04:05Z|2026-03-04T05:06:07Z" ]
[ "$(n "id='$m' AND source='vps1' AND body LIKE 'm2%' AND imported_at LIKE '2000-%'")" -eq 1 ]

# agent: the frontmatter's agent, else <name> from profiles/<name>/ in the
# path, else empty; agent and created_at are read again from each new version
p=.hermes/profiles/scout; put "vps1/$p/notes/p.md" p; put vps1/profiles/x.md x
printf '%s\n' --- 'agent: "ranger"' "created_at: '2025-12-31T23:59:59Z'" --- q >"$I/vps1/$p/q.md"
printf '%s\n' text --- 'agent: x' --- >"$I/vps1/nf.md"; printf '%s\n' --- 'agent: x' >"$I/vps1/un.md"
clee import "$I"
[ "$(q agent "path='$p/notes/p.md'")" = scout ]
[ "$(am "$p/q.md")" = "ranger|2025-12-31T23:59:59Z" ]
[ "$(n "path IN ('profiles/x.md', 'nf.md', 'un.md') AND agent=''")" -eq 3 ]
printf '%s\n' --- 'agent: warden' --- q2 >"$I/vps1/$p/q.md"; clee import "$I"
[ "$(am "$p/q.md")" = "warden|2025-12-31T23:59:59Z" ]
printf '%s\n' --- 'created_at: 2026-06-01T00:00:00Z' '  agent: nested' --- q3 >"$I/vps1/$p/q.md"
clee import "$I"; [ "$(am "$p/q.md")" = "scout|2026-06-01T00:00:00Z" ]

# --agent keeps the rows whose agent is exactly the name
hits --agent scout; [ "$h" -eq 2 ]; hits q3 --agent scout; [ "$h" -eq 1 ]
hits --agent Scout; [ "$h" -eq 0 ]; hits --agent scout --source vps2; [ "$h" -eq 0 ]
hits --agent ranger; [ "$h" -eq 0 ]

# show: Clee's frontmatter, then the file byte for byte (its own frontmatter,
# CRLF and a missing final newline included); non-ASCII stays as UTF-8,
# characters YAML forbids are escaped
printf '%s\r\n' --- 'agent: scout' --- >"$I/vps2/fm.md"; printf 'no final newline' >>"$I/vps2/fm.md"
clee import "$I"; clee show "$(idof fm.md)" >"$T/show"
tail -n +11 "$T/show" | cmp - "$I/vps2/fm.md"
grep -qx "sha256: \"$(q sha256 "path='fm.md'")\"" "$T/show"; grep -qxF 'agent: "scout"' "$T/show"
put vps1/日志😀.md x; put "vps1/del$(printf '\177').md" x; clee import "$I"
clee show "$(idof 日志😀.md)" >"$T/show"; grep -qxF 'path: "日志😀.md"' "$T/show"
clee show "$(q id "path LIKE 'del%'")" >"$T/show"; grep -qxF 'path: "del\u007f.md"' "$T/show"

# flag writes the item file now, exactly what show printed; imports leave it
# alone; flagging again rewrites it
put "vps1/Disk: Full!.md" "disk full on db-1"; clee import "$I"
id=$(idof 'Disk: Full!.md'); f=$CLEE_OUT/Items/$id-disk-full-md.md
clee show "$id" >"$T/show"; clee flag "$id"; cmp "$f" "$T/show"
[ "$(sed -n '2,9p' "$f" | cut -d: -f1 | tr '\n' ' ')" = "clee_id source path agent created_at updated_at imported_at sha256 " ]
put "vps1/Disk: Full!.md" "disk full again"; clee import "$I"; cmp "$f" "$T/show"
clee flag "$id"; [ "$(grep -c 'disk full again' "$f")" -eq 1 ]
[ "$(ls -A "$CLEE_OUT/Items")" = "$id-disk-full-md.md" ]
HOME=$T CLEE_OUT='~/home-out' clee flag "$id"; [ -f "$T/home-out/Items/$id-disk-full-md.md" ]

# slug: runs outside [A-Za-z0-9] become -, then lowercased, cut to 40
put "vps1/notes/Quarterly Review — Churn & Retention 2026 Final.md" qr; clee import "$I"
s=$(idof 'notes/Quarterly Review — Churn & Retention 2026 Final.md'); clee flag "$s"
[ -f "$CLEE_OUT/Items/$s-quarterly-review-churn-retention-2026-fi.md" ]

# a failing flag exits 1
: >"$T/notadir"; no "CLEE_OUT='$T/notadir' clee flag $id"

# a file or directory name cannot inject frontmatter or split a search line
put "vps1
evil: 1/x
---
evil: 2.md" body; clee import "$I"
j=$(q id "path LIKE 'x%'")
clee flag "$j"
[ "$(grep -c '^evil:' "$CLEE_OUT"/Items/"$j"-*.md)" -eq 0 ]
hits evil; [ "$h" -eq 1 ]; [ "$(cut -f1 "$T/hits")" = "$j" ]

# rebuild from the inbox: the same rows, IDs and agents included; created_at
# from frontmatter survives, the mtime fallback becomes the current mtime
rows="SELECT id, source, path, agent, sha256, body FROM items ORDER BY id"
sqlite3 "$CLEE_DB" "$rows" >"$T/before"
rm "$CLEE_DB"; clee init; clee import "$I"
sqlite3 "$CLEE_DB" "$rows" | cmp - "$T/before"
[ "$(am "$p/q.md")" = "scout|2026-06-01T00:00:00Z" ]
[ "$(am m.md)|$(q updated_at "id='$m'")" = "|2026-03-04T05:06:07Z|2026-03-04T05:06:07Z" ]

echo "all acceptance cases passed"
