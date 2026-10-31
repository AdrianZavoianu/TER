#!/usr/bin/env bash
# Headless smoke test for devc: builds a throwaway project on the devc tmux
# socket, asserts panes/scale/restart/logs/stop, cleans up after itself.
set -euo pipefail

DEVC="$(cd "$(dirname "$0")" && pwd)/devc"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/devc-selftest-XXXXXX")
PROJ=$(basename "$TMP")
SES="devc-$PROJ"
T() { tmux -L devc "$@"; }

cleanup() {
  T kill-session -t "=$SES" 2>/dev/null || true
  rm -rf "$TMP" "$HOME/.devc/logs/$PROJ"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
# grep without -q: consume the whole stream so pipefail doesn't see SIGPIPE
status_has() { "$DEVC" status | grep -F "$1" >/dev/null; }

cd "$TMP"
cat >.devc <<'EOF'
ports: TP=8150
backend: while :; do echo backend-tick; sleep 1; done
worker*2: while :; do echo "worker $DEVC_INSTANCE tick"; sleep 1; done
pecho: while :; do echo "svcTP=$TP"; sleep 1; done
shell: zsh
EOF

# occupy the base port so the picker must increment to 8151
python3 -m http.server 8150 --bind 127.0.0.1 >/dev/null 2>&1 &
BLOCKER=$!
trap 'kill "$BLOCKER" 2>/dev/null; cleanup' EXIT
sleep 1

"$DEVC" start -d

T has-session -t "=$SES" || fail "session not created"
ok "session exists"

names=$(T list-panes -t "=$SES:0" -F '#{@devc_name}' | sort | xargs)
[[ "$names" == "backend ctl pecho shell worker-1 worker-2" ]] || fail "panes: got '$names'"
ok "panes: $names"

# session/window options must actually stick (tmux 3.2a rejects '=' targets on set)
[[ "$(T show -t "$SES" -v @devc_root)" == "$TMP" ]] || fail "@devc_root not stored"
[[ "$(T show -t "$SES" -v mouse)" == on ]] || fail "mouse not on"
[[ "$(T show -t "$SES" -v history-limit)" == 50000 ]] || fail "history-limit not set"
[[ "$(T show -w -t "$SES:0" -v pane-border-status)" == top ]] || fail "pane borders not set"
status_has "root:$TMP" || fail "status misses root"
ok "session options + @devc_root stored"

kinds=$(T list-panes -t "=$SES:0" -F '#{@devc_name}=#{@devc_kind}' | sort | xargs)
[[ "$kinds" == "backend=service ctl=shell pecho=service shell=shell worker-1=worker worker-2=worker" ]] ||
  fail "pane kinds: got '$kinds'"
ok "pane kinds (chip colors) tagged"

# ports: 8150 is blocked, so TP must be 8151 — in status, services, and shells
status_has "ports: TP=8151" || fail "status misses picked port"
[[ "$("$DEVC" port 8150)" == 8151 ]] || fail "devc port didn't skip busy 8150"
sleep 6   # panes are interactive zsh now — allow oh-my-zsh init before output
grep -q "svcTP=8151" "$HOME/.devc/logs/$PROJ/pecho.log" || fail "service didn't get picked port"
shell_id=$(T list-panes -t "=$SES:0" -F '#{pane_id} #{@devc_name}' | awk '$2=="shell"{print $1}')
T send-keys -t "$shell_id" 'echo shTP=$TP' Enter
sleep 2
grep -q "shTP=8151" "$HOME/.devc/logs/$PROJ/shell.log" || fail "shell pane didn't get picked port"
"$DEVC" restart pecho
sleep 3
! grep -q "svcTP=8150" "$HOME/.devc/logs/$PROJ/pecho.log" || fail "restart re-picked a different port"
tail -3 "$HOME/.devc/logs/$PROJ/pecho.log" | grep -q "svcTP=8151" || fail "restart lost the picked port"
ok "auto ports: picked 8151, same in status/service/shell, survives restart"

"$DEVC" start -d | grep -q "already running" || fail "start not idempotent"
ok "start is idempotent"

sleep 4
log="$HOME/.devc/logs/$PROJ/backend.log"
grep -q backend-tick "$log" || fail "backend log empty ($log)"
grep -q "worker 2 tick" "$HOME/.devc/logs/$PROJ/worker-2.log" || fail "DEVC_INSTANCE not seen in worker-2 log"
ok "logs flowing, DEVC_INSTANCE works"

pane_id=$(T list-panes -t "=$SES:0" -F '#{pane_id} #{@devc_name}' | awk '$2=="backend"{print $1}')
n1=$(grep -c backend-tick "$log")
"$DEVC" restart backend
sleep 3
n2=$(grep -c backend-tick "$log")
((n2 > n1)) || fail "backend not ticking after restart ($n1 -> $n2)"
[[ "$(T display -p -t "$pane_id" '#{pane_dead}')" == 0 ]] || fail "backend dead after restart"
ok "restart backend (Ctrl-C + rerun in same shell)"

"$DEVC" scale worker 3
n=$(T list-panes -t "=$SES:0" -F '#{@devc_base}' | grep -cx worker)
[[ "$n" == 3 ]] || fail "scale up: got $n workers"
"$DEVC" scale worker 1
n=$(T list-panes -t "=$SES:0" -F '#{@devc_base}' | grep -cx worker)
[[ "$n" == 1 ]] || fail "scale down: got $n workers"
ok "scale worker 3 -> 1"

"$DEVC" add oneshot 'echo bye-now; exit 3'
sleep 3
status_has "DEAD" || fail "dead pane not reported in status"
grep -q bye-now "$HOME/.devc/logs/$PROJ/oneshot.log" || fail "oneshot log missing output"
! "$DEVC" add oneshot 2>/dev/null || fail "duplicate add not rejected"
b1=$(grep -c bye-now "$HOME/.devc/logs/$PROJ/oneshot.log")
"$DEVC" restart oneshot   # dead pane: respawn shell + re-type the command
sleep 3
b2=$(grep -c bye-now "$HOME/.devc/logs/$PROJ/oneshot.log")
((b2 > b1)) || fail "restart of dead pane didn't rerun its command"
ok "add + shell-exit DEAD + restart of dead pane"

# -t/-h place the pane beside the named one, not under ctl
"$DEVC" add sidecar -t backend -h -l 30% zsh
read -r bl bt < <(T display -p -t "$pane_id" '#{pane_left} #{pane_top}')
side_id=$(T list-panes -t "=$SES:0" -F '#{pane_id} #{@devc_name}' | awk '$2=="sidecar"{print $1}')
read -r sl st < <(T display -p -t "$side_id" '#{pane_left} #{pane_top}')
[[ "$st" == "$bt" && "$sl" -gt "$bl" ]] || fail "add -t backend -h landed at $sl,$st (backend $bl,$bt)"
ok "add -t <pane> -h places beside the target"

# 'worker-3' with no command reuses the config command as instance 3
"$DEVC" add worker-3 -t backend -v
sleep 4
w3=$(T list-panes -t "=$SES:0" -F '#{@devc_name};#{@devc_base};#{@devc_inst}' | grep '^worker-3;')
[[ "$w3" == "worker-3;worker;3" ]] || fail "add worker-3 tagged '$w3'"
grep -q "worker 3 tick" "$HOME/.devc/logs/$PROJ/worker-3.log" || fail "worker-3 didn't run the config command"
ok "add worker-3 inherits the config command + instance"

status_has "$SES" || fail "status misses session"
ok "status lists session"

"$DEVC" stop
! T has-session -t "=$SES" 2>/dev/null || fail "session survived stop"
ok "stop"

echo "ALL PASS"
