#!/usr/bin/env bash
# End-to-end check of clones: profiles, parallel launch, MCP isolation, kill/rm/app/rename,
# Claude.app copies and the copy guard.
#
#   make e2e                       — on the scripts/fake-claude stub (works on Linux/CI too)
#   CLONES_E2E_REAL=1 make e2e     — on macOS with the real /Applications/Claude.app
#
# Profiles, metadata and launchers live in a temporary folder (CLONES_*_DIR) removed at the end.
# In REAL mode the default profile is your plain Claude: it is started and closed at the end (kill --all).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLONES="${CLONES:-$ROOT/.build/debug/clones}"
# pwd -P: on macOS /var → /private/var, and lsof reports real paths.
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/clones-e2e.XXXXXX")" && pwd -P)"
export CLONES_HOME="$SANDBOX/clones-home"
export CLONES_APPS_DIR="$SANDBOX/Applications"
export NO_COLOR=1
export CLONES_LANG=en   # the checks look for English messages
export CLONES_NO_AGENT=1   # never replace the real copy guard (it is tested with agent run --once)
REAL="${CLONES_E2E_REAL:-0}"
FAKE="$SANDBOX/Claude.app"
if [[ "$REAL" != 1 ]]; then
  # The stub has another bundle id so LaunchServices does not mix it up with the real Claude.
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME" "$FAKE/Contents/MacOS"
  cp "$ROOT/scripts/fake-claude/Info.plist" "$FAKE/Contents/Info.plist"
  cc -O2 -o "$FAKE/Contents/MacOS/Claude" "$ROOT/scripts/fake-claude/fake-claude.c"
  # Ad-hoc signed like the real Claude: profile copies are checked with codesign --verify.
  if [[ "$(uname)" == Darwin ]]; then codesign --force --sign - "$FAKE" >/dev/null; fi
  export CLONES_CLAUDE_APP="$FAKE"
fi
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

pass=0
fail=0
ok()   { echo "  ✓ $*"; pass=$((pass + 1)); }
bad()  { echo "  ✗ $*"; fail=$((fail + 1)); }
step() { echo; echo "== $*"; }
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

cleanup() {
  "$CLONES" kill --all --force --timeout 10 >/dev/null 2>&1 || true
  if [[ -x "$LSREGISTER" ]]; then
    for app in "$FAKE" "$CLONES_APPS_DIR"/*.app; do [[ -e "$app" ]] && "$LSREGISTER" -u "$app" 2>/dev/null; done
  fi
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

pid_of() { "$CLONES" ls --json --no-size | python3 -c "import json,sys; d={p['name']:p['pids'] for p in json.load(sys.stdin)['profiles']}; print(' '.join(map(str, d.get('$1', []))))"; }
dir_of() { "$CLONES" dir "$1"; }
# Gone = no process, or a zombie (containers without init never reap them).
gone()   { local st; st=$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' '); [[ -z "$st" || "$st" == Z* ]]; }
descendants() {
  local all="$1" frontier="$1" next
  while [[ -n "$frontier" ]]; do
    next=$(ps -axo pid=,ppid= | awk -v f=",$frontier," 'index(f, "," $2 ",") { printf "%s,", $1 }' | sed 's/,$//')
    [[ -n "$next" ]] && all="$all,$next"
    frontier="$next"
  done
  echo "$all"
}
wait_init() { for _ in $(seq 1 100); do [[ -e "$1/Local State" ]] && return 0; sleep 0.1; done; return 1; }

echo "clones: $CLONES"
echo "sandbox: $SANDBOX (real Claude: $REAL)"

step "1. Create profiles work and test"
"$CLONES" add work --color '#E5484D'
"$CLONES" add test --clone-mcp-from work
check "add created the launcher" test -x "$CLONES_APPS_DIR/Claude Work.app/Contents/MacOS/launcher"
check "the first profile also created “Claude Default”" test -x "$CLONES_APPS_DIR/Claude Default.app/Contents/MacOS/launcher"
"$CLONES" add nolauncher --no-app >/dev/null
check "--no-app: no launcher" test ! -e "$CLONES_APPS_DIR/Claude Nolauncher.app"
"$CLONES" rm nolauncher --force >/dev/null
check "duplicate name is rejected" bash -c "'$CLONES' add WORK 2>&1 | grep -q 'already exists'"
check "the name default is reserved" bash -c "'$CLONES' add default 2>&1 | grep -q 'reserved'"
"$CLONES" ls

step "2. Start default, work and test at once"
"$CLONES" run default
"$CLONES" run work
"$CLONES" run test
D=$(pid_of default); W=$(pid_of work); T=$(pid_of test)
echo "  PID: default=$D work=$W test=$T"
check "three different processes" test -n "$D" -a -n "$W" -a -n "$T" -a "$D" != "$W" -a "$W" != "$T" -a "$D" != "$T"
check "a second run work does not start another process" bash -c "'$CLONES' run work | grep -q 'already running' && [ \"\$('$CLONES' ls --json --no-size | grep -c '\"running\" : true')\" = 3 ]"

COPIES="$CLONES_HOME/.bundles.noindex"
exe_of() { ps -o args= -p "$1" | sed 's/ --user-data-dir=.*//'; }
check "work runs from its own Claude Work.app copy" bash -c "[[ \"\$(ps -o args= -p $W)\" == '$COPIES/work/Claude Work.app/Contents/MacOS/Claude '* ]]"
check "work gets its own Claude Code folder (CLAUDE_CONFIG_DIR)" bash -c "grep -q 'clones-home/work/claude-config' '$(dir_of work)/claude-config-dir.txt'"
check "default keeps the shared ~/.claude" bash -c "[ ! -s '$(dir_of default)/claude-config-dir.txt' ]"
check "default runs from its Claude Default copy, without --user-data-dir" bash -c "[[ \"\$(ps -o args= -p $D)\" == '$COPIES/default/Claude Default.app/Contents/MacOS/Claude' ]]"
echo "  ps:"
ps -o pid=,args= -p "$D,$W,$T" | sed 's/^/    /'
for name in default work test; do
  wait_init "$(dir_of "$name")" || true
done
for name in default work test; do
  pid=$(pid_of "$name"); dir=$(dir_of "$name")
  # lsof: the process keeps files open only in its own userData folder.
  # Chromium helper processes hold cookies, leveldb etc., so look at the whole process tree.
  tree=$(descendants "$pid")
  files=$(lsof -p "$tree" -Fn 2>/dev/null | sed -n 's/^n//p' || true)
  own=$(grep -cF "$dir/" <<<"$files" || true)
  foreign=0
  for other in default work test; do
    [[ "$other" == "$name" ]] && continue
    n=$(grep -cF "$(dir_of "$other")/" <<<"$files" || true); foreign=$((foreign + n))
  done
  if [[ "$own" -gt 0 && "$foreign" -eq 0 ]]; then ok "$name (PID $pid, processes: $(tr ',' '\n' <<<"$tree" | wc -l | tr -d ' ')): open files only in $dir ($own)"
  else bad "$name (PID $pid): own files $own, foreign $foreign"; fi
done
"$CLONES" ls

step "3. The MCP config of work is invisible to other profiles"
EDIT="$SANDBOX/editor.sh"
cat >"$EDIT" <<'EOF'
#!/bin/sh
cat >"$1" <<'JSON'
{ "mcpServers": { "e2e-only-work": { "command": "echo", "args": ["hello"] } } }
JSON
EOF
chmod +x "$EDIT"
EDITOR="$EDIT" "$CLONES" config work
check "work: server in claude_desktop_config.json" grep -q e2e-only-work "$(dir_of work)/claude_desktop_config.json"
check "test: no server" bash -c "! grep -q e2e-only-work '$(dir_of test)/claude_desktop_config.json'"
check "default: no server" bash -c "! grep -qs e2e-only-work '$(dir_of default)/claude_desktop_config.json'"
if [[ "$REAL" != 1 ]]; then
  "$CLONES" kill work && "$CLONES" run work && wait_init "$(dir_of work)"
  sleep 0.5
  check "restarted work loaded the server" grep -q e2e-only-work "$(dir_of work)/loaded-config.json"
  check "test has its own config (no server)" bash -c "! grep -q e2e-only-work '$(dir_of test)/loaded-config.json'"
fi

step "4. kill / rm / app / rename"
W=$(pid_of work)
"$CLONES" kill work
check "work exited" gone "$W"
if [[ "$REAL" != 1 ]]; then check "graceful exit (SIGTERM, not SIGKILL)" grep -q "quit pid=$W" "$(dir_of work)/main.log"; fi
check "kill of a stopped profile: clear error" bash -c "'$CLONES' kill work 2>&1 | grep -q 'not running'"
check "rm of running test without --force is refused" bash -c "! '$CLONES' rm test </dev/null"
check "rm without a TTY asks for --force" bash -c "'$CLONES' rm work </dev/null 2>&1 | grep -q 'force'"
T=$(pid_of test); TD=$(dir_of test)
"$CLONES" rm test --force
check "test closed" gone "$T"
check "test removed" bash -c "[ ! -e '$TD' ] && ! '$CLONES' dir test"
check "rm removed the Claude copy of test" test ! -e "$COPIES/test"
check "rm removed the launcher of test" test ! -e "$CLONES_APPS_DIR/Claude Test.app"

"$CLONES" app work
LAUNCHER="$CLONES_APPS_DIR/Claude Work.app"
check "launcher created" test -x "$LAUNCHER/Contents/MacOS/launcher"
check "launcher Info.plist carries the profile" grep -q ClonesProfile "$LAUNCHER/Contents/Info.plist"
if [[ "$(uname)" == Darwin ]]; then
  check "badge icon built" test -s "$LAUNCHER/Contents/Resources/AppIcon.icns"
  check "launcher Info.plist is valid" plutil -lint "$LAUNCHER/Contents/Info.plist"
fi
"$LAUNCHER/Contents/MacOS/launcher"
check "the launcher started work" test -n "$(pid_of work)"
"$CLONES" kill work

"$CLONES" rename work job
check "rename: data moved" test -e "$(dir_of job)/claude_desktop_config.json"
check "rename: launcher rebuilt" test -x "$CLONES_APPS_DIR/Claude Job.app/Contents/MacOS/launcher"
check "rename: old launcher gone" test ! -e "$LAUNCHER"
check "rename: copy moved (Claude Job.app)" bash -c "[ -x '$COPIES/job/Claude Job.app/Contents/MacOS/Claude' ] && [ ! -e '$COPIES/work' ]"
"$CLONES" add plain --no-copy --no-isolate-claude-code >/dev/null
"$CLONES" run plain >/dev/null
P=$(pid_of plain)
check "--no-copy: profile runs from the original Claude.app" bash -c "[[ \"\$(ps -o args= -p $P)\" != *bundles.noindex* ]]"
check "--no-isolate-claude-code: shared ~/.claude" bash -c "sleep 0.5; [ ! -s '$(dir_of plain)/claude-config-dir.txt' ]"
"$CLONES" rm plain --force >/dev/null
check "MCP server survived the rename" grep -q e2e-only-work "$(dir_of job)/claude_desktop_config.json"

# clones 0.1.0 put CLAUDE_CONFIG_DIR into <profile>/claude-code, the folder Claude Desktop clears on updates.
JOB="$(dir_of job)"
OLD_CC="$JOB/claude-code"
mkdir -p "$OLD_CC/2.1.304" "$OLD_CC/projects/p"
echo '{}' > "$OLD_CC/projects/p/s.jsonl"
"$CLONES" run job >/dev/null
python3 -c "import json,sys; f=sys.argv[1]; c=json.load(open(f)); c['profiles']['job']['env']={'CLAUDE_CONFIG_DIR': sys.argv[2]}; json.dump(c, open(f,'w'))" "$CLONES_HOME/.config.json" "$OLD_CC"
check "a running 0.1.0-style profile is left alone, with a warning" bash -c "'$CLONES' ls --no-size 2>&1 | grep -q 'clears when it updates' && [ -e '$OLD_CC/projects/p/s.jsonl' ]"
"$CLONES" kill job >/dev/null 2>&1
check "once closed, its Claude Code moves to claude-config" bash -c "'$CLONES' ls --no-size 2>&1 | grep -q 'Claude Code moved' && [ -e '$JOB/claude-config/projects/p/s.jsonl' ] && [ -d '$OLD_CC/2.1.304' ] && [ ! -e '$OLD_CC/projects' ]"
check "the launcher's fallback points at claude-config" bash -c "grep -q 'job/claude-config' '$CLONES_APPS_DIR/Claude Job.app/Contents/MacOS/launcher' && [ -x '$CLONES_APPS_DIR/Claude Job.app/Contents/MacOS/launcher' ]"
"$CLONES" run job >/dev/null
check "job now runs with CLAUDE_CONFIG_DIR=claude-config" bash -c "sleep 0.5; grep -q 'job/claude-config' '$JOB/claude-config-dir.txt'"
"$CLONES" kill job >/dev/null

step "5. doctor, kill --all, copy guard"
"$CLONES" doctor || true
"$CLONES" kill --all
check "no instances left" bash -c "'$CLONES' ls --json --no-size | grep -q '\"running\" : true' && exit 1 || exit 0"
# A copy opened directly (no --user-data-dir) runs on the default data; doctor must notice.
"$COPIES/job/Claude Job.app/Contents/MacOS/Claude" </dev/null >/dev/null 2>&1 &
STRAY=$!
sleep 1
check "doctor notices a copy opened directly" bash -c "'$CLONES' doctor 2>&1 | grep -q 'opened directly'"
check "ls warns about a copy without its profile" bash -c "'$CLONES' ls --no-size 2>&1 | grep -q 'running without its profile'"
"$CLONES" agent run --once
check "the guard closed the copy without a profile" gone "$STRAY"
check "the guard started job properly" bash -c "[[ \"\$(ps -o args= -p \$('$CLONES' ls --json --no-size | python3 -c \"import json,sys;print([p['pids'][0] for p in json.load(sys.stdin)['profiles'] if p['name']=='job'][0])\"))\" == *--user-data-dir=*clones-home/job* ]]"
"$CLONES" kill --all >/dev/null
wait "$STRAY" 2>/dev/null || true
"$CLONES" ls

"$CLONES" app default --remove >/dev/null
"$CLONES" app --all >/dev/null
check "app --all does not bring back a removed Claude Default" test ! -e "$CLONES_APPS_DIR/Claude Default.app"
"$CLONES" add later >/dev/null
check "later profiles do not bring it back either" test ! -e "$CLONES_APPS_DIR/Claude Default.app"
"$CLONES" app job --remove >/dev/null
check "app --remove removed launcher and copy" bash -c "[ ! -e '$CLONES_APPS_DIR/Claude Job.app' ] && [ ! -e '$COPIES/job' ] && '$CLONES' dir job"

echo
echo "Total: $pass ok, $fail failed"
[[ "$fail" -eq 0 ]]
