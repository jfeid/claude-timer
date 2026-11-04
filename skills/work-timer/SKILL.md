---
name: work-timer
description: Work timer per task and project. Start, pause, resume and stop timers, show live status, and print day and month reports with quarter-rounded billable time. Use for /timer, or when the user asks to start, stop, pause or check time tracking for a task.
argument-hint: "<on|pause|resume|off|status|report|day|month> [task,...|--all|DATE|MM-YYYY] [--split]"
allowed-tools: Bash(timer.sh:*)
user-invocable: false
---

# Work timer

Start, pause, resume and stop work timers for one or more tasks. Timers are
stored per project and survive session restarts, so a timer started in one
session can be paused or stopped from another.

## Arguments

$ARGUMENTS - The action and optional task list

Format: `<on|pause|resume|off|status|report|day|month> [task[,task2,...]|--all|date|MM-YYYY] [flags]`

Examples:
- `/timer on ABC-123` - Start (or resume) one task
- `/timer on ABC-1,ABC-2,ABC-3` - Start several tasks at once
- `/timer on` - Start or resume the session's task; otherwise ask which
- `/timer on --all` - Resume whatever is paused, or reopen the last task used
- `/timer pause` - Pause the session's task; otherwise ask which running task
- `/timer pause ABC-123` - Pause just that task
- `/timer pause --all` - Pause every running task
- `/timer resume` - Resume the session's task; otherwise ask which paused task
- `/timer resume --all` - Resume every paused task
- `/timer off` - Stop the session's task; otherwise ask which open task
- `/timer off ABC-123` - Stop one task and report its total
- `/timer off --all` - Stop everything still open
- `/timer status` - Live state and elapsed time per task
- `/timer report` - Table with tracked and quarter-rounded totals
- `/timer report --split` - Divide overlapping time between concurrent tasks
- `/timer day` - Full-day report for today: per-task time, wall clock, timeline
- `/timer day yesterday` / `/timer day 2026-09-07` - Same for another day
- `/timer day --all` - Include every project's log, not just this repository
- `/timer day --split` - Divide overlapping time within that day
- `/timer month` - Billable hours for the current month: per day and per task
- `/timer month 08-2026` - Same for another month (`MM-YYYY`)
- `/timer month --all` / `--split` - Every project's log / divide overlaps per day

## Instructions

1. Parse `$ARGUMENTS`: first word is the action, the rest is an optional task
   list (comma or space separated). Default the action to `status` when nothing
   is supplied. Accept `start` as an alias for `on` and `stop` for `off`.

2. Run the tracker, passing the arguments through unchanged:

   ```bash
   timer.sh <action> [tasks]
   ```

   `timer.sh` is this plugin's `bin/timer.sh`, on the Bash tool's PATH while
   the plugin is enabled. If the shell cannot find it, run
   `${CLAUDE_PLUGIN_ROOT}/bin/timer.sh` instead.

   The script picks the log file from the current git repository name, so run it
   from inside the project. Set `TIMER_PROJECT=<name>` to override.

3. Report the script's output back plainly. For `off`, `report`, `day` and `month`,
   show the tables as printed. Do not editorialise; the numbers are the answer.

4. Exit code 2 (`on`, `pause`, `resume` or `off` without a task) means the
   script could not pick a task and printed the candidates. Ask the user which one to
   act on with AskUserQuestion: one option per listed task, plus `All` when
   there are two or more (the `--all` form). Then run the script again with
   the chosen task list (or `--all`) and report that output. Never pick for
   the user, and never act on every task without that answer.

5. Never look for the session's name or task in Claude Code's own files
   (`~/.claude/sessions/`, `~/.claude/projects/` or transcripts). When the
   task is unclear, ask the user.

## on / pause / resume / off without a task

Precedence when no task is named:

1. The session's task: the last single task named with `on`, `pause`,
   `resume` or `off` in this session (`timer.sh session-task` prints it). The
   script keeps it in its own folder, keyed by the session id. When that task
   is in a state the verb can act on, it is the only one acted on, even when
   other tasks are open:

   | Verb | Acts on the session task when it is |
   |---|---|
   | `on` | paused (resumes) or stopped (restarts) |
   | `pause` | running |
   | `resume` | paused |
   | `off` | running or paused |

2. Otherwise the script prints why the session did not match (no task named
   yet, or the wrong state) and the tasks that could be acted on, and exits 2. Ask which one, as in step 4 above. Candidates are
   the running tasks for `pause`, the paused ones for `resume`, both for
   `off`, and for `on` the paused tasks or, failing that, the last task used.
3. `--all` skips the question and acts on every candidate, which is what the
   bare command used to do.

`Nothing to start/pause/resume/stop.` with exit 0 means there is no candidate
at all; report it and stop.

## day

`day [DATE] [--all] [--split]` answers "what did I work on that day": every
interval of every task is clipped to the calendar day (midnight to midnight,
local time) and summed per task. The output has three parts:

- a table with TRACKED (time on that day), ROUNDED (that figure rounded up to
  the quarter), FIRST and LAST touch, and the task's current STATE;
- a wall-clock line: the union of all intervals, and the span between the
  first and last touch of the day, so idle gaps are visible;
- a timeline, one line per interval in start order, with `(running)` on an
  open one.

`DATE` accepts `today` (default), `yesterday`, `YYYY-MM-DD` or anything GNU
`date -d` understands (`"last friday"`, `"-2 days"`). `--all` reads every log
under `~/.claude/timer/logs/` and adds a PROJECT column, which is the view to
use for a working day that touched more than one repository. `--tsv` prints
one machine-readable row per task (project, task, seconds, rounded seconds,
first epoch, last epoch, state) and is what scripts consume.

A task that ran across midnight is split between the two days. Rounding is per
task per day, so the day total of ROUNDED can exceed the rounded total of the
week; quote the per-task figures when logging.

## month

`month [MM-YYYY] [--all] [--split]` sums the `day` report over every day of
the month that has records. The month defaults to the current one and also
accepts `M-YYYY`, `YYYY-MM` and `last` (the previous month). For the current
month, days after today are not read.

- a per-day table: DATE, DAY, TASKS touched, TRACKED, BILLABLE and WALL clock;
- a per-task table: DAYS worked, TRACKED, BILLABLE and the current STATE;
- a `Billable:` line with the month total in `h m` and in decimal hours
  (`102h 00m = 102.00 hours over 16 day(s)`), plus tracked and wall clock.

BILLABLE is the `day` ROUNDED figure summed: each task's time on each day is
rounded up to the quarter, then the days are added. It therefore matches the
sum of the `day` reports, and is higher than rounding the month total once.
`--all` adds a PROJECT column, the same as `day --all`. `--split` divides
overlapping time within each day before rounding and is the figure to bill
when the NOTE line reports overlaps. `--tsv` prints one row per task per day
(date, project, task, seconds, rounded seconds, state) and is what
scripts consume.

## Rules

- **Rounding.** `report` shows tracked time and time rounded UP to the next
  quarter hour: 8m becomes 15m, 1h 23m becomes 1h 30m, 10h 12m becomes 10h 15m.
  Quote the rounded figure when the time is going to be billed or logged.
  Override the granularity with `TIMER_QUARTER=<seconds>`.

- **Review counts.** Reviewing work is chargeable, so leave the timer running
  while the user reviews a change. Stop it only when they say the task is done
  or ask for the total. A timer left running through a long review will keep
  accruing, so re-check the total right before logging it rather than reusing an
  earlier figure.

- **Overlapping tasks.** When several tasks run at once, each accrues the full
  wall time by default, so the per-task figures add up to more than the clock.
  `report` and `day` print a warning when this happens; `--split` divides the
  shared time evenly instead. Use the split figures for anything billed.

- **Never log time anywhere automatically.** Report the totals and stop.
  Only write worklogs to Jira or any other system when the user asks for it in
  that message, and show the figures for approval first.

- **Task names** are free text, typically a ticket key. Keep them consistent
  across sessions, since totals accumulate per name.

## Other commands

- `timer.sh day DATE --tsv` - machine-readable day rows
- `timer.sh month MM-YYYY --tsv` - machine-readable month rows
- `timer.sh tasks` - list known task names for this project
- `timer.sh session-task` - the task this session last named
- `timer.sh where` - print the log file path
- `timer.sh cancel <task>` - erase a task's entries entirely

The log is a plain TSV (`task`, `event`, `epoch`, `timestamp`) at
`~/.claude/timer/logs/<project>.tsv` and can be edited by hand if an entry is
wrong.
