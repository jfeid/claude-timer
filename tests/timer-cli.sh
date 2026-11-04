#!/usr/bin/env bash
# End-to-end checks of bin/timer.sh against a throwaway log, so the script can
# be tested on every platform CI offers (Linux, macOS, Windows/Git Bash).
#   bash tests/timer-cli.sh
set -u

T="$(cd "$(dirname "$0")/.." && pwd)/bin/timer.sh"
TIMER_HOME=$(mktemp -d)
export TIMER_HOME TIMER_PROJECT=ci TIMER_SESSION_NAME=ci-session TZ=UTC
trap 'rm -rf "$TIMER_HOME"' EXIT

fails=0
out=""
# run NAME WANT_EXIT ARGS...: run timer.sh, check its exit code.
run() {
    local name=$1 want=$2 code
    shift 2
    out=$("$T" "$@" 2>&1); code=$?
    if [ "$code" = "$want" ]; then
        echo "ok   $name"
    else
        echo "FAIL $name: exit $code, expected $want"
        printf '%s\n' "$out" | sed 's/^/     /'
        fails=$((fails + 1))
    fi
}
# has TEXT: the last output contains TEXT.
has() {
    if printf '%s\n' "$out" | grep -qF -- "$1"; then
        echo "ok     has '$1'"
    else
        echo "FAIL   no '$1' in:"
        printf '%s\n' "$out" | sed 's/^/     /'
        fails=$((fails + 1))
    fi
}

echo "== live timers"
run "status, empty log" 0 status;          has "No timers yet for ci."
run "on ABC-1" 0 on ABC-1;                 has "ABC-1 started"
run "status, running" 0 status;            has "RUNNING"
run "pause" 0 pause ABC-1;                 has "ABC-1 paused"
run "resume" 0 resume ABC-1
run "off" 0 off ABC-1;                     has "ABC-1 stopped"
run "on two tasks" 0 on ABC-1,ABC-2
run "off without a task asks" 2 off;       has "Open: ABC-1, ABC-2"
run "off --all" 0 off --all;               has "ABC-2 stopped"
run "report" 0 report;                     has "TOTAL"
run "tasks" 0 tasks;                       has "ABC-2"
run "cancel" 0 cancel ABC-2;               has "ABC-2 removed"
run "day today" 0 day
run "day yesterday" 0 day yesterday
run "month current" 0 month
run "month last" 0 month last

echo "== fixed history (2026-01-15, UTC)"
# OLD-1 09:00-10:00 and 10:10-10:30, OLD-2 09:30-09:45 (overlapping).
printf '%s\t%s\t%s\t-\n' \
    OLD-1 START 1768467600  OLD-1 PAUSE 1768471200 \
    OLD-1 RESUME 1768471800 OLD-1 STOP 1768473000 \
    OLD-2 START 1768469400  OLD-2 STOP 1768470300 \
    > "$TIMER_HOME/logs/ci.tsv"
run "day" 0 day 2026-01-15
has "Day: 2026-01-15 (Thursday)"
has "OLD-1                  1h 20m    1h 30m    09:00  10:30  STOPPED"
has "Wall clock: 1h 20m between 09:00 and 10:30"
has "10:10-10:30  OLD-1"
run "day --tsv" 0 day 2026-01-15 --tsv
has "ci	OLD-1	4800	5400	1768467600	1768473000	STOPPED"
run "month" 0 month 01-2026
has "Billable: 1h 45m = 1.75 hours over 1 day(s)"
run "month --split" 0 month 01-2026 --split
has "Billable: 1h 30m = 1.50 hours over 1 day(s)"
run "report --split" 0 report --split
has "OLD-1                  1h 12m     1h 15m"

echo "== session name"
mkdir -p "$TIMER_HOME/.claude/sessions"
printf '{"pid":4242,"sessionId":"s-1","name":"ABC-7 login fix","cwd":"/x"}\n' \
    > "$TIMER_HOME/.claude/sessions/4242.json"
HOME="$TIMER_HOME" CLAUDE_PID=4242 TIMER_SESSION_NAME="" run "session-name from the session file" 0 session-name
has "ABC-7 login fix"
# The same field read without jq: only sed and head on PATH.
mkdir -p "$TIMER_HOME/nojq"
ln -s "$(command -v sed)" "$TIMER_HOME/nojq/sed"
ln -s "$(command -v head)" "$TIMER_HOME/nojq/head"
out=$(PATH="$TIMER_HOME/nojq" "$BASH" -c "$(sed -n '/^json_str()/,/^}/p' "$T")"'
    json_str "$1" name' _ "$TIMER_HOME/.claude/sessions/4242.json" 2>&1)
has "ABC-7 login fix"

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; exit 1; fi
