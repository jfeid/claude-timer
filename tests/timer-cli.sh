#!/usr/bin/env bash
# End-to-end checks of bin/timer.sh against a throwaway log, so the script can
# be tested on every platform CI offers (Linux, macOS, Windows/Git Bash).
#   bash tests/timer-cli.sh
set -u

T="$(cd "$(dirname "$0")/.." && pwd)/bin/timer.sh"
TIMER_HOME=$(mktemp -d)
export TIMER_HOME TIMER_PROJECT=ci TIMER_SESSION_ID=ci-session TZ=UTC
# Claude Code's folder, with session files written below; never the real one.
export CLAUDE_CONFIG_DIR="$TIMER_HOME/claude"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PID TIMER_SESSION_NAME
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
run "on, nothing to start" 0 on;           has "Nothing to start. Name the task: /timer on <task>, or /rename"
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
has "this session has no task"; has "Open: ABC-1, ABC-2"
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

echo "== session name"
# session FILE ID NAME SOURCE: a Claude Code session file.
session() {
    mkdir -p "$CLAUDE_CONFIG_DIR/sessions"
    printf '{"pid":%s,"sessionId":"%s","name":"%s","nameSource":"%s"}\n' \
        "$1" "$2" "$3" "$4" | sed 's/}$/,"formerNames":[{"name":"OLD-NAME","sessionId":"s-old"}]}/' \
        > "$CLAUDE_CONFIG_DIR/sessions/$1.json"
}
session 101 s-name PFLX-1 user
session 102 s-gen brave-otter derived
session 103 s-space "fix the login" user
CLAUDE_PID=101 TIMER_SESSION_ID=s-name run "name from CLAUDE_PID" 0 session-name; has "PFLX-1"
TIMER_SESSION_ID=s-name run "name found by session id" 0 session-name; has "PFLX-1"
CLAUDE_PID=102 TIMER_SESSION_ID=s-name run "another session's file is not used" 0 session-name; has "PFLX-1"
TIMER_SESSION_ID=s-old run "a former session id is not this one" 0 session-name
[ -z "$out" ] && echo "ok     empty" || { echo "FAIL   expected empty, got: $out"; fails=$((fails + 1)); }
TIMER_SESSION_ID=s-gen run "generated name is ignored" 0 session-task
[ -z "$out" ] && echo "ok     empty" || { echo "FAIL   expected empty, got: $out"; fails=$((fails + 1)); }
TIMER_SESSION_ID=s-space run "name with spaces is ignored" 0 session-task
[ -z "$out" ] && echo "ok     empty" || { echo "FAIL   expected empty, got: $out"; fails=$((fails + 1)); }
TIMER_SESSION_ID=s-name run "on starts the name" 0 on;        has "PFLX-1 started"
TIMER_SESSION_ID=s-name run "pause uses the name" 0 pause;    has "PFLX-1 paused"
TIMER_SESSION_ID=s-name run "a named task wins" 0 on PFLX-2;  has "PFLX-2 started"
TIMER_SESSION_ID=s-name run "session-task" 0 session-task;    has "PFLX-2"
TIMER_SESSION_ID=s-name run "off stops PFLX-2" 0 off;         has "PFLX-2 stopped"
session 101 s-name PFLX-3 user
TIMER_SESSION_ID=s-name run "a later rename wins" 0 on;       has "PFLX-3 started"
TIMER_SESSION_NAME= TIMER_SESSION_ID=s-gen run "empty TIMER_SESSION_NAME" 0 session-name
[ -z "$out" ] && echo "ok     empty" || { echo "FAIL   expected empty, got: $out"; fails=$((fails + 1)); }
TIMER_SESSION_NAME=OVR-1 TIMER_SESSION_ID=s-gen run "TIMER_SESSION_NAME" 0 session-task; has "OVR-1"
run "off --all" 0 off --all

echo "== nested repositories"
# A session that named a task in outer/ keeps to that project after the
# shell moves into outer/inner/, a repository of its own.
NEST=$(mktemp -d)
mkdir -p "$NEST/outer/inner"
git -C "$NEST/outer" init -q && git -C "$NEST/outer/inner" init -q
( cd "$NEST/outer" && TIMER_PROJECT= TIMER_SESSION_ID=s-nest "$T" on NEST-1 >/dev/null )
out=$(cd "$NEST/outer/inner" && TIMER_PROJECT= TIMER_SESSION_ID=s-nest "$T" off 2>&1)
has "NEST-1 stopped"
out=$(cd "$NEST/outer/inner" && TIMER_PROJECT= TIMER_SESSION_ID=s-nest "$T" where 2>&1)
has "/logs/outer.tsv"
# Without a session, the inner repository is its own project.
out=$(cd "$NEST/outer/inner" && TIMER_PROJECT= TIMER_SESSION_ID= "$T" where 2>&1)
has "/logs/inner.tsv"
# TIMER_PROJECT still wins.
out=$(cd "$NEST/outer/inner" && TIMER_PROJECT=forced TIMER_SESSION_ID=s-nest "$T" where 2>&1)
has "/logs/forced.tsv"
rm -rf "$NEST"

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

echo "== trim"
# TR-1 ran 09:00-18:00 on 2026-01-15 (UTC), paused, then stopped; TR-2 has
# been running for four hours; TR-3 for two.
NOW=$(date +%s)
TL="$TIMER_HOME/logs/trim.tsv"
printf '%s\t%s\t%s\t-\n' \
    TR-1 START 1768467600 TR-1 PAUSE 1768500000 TR-1 STOP 1768500100 \
    TR-2 START $((NOW - 14400)) TR-3 START $((NOW - 7200)) > "$TL"
tr_run() { TIMER_PROJECT=trim TIMER_SESSION_ID=s-trim run "$@"; }
# count EVENT TASK: lines of that task and event in the trim log.
count() { awk -F'\t' -v e="$1" -v k="$2" '$1==k && $2==e' "$TL" | wc -l | tr -d ' '; }
check() { if [ "$1" = "$2" ]; then echo "ok     $3"; else echo "FAIL   $3: got '$1', expected '$2'"; fails=$((fails + 1)); fi; }

tr_run "no task: ask between the running" 2 trim -1h
has "Running: TR-2, TR-3"; has "timer.sh trim <task[,task]|--all> -1h"
tr_run "no time: show the last run" 0 trim TR-2
has "TR-2: last run"; has "4h 00m, running"
check "$(ls "$TIMER_HOME/backups"/trim.* 2>/dev/null | wc -l | tr -d ' ')" 0 "no backup without a change"
before=$(cat "$TL")
tr_run "before the run's start" 1 trim TR-1 2026-01-15 08:00; has "is not within the last run"
tr_run "after the run's end" 1 trim TR-1 2026-01-15 19:00; has "trim only shortens"
tr_run "in the future" 1 trim TR-2 2030-01-01 10:00; has "is in the future"
tr_run "longer than the run" 1 trim TR-3 -3h; has "is not within the last run"
tr_run "one bad task stops all" 1 trim TR-1,TR-2 2026-01-15 12:00; has "Nothing changed."
tr_run "bad time" 1 trim TR-2 25:00; has "Cannot read the time"
tr_run "bad duration" 1 trim TR-2 -3x; has "Cannot read the duration"
check "$(cat "$TL")" "$before" "refused trims leave the log alone"

tr_run "closed run, exact time" 0 trim TR-1 2026-01-15 12:30
has "TR-1 last run now ends at 2026-01-15 12:30 instead of 2026-01-15 18:00: cut 5h 30m. Total 9h 00m → 3h 30m."
has "Backup: $TIMER_HOME/backups/trim."
check "$(awk -F'\t' '$1=="TR-1" && $2=="PAUSE" { print $3 "|" $4 }' "$TL")" "1768480200|2026-01-15 12:30:00" "PAUSE line rewritten"
check "$(count STOP TR-1)" 1 "STOP line kept"
bk=$(ls "$TIMER_HOME/backups"/trim.*.tsv | head -1)
check "$(cat "$bk")" "$before" "backup holds the old log"
tr_run "closed run, HH:MM inside it" 0 trim TR-1 11:15; has "ends at 2026-01-15 11:15"
tr_run "running: paused at the cut" 0 trim TR-2 -1h
has "TR-2 paused at"; has "cut 1h 00m. Total 4h 00m → 3h 00m."; has "/timer on TR-2 to continue."
# The script reads the clock a moment after NOW: allow a few seconds.
check "$(awk -F'\t' -v w=$((NOW - 3600)) '$1=="TR-2" && $2=="PAUSE" { print ($3 >= w && $3 <= w + 5) ? "yes" : $3 }' "$TL")" yes "PAUSE one hour before now"
tr_run "session task is now TR-2" 0 session-task; has "TR-2"
tr_run "paused run: bare trim uses the session task" 0 trim -30m; has "TR-2 last run now ends at"
tr_run "running, --resume" 0 trim TR-3 -30m --resume; has "TR-3 paused at"; has "resumed now"
check "$(TIMER_PROJECT=trim "$T" list running)" "$(printf 'TASK                   STATE     TIME\nTR-3                   RUNNING   1h 30m')" "TR-3 still running, 30m less"
printf '%s\t%s\t%s\t-\n' TR-4 START $((NOW - 3600)) >> "$TL"
tr_run "running, --stop" 0 trim TR-4 -20m --stop; has "TR-4 stopped at"
check "$(count STOP TR-4)" 1 "STOP written"
tr_run "cancel keeps a backup" 0 cancel TR-4; has "TR-4 removed"; has "Backup: $TIMER_HOME/backups/trim."
grep -q "TR-4" "$(ls -t "$TIMER_HOME/backups"/trim.*.tsv | head -1)" && echo "ok     backup holds TR-4" || { echo "FAIL   backup lacks TR-4"; fails=$((fails + 1)); }

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
