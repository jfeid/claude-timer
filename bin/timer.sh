#!/usr/bin/env bash
# Session-agnostic work timer. Tracks time per task, per project, across sessions.
#
#   timer.sh on [task,...|--all]     start or resume; without a task: the session's task
#                                    (resumed or restarted), else exit 2 listing the paused
#                                    tasks or the last task so the caller can ask (--all:
#                                    every paused task or the last one)
#   timer.sh pause [task,...|--all]  pause; the session's task when running, else exit 2
#                                    listing the running tasks (--all: every running task)
#   timer.sh resume [task,...|--all] resume; same resolution over the paused tasks
#   timer.sh off [task,...|--all]    stop; the session's task when running or paused, else
#                                    exit 2 listing the open tasks (--all: every open task)
#   timer.sh status                  this session's task: state, since when, total, today,
#                                    and the other open tasks of the project
#   timer.sh list [running|paused|stopped|open ...]
#                                    one line per task with live totals, optionally only
#                                    those states (open = running and paused)
#   timer.sh report [--split]        table with raw + quarter-rounded totals
#   timer.sh day [DATE] [--all] [--split] [--tsv]
#                                    full-day report: per-task time clipped to that day,
#                                    wall clock and a timeline (DATE: today, yesterday,
#                                    YYYY-MM-DD or anything GNU `date -d` accepts; --all reads
#                                    every project log; --tsv prints machine-readable rows)
#   timer.sh month [MM-YYYY] [--all] [--split] [--tsv]
#                                    every day of the month with records: per-day and per-task
#                                    tracked and billable time (per task per day, rounded up to
#                                    the quarter, then summed); default: current month
#   timer.sh tasks                   list known task names
#   timer.sh session-task            the task this session last named
#   timer.sh cancel <task>           erase a task's entries entirely
#
# Log lives at ~/.claude/timer/logs/<project>.tsv, so timers survive session
# restarts and several projects can run their own timers at the same time.
# Override the project with TIMER_PROJECT=name. In a session that has named a
# task, the project stays that task's project wherever the shell moves.
#
# The session's task is the last single task named with on, pause, resume or
# off in that session, kept in ~/.claude/timer/sessions/<session id>. The id
# comes from TIMER_SESSION_ID or CLAUDE_CODE_SESSION_ID; no file of Claude
# Code's own is read.

set -uo pipefail

ROOT="${TIMER_HOME:-$HOME/.claude/timer}"
LOGDIR="$ROOT/logs"
QUARTER="${TIMER_QUARTER:-900}"   # rounding granularity in seconds

# This session's task: the last single task named with on, pause, resume or
# off in this session and project. Kept by this script in
# $ROOT/sessions/<session id> as "project<TAB>task" lines, the last for a
# project winning. Files untouched for 30 days are removed.
SESSION_ID="${TIMER_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
SESSION_FILE=""
case "$SESSION_ID" in
    ""|*[!A-Za-z0-9_-]*) ;;
    *) SESSION_FILE="$ROOT/sessions/$SESSION_ID" ;;
esac

# The project: TIMER_PROJECT; else, in a session that has named a task, that
# task's project, so a shell that moved into a nested repository (say
# internal/) still logs to the session's project; else the folder name of the
# git top level, or of the current folder outside git.
project_slug() {
    local top bound
    if [ -n "${TIMER_PROJECT:-}" ]; then
        echo "$TIMER_PROJECT"
        return
    fi
    if [ -n "$SESSION_FILE" ] && [ -r "$SESSION_FILE" ]; then
        bound=$(awk -F'\t' 'NF>=2 { p=$1 } END { if (p!="") print p }' "$SESSION_FILE")
        if [ -n "$bound" ]; then echo "$bound"; return; fi
    fi
    top=$(git rev-parse --show-toplevel 2>/dev/null)
    [ -z "$top" ] && top="$(pwd)"
    # printf avoids basename's trailing newline becoming a stray "-"
    printf '%s' "$(basename "$top")" | tr -c 'A-Za-z0-9._-' '-'
}

PROJECT="$(project_slug)"
LOG="$LOGDIR/$PROJECT.tsv"
if ! mkdir -p "$LOGDIR" 2>/dev/null || ! touch "$LOG" 2>/dev/null; then
    echo "timer: cannot write $LOG" >&2
    exit 1
fi

now() { date +%s; }
stamp() { date '+%Y-%m-%d %H:%M:%S'; }

# ---- dates: GNU date (Linux, Git Bash, gdate on macOS) or BSD date (macOS) ---

if date -d @0 +%s >/dev/null 2>&1; then GDATE=date
elif command -v gdate >/dev/null 2>&1; then GDATE=gdate
else GDATE=""; fi

# GNU date by either name, each written out.
gnu_date() {
    if [ "$GDATE" = gdate ]; then gdate "$@"; else date "$@"; fi
}

# YYYY-MM-DD for a date spec. BSD date knows today, yesterday, tomorrow and
# YYYY-MM-DD; anything else ("last friday") needs GNU date.
day_of() {
    local spec="${1:-today}"
    if [ -n "$GDATE" ]; then gnu_date -d "$spec" +%Y-%m-%d 2>/dev/null; return; fi
    case "$spec" in
        today)     date +%Y-%m-%d ;;
        yesterday) date -v-1d +%Y-%m-%d ;;
        tomorrow)  date -v+1d +%Y-%m-%d ;;
        [0-9][0-9][0-9][0-9]-[0-9]*-[0-9]*)
            date -j -f %Y-%m-%d "$spec" +%Y-%m-%d 2>/dev/null ;;
        *)  echo "macOS date reads today, yesterday, tomorrow or YYYY-MM-DD;" \
                 "install coreutils (brew install coreutils) for '$spec'." >&2
            return 1 ;;
    esac
}

# Epoch of local midnight at the start of YYYY-MM-DD.
midnight() {
    if [ -n "$GDATE" ]; then gnu_date -d "$1 00:00:00" +%s
    else date -j -f '%Y-%m-%d %H:%M:%S' "$1 00:00:00" +%s; fi
}

# YYYY-MM-DD plus N days, or plus N months (N may be negative).
add_days() {
    if [ -n "$GDATE" ]; then gnu_date -d "$1 $(signed "$2") day" +%Y-%m-%d
    else date -j -v"$(signed_bsd "$2")"d -f %Y-%m-%d "$1" +%Y-%m-%d; fi
}
add_months() {
    if [ -n "$GDATE" ]; then gnu_date -d "$1 $(signed "$2") month" +%Y-%m-%d
    else date -j -v"$(signed_bsd "$2")"m -f %Y-%m-%d "$1" +%Y-%m-%d; fi
}
signed() { if [ "$1" -lt 0 ]; then echo "- $(( -$1 ))"; else echo "+ $1"; fi; }
signed_bsd() { if [ "$1" -lt 0 ]; then echo "$1"; else echo "+$1"; fi; }

# Format an epoch, or a YYYY-MM-DD, with a strftime format.
fmt_epoch() {
    if [ -n "$GDATE" ]; then gnu_date -d "@$1" "+$2"; else date -r "$1" "+$2"; fi
}
fmt_day() {
    if [ -n "$GDATE" ]; then gnu_date -d "$1" "+$2"; else date -j -f %Y-%m-%d "$1" "+$2"; fi
}

# Comma/space separated list -> newline separated, deduped, order preserved.
split_tasks() {
    echo "$*" | tr ',' ' ' | tr -s ' ' '\n' | awk 'NF && !seen[$0]++'
}

# Append one event; a failed write ends the script before any success is printed.
emit() {
    if ! printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$(now)" "$(stamp)" 2>/dev/null >> "$LOG"; then
        echo "timer: cannot write $LOG" >&2
        exit 1
    fi
}

# Current state of one task: RUNNING | PAUSED | STOPPED | NONE
state_of() {
    awk -F'\t' -v k="$1" '
        $1==k { last=$2 }
        END {
            if (last=="")                       print "NONE";
            else if (last=="START"||last=="RESUME") print "RUNNING";
            else if (last=="PAUSE")              print "PAUSED";
            else                                 print "STOPPED";
        }' "${2:-$LOG}"
}

tasks_in_state() {
    local want="$1" t
    while IFS= read -r t; do
        [ -z "$t" ] && continue
        [ "$(state_of "$t")" = "$want" ] && echo "$t"
    done < <(awk -F'\t' 'NF{print $1}' "$LOG" | awk '!seen[$0]++')
}

all_known_tasks() { awk -F'\t' 'NF{print $1}' "$LOG" | awk '!seen[$0]++'; }

last_task() { awk -F'\t' 'NF{t=$1} END{if(t!="") print t}' "$LOG"; }

session_task() {
    [ -n "$SESSION_FILE" ] && [ -r "$SESSION_FILE" ] || return 0
    awk -F'\t' -v p="$PROJECT" '$1==p { t=$2 } END { if (t!="") print t }' "$SESSION_FILE"
}

# bind_session LIST: remember LIST as this session's task when it is one task.
# Runs before the action: when the task cannot be saved, the script stops
# without acting, so a later bare on/pause/off never falls back on an older
# session task the person did not mean.
bind_session() {
    local t
    [ -n "$SESSION_FILE" ] || return 0
    t=$(printf '%s\n' "$1" | awk 'NF')
    [ -n "$t" ] && [ "$(printf '%s\n' "$t" | wc -l | tr -d ' ')" = 1 ] || return 0
    [ "$(session_task)" = "$t" ] && return 0
    if ! mkdir -p "$ROOT/sessions" 2>/dev/null ||
       ! printf '%s\t%s\n' "$PROJECT" "$t" 2>/dev/null >> "$SESSION_FILE"; then
        echo "timer: cannot save this session's task to $SESSION_FILE; nothing changed" >&2
        exit 1
    fi
    find "$ROOT/sessions" -type f -mtime +30 -exec rm -f {} + 2>/dev/null
    return 0
}

# Which tasks a verb acts on when none were named. Precedence: the session's
# task when its state is one of OK (or, with NEWKEY=1, when it has no timer
# yet); otherwise the caller must ask, so the candidates are printed with a
# LABEL and the exit code says what happened:
#   0  one task chosen (printed)     2  ask: candidates printed     3  no candidate
#   choose_for VERB PAST "OK STATES" CANDIDATES LABEL [NEWKEY]   (VERB is for messages; the hint uses $CMD)
choose_for() {
    local verb="$1" past="$2" ok="$3" cand="$4" label="$5" newkey="${6:-0}" sess st
    sess=$(session_task)
    if [ -n "$sess" ]; then
        st=$(state_of "$sess")
        case " $ok " in *" $st "*) echo "$sess"; return 0 ;; esac
        if [ "$newkey" = 1 ] && [ "$st" = NONE ]; then
            echo "$sess"; return 0
        fi
    fi
    if [ -z "$sess" ]; then
        echo "No task given, and this session has not named one yet."
    else
        echo "No task given. This session's task $sess is $st, so it cannot be $past."
    fi
    if [ -z "$cand" ]; then
        if [ "$verb" = start ]; then echo "Nothing to start. Name the task: /timer on <task>"
        else echo "Nothing to $verb."; fi
        return 3
    fi
    echo "$label: $(printf '%s\n' "$cand" | paste -sd, - | sed 's/,/, /g')"
    echo "Ask which to $verb, then run: timer.sh $CMD <task[,task]|--all>"
    return 2
}

# Run choose_for and either set LIST or print its message and exit.
choose_or_exit() {
    local rc
    LIST=$(choose_for "$@"); rc=$?
    [ "$rc" = 3 ] && { echo "$LIST"; exit 0; }
    [ "$rc" != 0 ] && { echo "$LIST"; exit "$rc"; }
}

fmt() {
    awk -v s="$1" 'BEGIN{
        if (s<0) s=0;
        h=int(s/3600); m=int((s%3600)/60);
        if (h>0) printf "%dh %02dm", h, m; else printf "%dm", m;
    }'
}

roundup() {
    awk -v s="$1" -v q="$QUARTER" 'BEGIN{
        if (s<=0) { print 0; exit }
        print int((s + q - 1) / q) * q;
    }'
}

# Totals per task. Prints: task <TAB> seconds <TAB> state
totals() {
    awk -F'\t' -v now="$(now)" '
        {
            task=$1; ev=$2; ts=$3;
            if (!(task in seen)) { seen[task]=1; order[++n]=task; open[task]=0; tot[task]=0 }
            if (ev=="START" || ev=="RESUME") { if (!open[task]) open[task]=ts }
            else if (ev=="PAUSE" || ev=="STOP") { if (open[task]) { tot[task]+=ts-open[task]; open[task]=0 } }
            last[task]=ev;
        }
        END {
            for (i=1;i<=n;i++) {
                t=order[i]; s=tot[t]; st="STOPPED";
                if (open[t]) { s += now-open[t]; st="RUNNING" }
                else if (last[t]=="PAUSE") st="PAUSED";
                printf "%s\t%d\t%s\n", t, s, st;
            }
        }' "$LOG"
}

# Wall time split evenly among tasks that were running at the same moment.
split_totals() {
    awk -F'\t' -v now="$(now)" '
        {
            task=$1; ev=$2; ts=$3;
            if (!(task in seen)) { seen[task]=1; order[++n]=task; open[task]=0 }
            if (ev=="START" || ev=="RESUME") { if (!open[task]) open[task]=ts }
            else if (ev=="PAUSE" || ev=="STOP") {
                if (open[task]) { iv_t[++m]=task; iv_a[m]=open[task]; iv_b[m]=ts; open[task]=0 }
            }
        }
        END {
            for (i=1;i<=n;i++) { t=order[i]; if (open[t]) { iv_t[++m]=t; iv_a[m]=open[t]; iv_b[m]=now } }
            # collect boundaries
            for (i=1;i<=m;i++) { b[iv_a[i]]=1; b[iv_b[i]]=1 }
            nb=0; for (x in b) pts[++nb]=x+0;
            for (i=1;i<nb;i++) for (j=i+1;j<=nb;j++) if (pts[j]<pts[i]) { tmp=pts[i]; pts[i]=pts[j]; pts[j]=tmp }
            for (k=1;k<nb;k++) {
                a=pts[k]; z=pts[k+1]; d=z-a; if (d<=0) continue;
                c=0; delete act;
                for (i=1;i<=m;i++) if (iv_a[i]<=a && iv_b[i]>=z) { act[++c]=iv_t[i] }
                if (c==0) continue;
                for (i=1;i<=c;i++) sp[act[i]] += d/c;
            }
            for (i=1;i<=n;i++) { t=order[i]; printf "%s\t%d\n", t, (t in sp ? sp[t] : 0) }
        }' "$LOG"
}

# ---- day report -------------------------------------------------------------

# Resolve DATE (today, yesterday, 2026-09-07, "last monday", ...) into
# DAY, DAY_START, DAY_END (epoch, end exclusive).
day_bounds() {
    local d
    d=$(day_of "${1:-today}") || return 1
    [ -n "$d" ] || return 1
    DAY="$d"
    DAY_START=$(midnight "$d")
    # Add the day to the date alone: "00:00:00 + 1 day" would read "+ 1" as a UTC+1 zone.
    DAY_END=$(midnight "$(add_days "$d" 1)")
}

# Intervals of the given logs clipped to [DAY_START, DAY_END), sorted by start:
# project <TAB> task <TAB> from <TAB> to <TAB> open(1|0)
day_intervals() {
    awk -F'\t' -v now="$(now)" -v a="$DAY_START" -v z="$DAY_END" '
        function emit(p,t,s,e,o) {
            if (s<a) s=a; if (e>z) e=z;
            if (e>s) printf "%s\t%s\t%d\t%d\t%d\n", p, t, s, e, o
        }
        FNR==1 { proj=FILENAME; sub(/.*\//,"",proj); sub(/\.tsv$/,"",proj) }
        NF {
            k=proj SUBSEP $1; ev=$2; ts=$3;
            if (ev=="START"||ev=="RESUME") { if (!(k in open)) open[k]=ts }
            else if (ev=="PAUSE"||ev=="STOP") { if (k in open) { emit(proj,$1,open[k],ts,0); delete open[k] } }
        }
        END { for (k in open) { split(k,x,SUBSEP); emit(x[1],x[2],open[k],now,1) } }
    ' "$@" | sort -t$'\t' -k3,3n -k1,1 -k2,2
}

# Per task from the interval list, in order of first appearance:
# project <TAB> task <TAB> seconds <TAB> first <TAB> last <TAB> open(1|0)
day_totals() {
    awk -F'\t' '
        {
            k=$1 SUBSEP $2
            if (!(k in tot)) { order[++n]=k; tot[k]=0; first[k]=$3; open[k]=0 }
            tot[k]+=$4-$3; last[k]=$4; if ($5) open[k]=1
        }
        END {
            for (i=1;i<=n;i++) { k=order[i]; split(k,x,SUBSEP)
                printf "%s\t%s\t%d\t%d\t%d\t%d\n", x[1], x[2], tot[k], first[k], last[k], open[k] }
        }'
}

# Union of the intervals (wall clock actually spent) in seconds.
day_wall() {
    awk -F'\t' '
        { if (n && $3<=end) { if ($4>end) end=$4 } else { if (n) s+=end-st; st=$3; end=$4; n++ } }
        END { if (n) s+=end-st; printf "%d\n", s+0 }'
}

# Wall time divided evenly between tasks running at the same moment:
# project <TAB> task <TAB> seconds
day_split() {
    awk -F'\t' '
        { m++; iv_p[m]=$1; iv_t[m]=$2; iv_a[m]=$3; iv_b[m]=$4; k=$1 SUBSEP $2; if (!(k in seen)) { seen[k]=1; order[++n]=k } }
        END {
            for (i=1;i<=m;i++) { b[iv_a[i]]=1; b[iv_b[i]]=1 }
            nb=0; for (y in b) pts[++nb]=y+0;
            for (i=1;i<nb;i++) for (j=i+1;j<=nb;j++) if (pts[j]<pts[i]) { tmp=pts[i]; pts[i]=pts[j]; pts[j]=tmp }
            for (q=1;q<nb;q++) {
                a=pts[q]; z=pts[q+1]; d=z-a; if (d<=0) continue;
                c=0; delete act;
                for (i=1;i<=m;i++) if (iv_a[i]<=a && iv_b[i]>=z) act[++c]=iv_p[i] SUBSEP iv_t[i];
                for (i=1;i<=c;i++) sp[act[i]] += d/c;
            }
            for (i=1;i<=n;i++) { k=order[i]; split(k,x,SUBSEP); printf "%s\t%s\t%d\n", x[1], x[2], (k in sp ? sp[k] : 0) }
        }'
}

hm() { fmt_epoch "$1" '%H:%M'; }

# FILES: this project's log, or with ALL=1 every project's, as an array so
# paths with spaces stay whole.
log_files() {
    local f
    FILES=()
    if [ "$1" = "1" ]; then
        for f in "$LOGDIR"/*.tsv; do [ -f "$f" ] && FILES+=("$f"); done
    else
        FILES=("$LOG")
    fi
}

cmd_day() {
    local want_split=0 want_all=0 want_tsv=0 when="" a ivs tots
    for a in "$@"; do
        case "$a" in
            --split) want_split=1 ;;
            --all)   want_all=1 ;;
            --tsv)   want_tsv=1 ;;
            *)       when="${when:+$when }$a" ;;
        esac
    done
    day_bounds "${when:-today}" || { echo "Cannot understand date '$when'." >&2; exit 1; }

    log_files "$want_all"
    [ "${#FILES[@]}" -eq 0 ] && { echo "No timer logs found."; exit 0; }
    ivs=$(day_intervals "${FILES[@]}")
    tots=$(printf '%s\n' "$ivs" | awk 'NF' | day_totals)

    if [ "$want_tsv" = "1" ]; then
        # project, task, seconds, rounded, first_epoch, last_epoch, state;
        # with --split, seconds are the task's share of overlapping time.
        local spl=""
        [ "$want_split" = "1" ] && spl=$(printf '%s\n' "$ivs" | awk 'NF' | day_split)
        printf '%s\n' "$tots" | awk 'NF' | while IFS=$'\t' read -r p t s f l o; do
            if [ -n "$spl" ]; then
                s=$(printf '%s\n' "$spl" | awk -F'\t' -v p="$p" -v t="$t" '$1==p && $2==t { print $3; exit }')
            fi
            st=$(state_of "$t" "$LOGDIR/$p.tsv")
            printf '%s\t%s\t%d\t%d\t%d\t%d\t%s\n' "$p" "$t" "$s" "$(roundup "$s")" "$f" "$l" "$st"
        done
        return
    fi

    echo "Day: $DAY ($(LC_ALL=C fmt_day "$DAY" %A))   $([ "$want_all" = "1" ] && echo "Projects: all" || echo "Project: $PROJECT")"
    if [ -z "$(printf '%s' "$ivs" | awk 'NF')" ]; then
        echo "No time tracked on $DAY."
        return
    fi

    local pcol=""
    [ "$want_all" = "1" ] && pcol=1
    if [ -n "$pcol" ]; then
        printf '%-10s %-18s %-9s %-9s %-6s %-6s %s\n' PROJECT TASK TRACKED ROUNDED FIRST LAST STATE
    else
        printf '%-22s %-9s %-9s %-6s %-6s %s\n' TASK TRACKED ROUNDED FIRST LAST STATE
    fi
    printf '%s\n' "------------------------------------------------------------------------"
    local graw=0 gr=0 p t s f l o r st
    while IFS=$'\t' read -r p t s f l o; do
        [ -z "$t" ] && continue
        r=$(roundup "$s"); graw=$((graw+s)); gr=$((gr+r))
        st=$(state_of "$t" "$LOGDIR/$p.tsv")
        if [ -n "$pcol" ]; then
            printf '%-10s %-18s %-9s %-9s %-6s %-6s %s\n' "$p" "$t" "$(fmt "$s")" "$(fmt "$r")" "$(hm "$f")" "$(hm "$l")" "$st"
        else
            printf '%-22s %-9s %-9s %-6s %-6s %s\n' "$t" "$(fmt "$s")" "$(fmt "$r")" "$(hm "$f")" "$(hm "$l")" "$st"
        fi
    done <<< "$tots"
    printf '%s\n' "------------------------------------------------------------------------"
    if [ -n "$pcol" ]; then
        printf '%-10s %-18s %-9s %-9s\n' "" TOTAL "$(fmt "$graw")" "$(fmt "$gr")"
    else
        printf '%-22s %-9s %-9s\n' TOTAL "$(fmt "$graw")" "$(fmt "$gr")"
    fi

    local wall dfirst dlast
    wall=$(printf '%s\n' "$ivs" | awk 'NF' | day_wall)
    dfirst=$(printf '%s\n' "$ivs" | awk -F'\t' 'NF{print $3; exit}')
    dlast=$(printf '%s\n' "$ivs" | awk -F'\t' 'NF && $4>m{m=$4} END{print m}')
    echo "Wall clock: $(fmt "$wall") between $(hm "$dfirst") and $(hm "$dlast") (span $(fmt $((dlast-dfirst))))"

    if [ "$graw" -gt $((wall + 60)) ]; then
        echo
        echo "NOTE: tasks overlapped. Sum of per-task time is $(fmt "$graw"),"
        echo "      but only $(fmt "$wall") of wall clock elapsed."
        if [ "$want_split" = "1" ]; then
            echo
            printf '%-22s %-10s %s\n' "TASK (split)" "TRACKED" "ROUNDED"
            printf '%s\n' "----------------------------------------------------------------"
            while IFS=$'\t' read -r p t s; do
                [ -z "$t" ] && continue
                printf '%-22s %-10s %s\n' "$([ -n "$pcol" ] && printf '%s/' "$p")$t" "$(fmt "$s")" "$(fmt "$(roundup "$s")")"
            done < <(printf '%s\n' "$ivs" | awk 'NF' | day_split)
        else
            echo "      Run 'day --split' to divide shared time between them."
        fi
    fi

    echo
    echo "Timeline"
    while IFS=$'\t' read -r p t f l o; do
        [ -z "$t" ] && continue
        printf '%s-%s  %-22s %s%s\n' "$(hm "$f")" "$(hm "$l")" "$([ -n "$pcol" ] && printf '%s/' "$p")$t" "$(fmt $((l-f)))" "$([ "$o" = "1" ] && echo '  (running)')"
    done <<< "$ivs"
}

# ---- month report -----------------------------------------------------------

# Resolve MM-YYYY (also M-YYYY, YYYY-MM, "last"; default: current month) into
# MONTH (YYYY-MM), MONTH_START, MONTH_END (epoch, end exclusive).
month_bounds() {
    local in="${1:-}" m y
    case "$in" in
        "")                 m=$(date +%m); y=$(date +%Y) ;;
        last|prev|previous) in=$(add_months "$(date +%Y-%m-01)" -1); in=${in%-*}; y=${in%-*}; m=${in#*-} ;;
        *)
            if [[ "$in" =~ ^([0-9]{1,2})[-/.]([0-9]{4})$ ]]; then m=${BASH_REMATCH[1]}; y=${BASH_REMATCH[2]}
            elif [[ "$in" =~ ^([0-9]{4})[-/.]([0-9]{1,2})$ ]]; then y=${BASH_REMATCH[1]}; m=${BASH_REMATCH[2]}
            else return 1; fi ;;
    esac
    m=$((10#$m))
    [ "$m" -ge 1 ] && [ "$m" -le 12 ] || return 1
    MONTH=$(printf '%04d-%02d' "$((10#$y))" "$m")
    MONTH_START=$(midnight "$MONTH-01")
    MONTH_END=$(midnight "$(add_months "$MONTH-01" 1)")
}

# Per-day, per-task rows for every day of the month that has records:
# date <TAB> project <TAB> task <TAB> seconds <TAB> rounded <TAB> day_wall
# Rounding is per task per day, as in `day`, so the month total is the sum of the days.
month_rows() {
    local split="$1" i=0 d ivs per wall tomorrow
    shift
    tomorrow=$(midnight "$(add_days "$(date +%Y-%m-%d)" 1)")
    while :; do
        d=$(add_days "$MONTH-01" "$i"); i=$((i+1))
        day_bounds "$d"
        { [ "$DAY_START" -ge "$MONTH_END" ] || [ "$DAY_START" -ge "$tomorrow" ]; } && break
        ivs=$(day_intervals "$@" | awk 'NF')
        [ -z "$ivs" ] && continue
        if [ "$split" = "1" ]; then per=$(printf '%s\n' "$ivs" | day_split)
        else per=$(printf '%s\n' "$ivs" | day_totals | cut -f1-3); fi
        wall=$(printf '%s\n' "$ivs" | day_wall)
        printf '%s\n' "$per" | awk -F'\t' -v OFS='\t' -v d="$d" -v q="$QUARTER" -v w="$wall" '
            NF && $3>0 { print d, $1, $2, $3, int(($3 + q - 1) / q) * q, w }'
    done
}

cmd_month() {
    local want_split=0 want_all=0 want_tsv=0 when="" a rows
    for a in "$@"; do
        case "$a" in
            --split) want_split=1 ;;
            --all)   want_all=1 ;;
            --tsv)   want_tsv=1 ;;
            *)       when="${when:+$when }$a" ;;
        esac
    done
    month_bounds "$when" || { echo "Cannot understand month '$when' (use MM-YYYY, e.g. 09-2026)." >&2; exit 1; }

    log_files "$want_all"
    [ "${#FILES[@]}" -eq 0 ] && { echo "No timer logs found."; exit 0; }
    rows=$(month_rows "$want_split" "${FILES[@]}")

    if [ "$want_tsv" = "1" ]; then
        # date, project, task, seconds, rounded, state
        printf '%s\n' "$rows" | awk 'NF' | while IFS=$'\t' read -r d p t s r w; do
            printf '%s\t%s\t%s\t%d\t%d\t%s\n' "$d" "$p" "$t" "$s" "$r" "$(state_of "$t" "$LOGDIR/$p.tsv")"
        done
        return
    fi

    echo "Month: $MONTH ($(LC_ALL=C fmt_day "$MONTH-01" '%B %Y'))   $([ "$want_all" = "1" ] && echo "Projects: all" || echo "Project: $PROJECT")$([ "$want_split" = "1" ] && echo "   Overlaps: split")"
    if [ -z "$(printf '%s' "$rows" | awk 'NF')" ]; then
        echo "No time tracked in $MONTH."
        return
    fi

    local awk_fmt='function fmt(s,  h,m) { if (s<0) s=0; h=int(s/3600); m=int((s%3600)/60); return (h>0 ? sprintf("%dh %02dm", h, m) : sprintf("%dm", m)) }'

    # Per day
    printf '%-11s %-4s %-6s %-9s %-9s %s\n' DATE DAY TASKS TRACKED BILLABLE WALL
    printf '%s\n' "----------------------------------------------------------------"
    # Weekday names, looked up here rather than run from awk: "2026-11-02=Mon ..."
    local d wds=""
    for d in $(printf '%s\n' "$rows" | awk -F'\t' 'NF && !seen[$1]++ { print $1 }'); do
        wds="$wds $d=$(LC_ALL=C fmt_day "$d" %a)"
    done
    printf '%s\n' "$rows" | awk -F'\t' -v wds="$wds" "$awk_fmt"'
        BEGIN { nw=split(wds, x, " "); for (j=1;j<=nw;j++) { split(x[j], y, "="); wd_of[y[1]]=y[2] } }
        NF { if (!($1 in n)) { order[++k]=$1; w[$1]=$6 } n[$1]++; s[$1]+=$4; r[$1]+=$5 }
        END {
            for (i=1;i<=k;i++) { d=order[i]; wd=wd_of[d]
                printf "%-11s %-4s %-6d %-9s %-9s %s\n", d, wd, n[d], fmt(s[d]), fmt(r[d]), fmt(w[d])
                ts+=s[d]; tr+=r[d]; tw+=w[d] }
            print "----------------------------------------------------------------"
            printf "%-11s %-4s %-6s %-9s %-9s %s\n", "TOTAL", "", k " d", fmt(ts), fmt(tr), fmt(tw)
        }'

    # Per task
    echo
    local pcol=""
    [ "$want_all" = "1" ] && pcol=1
    if [ -n "$pcol" ]; then
        printf '%-15s %-18s %-5s %-9s %-9s %s\n' PROJECT TASK DAYS TRACKED BILLABLE STATE
    else
        printf '%-22s %-5s %-9s %-9s %s\n' TASK DAYS TRACKED BILLABLE STATE
    fi
    printf '%s\n' "----------------------------------------------------------------"
    local p t n s r
    while IFS=$'\t' read -r p t n s r; do
        [ -z "$t" ] && continue
        if [ -n "$pcol" ]; then
            printf '%-15s %-18s %-5s %-9s %-9s %s\n' "$p" "$t" "$n" "$(fmt "$s")" "$(fmt "$r")" "$(state_of "$t" "$LOGDIR/$p.tsv")"
        else
            printf '%-22s %-5s %-9s %-9s %s\n' "$t" "$n" "$(fmt "$s")" "$(fmt "$r")" "$(state_of "$t" "$LOGDIR/$p.tsv")"
        fi
    done < <(printf '%s\n' "$rows" | awk -F'\t' -v OFS='\t' '
        NF { k=$2 SUBSEP $3; if (!(k in n)) order[++m]=k; n[k]++; s[k]+=$4; r[k]+=$5 }
        END { for (i=1;i<=m;i++) { k=order[i]; split(k,x,SUBSEP); print x[1], x[2], n[k], s[k], r[k] } }')
    printf '%s\n' "----------------------------------------------------------------"

    local tot_s tot_r tot_w days
    read -r tot_s tot_r days tot_w < <(printf '%s\n' "$rows" | awk -F'\t' '
        NF { s+=$4; r+=$5; if (!($1 in d)) { d[$1]=1; n++; w+=$6 } }
        END { printf "%d %d %d %d\n", s, r, n, w }')
    if [ -n "$pcol" ]; then
        printf '%-15s %-18s %-5s %-9s %-9s\n' "" TOTAL "$days" "$(fmt "$tot_s")" "$(fmt "$tot_r")"
    else
        printf '%-22s %-5s %-9s %-9s\n' TOTAL "$days" "$(fmt "$tot_s")" "$(fmt "$tot_r")"
    fi
    echo
    echo "Billable: $(fmt "$tot_r") = $(LC_ALL=C awk -v s="$tot_r" 'BEGIN{printf "%.2f", s/3600}') hours over $days day(s) (tracked $(fmt "$tot_s"), wall clock $(fmt "$tot_w"))."

    if [ "$want_split" = "0" ] && [ "$tot_s" -gt $((tot_w + 60)) ]; then
        echo
        echo "NOTE: tasks overlapped. Sum of per-task time is $(fmt "$tot_s"),"
        echo "      but only $(fmt "$tot_w") of wall clock elapsed."
        echo "      Run 'month --split' to divide shared time between them."
    fi
}

# A task's last event and its epoch: EVENT<TAB>epoch.
last_event() {
    awk -F'\t' -v k="$1" '$1==k { e=$2; t=$3 } END { if (e!="") printf "%s\t%s\n", e, t }' "$LOG"
}

# An epoch as HH:MM when it is today, else YYYY-MM-DD HH:MM.
when_of() {
    if [ "$(fmt_epoch "$1" %Y-%m-%d)" = "$(date +%Y-%m-%d)" ]; then fmt_epoch "$1" %H:%M
    else fmt_epoch "$1" '%Y-%m-%d %H:%M'; fi
}

# Running and paused tasks other than $1, as "A (RUNNING, 1h 05m), B (PAUSED, 4m)".
open_others() {
    local t s st out=""
    while IFS=$'\t' read -r t s st; do
        [ "$t" = "$1" ] && continue
        case "$st" in RUNNING|PAUSED) out="${out:+$out, }$t ($st, $(fmt "$s"))" ;; esac
    done < <(totals)
    printf '%s' "$out"
}

cmd_status() {
    local sess st secs ev ts today others
    sess=$(session_task)
    others=$(open_others "$sess")
    if [ -z "$sess" ] || [ "$(state_of "$sess")" = NONE ]; then
        if [ -z "$sess" ]; then
            echo "This session has no task yet. Start or name one with: /timer on <task>"
        else
            echo "This session's task $sess has no timer in $PROJECT."
        fi
        if [ -n "$others" ]; then echo "Open in $PROJECT: $others"
        else echo "Nothing open in $PROJECT."; fi
        echo "All tasks: /timer list"
        return
    fi
    st=$(state_of "$sess")
    secs=$(totals | awk -F'\t' -v k="$sess" '$1==k { print $2 }')
    IFS=$'\t' read -r ev ts < <(last_event "$sess")
    day_bounds today
    today=$(day_intervals "$LOG" | awk -F'\t' -v k="$sess" '$2==k { s+=$4-$3 } END { print s+0 }')
    printf '%-11s %s   (project %s)\n' "Task:" "$sess" "$PROJECT"
    case "$st" in
        RUNNING) printf '%-11s RUNNING since %s (%s this run)\n' "State:" "$(when_of "$ts")" "$(fmt $(( $(now) - ts )))" ;;
        PAUSED)  printf '%-11s PAUSED since %s\n' "State:" "$(when_of "$ts")" ;;
        *)       printf '%-11s STOPPED at %s\n' "State:" "$(when_of "$ts")" ;;
    esac
    printf '%-11s %s   (rounded %s)\n' "Total:" "$(fmt "$secs")" "$(fmt "$(roundup "$secs")")"
    printf '%-11s %s\n' "Today:" "$(fmt "$today")"
    [ -n "$others" ] && printf '%-11s %s\n' "Also open:" "$others"
    return 0
}

# list [running|paused|stopped|open ...]: the task table, optionally filtered.
cmd_list() {
    local want="" a sess t s st mark marked=0 shown=0
    for a in "$@"; do
        case "$a" in
            running|paused|stopped) want="$want $(printf '%s' "$a" | tr '[:lower:]' '[:upper:]')" ;;
            open) want="$want RUNNING PAUSED" ;;
            *) echo "Unknown filter '$a'. Use running, paused, stopped or open." >&2; exit 1 ;;
        esac
    done
    if [ ! -s "$LOG" ]; then echo "No timers yet for $PROJECT."; return; fi
    sess=$(session_task)
    while IFS=$'\t' read -r t s st; do
        [ -n "$want" ] && case " $want " in *" $st "*) ;; *) continue ;; esac
        if [ "$shown" = 0 ]; then printf '%-22s %-9s %s\n' "TASK" "STATE" "TIME"; fi
        mark=""; [ -n "$sess" ] && [ "$t" = "$sess" ] && { mark=" *"; marked=1; }
        printf '%-22s %-9s %s%s\n' "$t" "$st" "$(fmt "$s")" "$mark"
        shown=$((shown+1))
    done < <(totals)
    if [ "$shown" = 0 ]; then
        echo "No$(printf '%s' "$want" | tr '[:upper:]' '[:lower:]' | sed 's/ running paused$/ open/; s/ /, /g; s/^,//') timers in $PROJECT."
    elif [ "$marked" = 1 ]; then
        echo "* this session's task"
    fi
}

require_tasks() {
    if [ -z "$1" ]; then
        echo "No task given and none could be inferred. Use: timer.sh $2 <task>" >&2
        exit 1
    fi
}

CMD="${1:-status}"; shift || true
ARGS="$*"

case "$CMD" in
    on|start)
        case "$ARGS" in
            "")    # Session task first (resume, restart, or start a new ticket key);
                   # otherwise the caller asks between the paused tasks, or the last task.
                   cand=$(tasks_in_state PAUSED); label=Paused
                   if [ -z "$cand" ]; then
                       cand=$(last_task); label="Last task"
                       [ -n "$cand" ] && [ "$(state_of "$cand")" = RUNNING ] && cand=""
                   fi
                   choose_or_exit start started "PAUSED STOPPED" "$cand" "$label" 1; list=$LIST ;;
            --all) list=$(tasks_in_state PAUSED)
                   [ -z "$list" ] && list=$(last_task)
                   require_tasks "$list" "on" ;;
            *)     list=$(split_tasks "${ARGS//--all/}"); bind_session "$list" ;;
        esac
        while IFS= read -r t; do
            [ -z "$t" ] && continue
            case "$(state_of "$t")" in
                RUNNING) echo "$t already running" ;;
                PAUSED)  emit "$t" RESUME; echo "$t resumed" ;;
                *)       emit "$t" START;  echo "$t started" ;;
            esac
        done <<< "$list"
        ;;

    pause|resume)
        if [ "$CMD" = pause ]; then want=RUNNING; ev=PAUSE; done_=paused; not="not running"
        else want=PAUSED; ev=RESUME; done_=resumed; not="not paused"; fi
        case "$ARGS" in
            "")    choose_or_exit "$([ "$want" = RUNNING ] && echo pause || echo resume)" "$done_" "$want" "$(tasks_in_state "$want")" "$([ "$want" = RUNNING ] && echo Running || echo Paused)"
                   list=$LIST ;;
            --all) list=$(tasks_in_state "$want")
                   if [ -z "$list" ]; then echo "Nothing to $([ "$want" = RUNNING ] && echo pause || echo resume)."; exit 0; fi ;;
            *)     list=$(split_tasks "${ARGS//--all/}"); bind_session "$list" ;;
        esac
        while IFS= read -r t; do
            [ -z "$t" ] && continue
            if [ "$(state_of "$t")" = "$want" ]; then
                emit "$t" "$ev"; echo "$t $done_"
            else
                echo "$t $not"
            fi
        done <<< "$list"
        ;;

    off|stop)
        open_tasks() { printf '%s\n%s\n' "$(tasks_in_state RUNNING)" "$(tasks_in_state PAUSED)" | awk 'NF'; }
        case "$ARGS" in
            "")    choose_or_exit stop stopped "RUNNING PAUSED" "$(open_tasks)" Open; list=$LIST ;;
            --all) list=$(open_tasks)
                   if [ -z "$list" ]; then echo "Nothing to stop."; exit 0; fi ;;
            *)     list=$(split_tasks "${ARGS//--all/}"); bind_session "$list" ;;
        esac
        while IFS= read -r t; do
            [ -z "$t" ] && continue
            st=$(state_of "$t")
            if [ "$st" = "RUNNING" ] || [ "$st" = "PAUSED" ]; then
                emit "$t" STOP
                secs=$(totals | awk -F'\t' -v k="$t" '$1==k{print $2}')
                echo "$t stopped — $(fmt "$secs") (${secs}s)"
            else
                echo "$t not active"
            fi
        done <<< "$list"
        ;;

    status)
        cmd_status
        ;;

    list|ls)
        # shellcheck disable=SC2086
        cmd_list $ARGS
        ;;

    report)
        if [ ! -s "$LOG" ]; then echo "No timers yet for $PROJECT."; exit 0; fi
        want_split=0
        case "$ARGS" in *--split*) want_split=1 ;; esac

        echo "Project: $PROJECT"
        printf '%-22s %-10s %-10s %s\n' "TASK" "TRACKED" "ROUNDED" "STATE"
        printf '%s\n' "----------------------------------------------------------------"
        graw=0; gr=0
        while IFS=$'\t' read -r t s st; do
            r=$(roundup "$s"); graw=$((graw+s)); gr=$((gr+r))
            printf '%-22s %-10s %-10s %s\n' "$t" "$(fmt "$s")" "$(fmt "$r")" "$st"
        done < <(totals)
        printf '%s\n' "----------------------------------------------------------------"
        printf '%-22s %-10s %-10s\n' "TOTAL" "$(fmt "$graw")" "$(fmt "$gr")"

        # Warn when tasks overlapped, because then the per-task times double-count
        # the same wall clock and cannot all be billed.
        wall=$(split_totals | awk -F'\t' '{s+=$2} END{printf "%d", s+0}')
        if [ "$graw" -gt $((wall + 60)) ]; then
            echo
            echo "NOTE: tasks overlapped. Sum of per-task time is $(fmt "$graw"),"
            echo "      but only $(fmt "$wall") of wall clock elapsed."
            if [ "$want_split" = "1" ]; then
                echo
                printf '%-22s %-10s %s\n' "TASK (split)" "TRACKED" "ROUNDED"
                printf '%s\n' "----------------------------------------------------------------"
                while IFS=$'\t' read -r t s; do
                    printf '%-22s %-10s %s\n' "$t" "$(fmt "$s")" "$(fmt "$(roundup "$s")")"
                done < <(split_totals)
            else
                echo "      Run 'report --split' to divide shared time between them."
            fi
        fi
        ;;

    day)
        # shellcheck disable=SC2086
        cmd_day $ARGS
        ;;

    month)
        # shellcheck disable=SC2086
        cmd_month $ARGS
        ;;

    tasks)
        all_known_tasks
        ;;

    session-task)
        session_task
        ;;

    cancel)
        require_tasks "$ARGS" "cancel"
        for t in $(split_tasks "$ARGS"); do
            awk -F'\t' -v k="$t" '$1!=k' "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
            echo "$t removed from the log"
        done
        ;;

    where)
        echo "$LOG"
        ;;

    *)
        echo "Unknown command: $CMD" >&2
        sed -n '2,30p' "$0" >&2
        exit 1
        ;;
esac
