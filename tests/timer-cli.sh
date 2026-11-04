#!/usr/bin/env bash
# End-to-end checks of bin/timer.sh against a throwaway log, so the script can
# be tested on every platform CI offers (Linux, macOS, Windows/Git Bash).
#   bash tests/timer-cli.sh
set -u

T="$(cd "$(dirname "$0")/.." && pwd)/bin/timer.sh"
TIMER_HOME=$(mktemp -d)
export TIMER_HOME TIMER_PROJECT=ci TIMER_SESSION_ID=ci-session TZ=UTC
unset CLAUDE_CODE_SESSION_ID
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
run "list, empty log" 0 list;              has "No timers yet for ci."
run "on, nothing to start" 0 on;           has "Nothing to start. Name the task: /timer on <task>"
run "status, no task yet" 0 status;        has "This session has no task yet"
run "on ABC-1" 0 on ABC-1;                 has "ABC-1 started"
run "list, running" 0 list;                has "RUNNING"; has "* this session's task"
run "status, running" 0 status;            has "RUNNING since"; has "Task:       ABC-1"
run "list paused, none" 0 list paused;     has "No paused timers in ci."
run "list bad filter" 1 list foo;          has "Unknown filter 'foo'"
run "pause" 0 pause ABC-1;                 has "ABC-1 paused"
run "status, paused" 0 status;             has "PAUSED since"
run "list paused" 0 list paused;           has "ABC-1"
run "list running, none" 0 list running;   has "No running timers in ci."
run "resume" 0 resume ABC-1
run "off" 0 off ABC-1;                     has "ABC-1 stopped"
run "on two tasks" 0 on ABC-1,ABC-2
run "off acts on the session's task" 0 off; has "ABC-1 stopped"
run "on ABC-1 again" 0 on ABC-1
TIMER_SESSION_ID=other run "another session asks" 2 off
has "this session has not named one yet"; has "Open: ABC-1, ABC-2"
run "off --all" 0 off --all;               has "ABC-2 stopped"
run "report" 0 report;                     has "TOTAL"
run "tasks" 0 tasks;                       has "ABC-2"
run "cancel" 0 cancel ABC-2;               has "ABC-2 removed"
run "day today" 0 day
run "day yesterday" 0 day yesterday
run "month current" 0 month
run "month last" 0 month last

echo "== session task"
TIMER_SESSION_ID=s-2 run "no task named yet" 0 session-task
[ -z "$out" ] && echo "ok     empty" || { echo "FAIL   expected empty, got: $out"; fails=$((fails + 1)); }
TIMER_SESSION_ID=s-2 run "on XYZ-1 names it" 0 on XYZ-1
TIMER_SESSION_ID=s-2 run "session-task" 0 session-task; has "XYZ-1"
TIMER_SESSION_ID=s-2 run "pause uses it" 0 pause;        has "XYZ-1 paused"
TIMER_SESSION_ID=s-2 run "on resumes it" 0 on;           has "XYZ-1 resumed"
TIMER_SESSION_ID=s-2 run "two tasks keep it" 0 on XYZ-2,XYZ-3
TIMER_SESSION_ID=s-2 run "still XYZ-1" 0 session-task;   has "XYZ-1"
TIMER_SESSION_ID=s-2 run "off uses it" 0 off;            has "XYZ-1 stopped"
TIMER_SESSION_ID=s-2 run "on restarts it" 0 on;          has "XYZ-1 started"
CLAUDE_CODE_SESSION_ID=s-2 TIMER_SESSION_ID= run "id from Claude's Bash tool" 0 session-task; has "XYZ-1"
TIMER_SESSION_ID=../x run "unsafe id is ignored" 0 session-task
[ ! -e "$TIMER_HOME/x" ] && echo "ok     no file outside sessions/" || { echo "FAIL   wrote outside sessions/"; fails=$((fails + 1)); }
run "off --all" 0 off --all

echo "== failed writes"
# Windows ignores chmod, so a read-only folder cannot be made there.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) echo "skip   read-only folder (Windows)" ;;
    *)
        RO=$(mktemp -d); chmod 500 "$RO"
        TIMER_HOME="$RO" run "unwritable log fails" 1 on ABC-9; has "cannot write"
        printf '%s\n' "$out" | grep -q started && { echo "FAIL   printed started"; fails=$((fails + 1)); } || echo "ok     no 'started'"
        chmod 700 "$RO"; rm -rf "$RO"
        # The session task cannot be saved: nothing is started, and the old
        # session task is not used by a later bare off.
        TIMER_SESSION_ID=s-ro run "bind OLD-9" 0 on OLD-9
        chmod 444 "$TIMER_HOME/sessions/s-ro"
        TIMER_SESSION_ID=s-ro run "unsaved session task fails" 1 on NEW-9; has "cannot save this session's task"
        run "NEW-9 was not started" 0 list running
        printf '%s\n' "$out" | grep -q NEW-9 && { echo "FAIL   NEW-9 started"; fails=$((fails + 1)); } || echo "ok     NEW-9 not started"
        chmod 644 "$TIMER_HOME/sessions/s-ro"
        TIMER_SESSION_ID=s-ro run "off OLD-9" 0 off OLD-9 ;;
esac

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

# Two tasks overlapping for a whole hour: --split gives each half of it.
printf '%s\t%s\t%s\t-\n' \
    SPL-1 START 1768550400 SPL-1 STOP 1768554000 \
    SPL-2 START 1768550400 SPL-2 STOP 1768554000 \
    > "$TIMER_HOME/logs/split.tsv"
TIMER_PROJECT=split run "day --split --tsv" 0 day 2026-01-16 --split --tsv
has "split	SPL-1	1800	1800"
TIMER_PROJECT=split run "day --tsv, unsplit" 0 day 2026-01-16 --tsv
has "split	SPL-1	3600	3600"

echo "== paths with spaces"
SP="$TIMER_HOME/with space"
mkdir -p "$SP/logs"; cp "$TIMER_HOME/logs/ci.tsv" "$SP/logs/ci.tsv"
TIMER_HOME="$SP" run "day --tsv" 0 day 2026-01-15 --tsv
has "ci	OLD-1	4800	5400"
TIMER_HOME="$SP" run "month --all" 0 month 01-2026 --all
has "Billable: 1h 45m"
TIMER_HOME="$SP" run "on with a space in the path" 0 on SP-1; has "SP-1 started"

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; exit 1; fi
