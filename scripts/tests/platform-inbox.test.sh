#!/usr/bin/env bash
# Tests for scripts/platform-inbox.sh. gcloud, chown and chgrp are stubs; the
# gcloud stub mirrors the top level of a fake bucket directory, and the install
# stub records its arguments and runs the real install without -o/-g, so the
# tests do not need root.
#
#   bash scripts/tests/platform-inbox.test.sh
set -euo pipefail

SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ORIG_PATH="$PATH"
REAL_INSTALL="$(command -v install)"
export REAL_INSTALL
FAILURES=0
WORK=""

fail(){ echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }

assert_eq(){
  if [ "$1" != "$2" ]; then
    fail "$3: expected '$2', got '$1'"
  fi
}

stub(){
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_LOG"\n%s\n' "$1" "$2" > "$WORK/bin/$1"
  chmod +x "$WORK/bin/$1"
}

# mode <path>: the permission bits in octal (GNU or BSD stat).
mode(){ stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# metadata <jq object of app values>: writes the metadata file.
metadata(){ jq -cn "$1 | with_entries(.value |= tojson)" > "$PLATFORM_METADATA_FILE"; }

default_metadata(){
  metadata '{
    "vm-app-film-picker": {name: "film-picker", port: 4100, domains: ["fp.example.com"], inbox_bucket: "fp-inbox", deploy_user: "sa_1"},
    "vm-app-other": {name: "other", port: 4200, domains: ["other.example.com"], inbox_bucket: "other-inbox", deploy_user: "sa_2"},
    "vm-app-nobucket": {name: "nobucket", port: 4300, domains: ["nb.example.com"], inbox_bucket: null, deploy_user: "sa_3"}
  }'
}

setup(){
  WORK="$(mktemp -d)"
  export PLATFORM_METADATA_FILE="$WORK/metadata.json" PLATFORM_CONF="$WORK/platform.conf"
  export STUB_LOG="$WORK/calls.log" BUCKETS="$WORK/buckets" RSYNC_FAIL=""
  export INBOX_DIR="$WORK/var/inbox" INBOX_STAGING_DIR="$WORK/var/inbox-staging"
  printf 'RELEASES_BUCKET=rel\nBACKUPS_BUCKET=bak\n' > "$PLATFORM_CONF"
  default_metadata
  mkdir -p "$WORK/bin" "$BUCKETS/fp-inbox" "$BUCKETS/other-inbox"
  touch "$STUB_LOG"
  # gcloud storage rsync [--delete-unmatched-destination-objects] gs://<bucket> <dest>:
  # top level only, like gcloud without --recursive. A bucket in RSYNC_FAIL is
  # copied and then fails, as a half-done rsync would.
  stub gcloud 'shopt -s nullglob dotglob
[ "$1 $2" = "storage rsync" ] || exit 9
delete=0
[ "$3" = --delete-unmatched-destination-objects ] && { delete=1; shift; }
bucket="${3#gs://}" dest="$4" src="$BUCKETS/${3#gs://}"
[ -d "$src" ] && [ -d "$dest" ] || exit 8
if [ "$delete" = 1 ]; then
  for f in "$dest"/*; do [ -e "$src/${f##*/}" ] || rm -rf "$f"; done
fi
for f in "$src"/*; do [ -f "$f" ] && cp -p "$f" "$dest/"; done
case " $RSYNC_FAIL " in *" $bucket "*) exit 1 ;; esac
exit 0'
  stub chown 'exit 0'
  stub chgrp 'exit 0'
  stub install 'args=()
while [ $# -gt 0 ]; do
  case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
done
exec "$REAL_INSTALL" "${args[@]}"'
  export PATH="$WORK/bin:$ORIG_PATH"
}

teardown(){
  export PATH="$ORIG_PATH"
  chmod -R u+rwx "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}

run_inbox(){ bash "$SCRIPTS/platform-inbox.sh" > "$WORK/out.log" 2>&1; }

put(){ mkdir -p "$(dirname "$BUCKETS/$1")"; printf '%s' "$2" > "$BUCKETS/$1"; }

old(){ touch -t 200001010000 "$@"; }

test_new_object(){
  put fp-inbox/a.csv "one"
  run_inbox || fail "inbox exited non-zero: $(cat "$WORK/out.log")"
  assert_eq "$(cat "$INBOX_DIR/film-picker/a.csv" 2>/dev/null)" "one" "published content"
  assert_eq "$(mode "$INBOX_DIR/film-picker/a.csv")" "640" "file mode"
  assert_eq "$(mode "$INBOX_DIR/film-picker")" "750" "inbox dir mode"
  assert_eq "$(mode "$INBOX_STAGING_DIR/film-picker")" "700" "staging dir mode"
  grep -q "^install -m 640 -o root -g app-film-picker $INBOX_STAGING_DIR/film-picker/a.csv $INBOX_DIR/film-picker/.tmp.a.csv$" "$STUB_LOG" \
    || fail "install not called with the app group via a temp name: $(grep '^install' "$STUB_LOG")"
  grep -q "^chown root:app-film-picker $INBOX_DIR/film-picker$" "$STUB_LOG" || fail "inbox dir not chowned to root:app-film-picker"
  grep -q "^gcloud storage rsync --delete-unmatched-destination-objects gs://fp-inbox $INBOX_STAGING_DIR/film-picker$" "$STUB_LOG" \
    || fail "rsync call: $(grep '^gcloud' "$STUB_LOG")"
  grep -q "film-picker: 1 added, 0 updated, 0 removed" "$WORK/out.log" || fail "summary line: $(cat "$WORK/out.log")"
  assert_eq "$(find "$INBOX_DIR/film-picker" -name '.tmp.*')" "" "temp file left behind"
}

test_changed_and_unchanged(){
  put fp-inbox/a.csv "one"
  put fp-inbox/b.csv "keep"
  run_inbox || fail "first run: $(cat "$WORK/out.log")"
  old "$INBOX_DIR/film-picker/a.csv" "$INBOX_DIR/film-picker/b.csv"
  touch -t 201001010000 "$WORK/marker"
  put fp-inbox/a.csv "two"
  : > "$STUB_LOG"
  run_inbox || fail "second run: $(cat "$WORK/out.log")"
  assert_eq "$(cat "$INBOX_DIR/film-picker/a.csv")" "two" "changed content"
  [ "$INBOX_DIR/film-picker/b.csv" -ot "$WORK/marker" ] || fail "unchanged file was rewritten"
  if grep -q "b.csv" "$STUB_LOG"; then fail "install called for the unchanged file"; fi
  grep -q "film-picker: 0 added, 1 updated, 0 removed" "$WORK/out.log" || fail "summary line: $(cat "$WORK/out.log")"
}

test_removed_object(){
  put fp-inbox/a.csv "one"
  put fp-inbox/b.csv "two"
  run_inbox || fail "first run: $(cat "$WORK/out.log")"
  rm "$BUCKETS/fp-inbox/a.csv"
  run_inbox || fail "second run: $(cat "$WORK/out.log")"
  [ ! -e "$INBOX_DIR/film-picker/a.csv" ] || fail "removed object still in the inbox"
  [ -f "$INBOX_DIR/film-picker/b.csv" ] || fail "remaining object gone"
  grep -q "film-picker: 0 added, 0 updated, 1 removed" "$WORK/out.log" || fail "summary line: $(cat "$WORK/out.log")"
}

test_app_without_bucket(){
  run_inbox || fail "inbox exited non-zero: $(cat "$WORK/out.log")"
  [ ! -e "$INBOX_DIR/nobucket" ] || fail "inbox dir created for an app without a bucket"
  [ ! -e "$INBOX_STAGING_DIR/nobucket" ] || fail "staging dir created for an app without a bucket"
  if grep -q nobucket "$STUB_LOG"; then fail "app without a bucket touched"; fi
}

test_rsync_failure(){
  put fp-inbox/a.csv "one"
  run_inbox || fail "first run: $(cat "$WORK/out.log")"
  put fp-inbox/a.csv "two"
  put fp-inbox/c.csv "new"
  put other-inbox/o.csv "other"
  export RSYNC_FAIL=fp-inbox
  if run_inbox; then fail "inbox must fail when an rsync fails"; fi
  assert_eq "$(cat "$INBOX_DIR/film-picker/a.csv")" "one" "inbox changed after a failed rsync"
  [ ! -e "$INBOX_DIR/film-picker/c.csv" ] || fail "file published after a failed rsync"
  assert_eq "$(cat "$INBOX_DIR/other/o.csv" 2>/dev/null)" "other" "other app not processed"
  grep -qi "warning:.*film-picker" "$WORK/out.log" || fail "no warning for the failed app: $(cat "$WORK/out.log")"
}

test_inbox_symlink_replaced(){
  put fp-inbox/a.csv "one"
  mkdir -p "$INBOX_DIR" "$WORK/elsewhere"
  printf 'theirs' > "$WORK/elsewhere/keep.txt"
  ln -s "$WORK/elsewhere" "$INBOX_DIR/film-picker"
  run_inbox || fail "inbox exited non-zero: $(cat "$WORK/out.log")"
  [ ! -L "$INBOX_DIR/film-picker" ] && [ -d "$INBOX_DIR/film-picker" ] || fail "symlink not replaced by a real directory"
  assert_eq "$(cat "$INBOX_DIR/film-picker/a.csv" 2>/dev/null)" "one" "published content"
  assert_eq "$(ls -A "$WORK/elsewhere")" "keep.txt" "symlink target touched"
  assert_eq "$(cat "$WORK/elsewhere/keep.txt")" "theirs" "symlink target content"
}

test_inbox_file_replaced(){
  put fp-inbox/a.csv "one"
  mkdir -p "$INBOX_DIR"
  printf 'x' > "$INBOX_DIR/film-picker"
  run_inbox || fail "inbox exited non-zero: $(cat "$WORK/out.log")"
  [ -d "$INBOX_DIR/film-picker" ] || fail "file not replaced by a directory"
  assert_eq "$(cat "$INBOX_DIR/film-picker/a.csv" 2>/dev/null)" "one" "published content"
}

test_symlinked_entry_replaced(){
  put fp-inbox/a.csv "one"
  mkdir -p "$INBOX_DIR/film-picker"
  printf 'one' > "$WORK/outside"
  ln -s "$WORK/outside" "$INBOX_DIR/film-picker/a.csv"
  ln -s "$WORK/outside" "$INBOX_DIR/film-picker/.tmp.a.csv"
  run_inbox || fail "inbox exited non-zero: $(cat "$WORK/out.log")"
  [ ! -L "$INBOX_DIR/film-picker/a.csv" ] && [ -f "$INBOX_DIR/film-picker/a.csv" ] || fail "symlinked entry not replaced"
  assert_eq "$(cat "$WORK/outside")" "one" "symlink target written"
  [ ! -e "$INBOX_DIR/film-picker/.tmp.a.csv" ] && [ ! -L "$INBOX_DIR/film-picker/.tmp.a.csv" ] || fail "stale temp entry left"
}

test_nested_object_ignored(){
  put fp-inbox/a.csv "one"
  put fp-inbox/sub/x.csv "nested"
  run_inbox || fail "inbox exited non-zero: $(cat "$WORK/out.log")"
  [ ! -e "$INBOX_DIR/film-picker/sub" ] || fail "nested prefix published"
  [ ! -e "$INBOX_DIR/film-picker/x.csv" ] || fail "nested object published"
  [ -f "$INBOX_DIR/film-picker/a.csv" ] || fail "top-level object missing"
}

test_reserved_temp_name_skipped(){
  put fp-inbox/.tmp.a.csv "sneaky"
  put fp-inbox/a.csv "one"
  run_inbox || fail "inbox exited non-zero: $(cat "$WORK/out.log")"
  assert_eq "$(cat "$INBOX_DIR/film-picker/a.csv")" "one" "published content"
  [ ! -e "$INBOX_DIR/film-picker/.tmp.a.csv" ] || fail "reserved temp name published"
}

test_gone_apps_cleaned(){
  put fp-inbox/a.csv "one"
  put other-inbox/o.csv "other"
  run_inbox || fail "first run: $(cat "$WORK/out.log")"
  mkdir -p "$WORK/elsewhere"
  ln -s "$WORK/elsewhere" "$INBOX_DIR/ghost"
  metadata '{
    "vm-app-film-picker": {name: "film-picker", port: 4100, domains: ["fp.example.com"], deploy_user: "sa_1"}
  }'
  run_inbox || fail "second run: $(cat "$WORK/out.log")"
  [ ! -e "$INBOX_DIR/other" ] || fail "inbox of a removed app kept"
  [ ! -e "$INBOX_STAGING_DIR/other" ] || fail "staging of a removed app kept"
  [ ! -e "$INBOX_DIR/film-picker" ] || fail "inbox of an app without a bucket kept"
  [ ! -e "$INBOX_STAGING_DIR/film-picker" ] || fail "staging of an app without a bucket kept"
  [ ! -L "$INBOX_DIR/ghost" ] || fail "stray symlink kept"
  [ -d "$WORK/elsewhere" ] || fail "stray symlink target removed"
}

test_invalid_app_keeps_inbox(){
  put other-inbox/o.csv "other"
  run_inbox || fail "first run: $(cat "$WORK/out.log")"
  metadata '{
    "vm-app-other": {name: "other", port: 1, domains: ["other.example.com"], inbox_bucket: "other-inbox", deploy_user: "sa_2"}
  }'
  run_inbox || true
  assert_eq "$(cat "$INBOX_DIR/other/o.csv" 2>/dev/null)" "other" "inbox of an invalid app removed"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  echo "$t"
  setup
  "$t"
  teardown
done

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES failure(s)"
  exit 1
fi
echo "all tests passed"
