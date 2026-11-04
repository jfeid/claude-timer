# Claude Code timer

[![test](https://github.com/jfeid/claude-timer/actions/workflows/test.yml/badge.svg)](https://github.com/jfeid/claude-timer/actions/workflows/test.yml)

A Claude Code plugin for tracking work time per task. Timers are kept per
project (the git repository) and survive session restarts, so a timer started
in one session can be paused or stopped from another. Reports round time up
to the quarter hour for billing.

The running timer is also shown at the right of the prompt footer, so you can
see it in every session without asking:

```
ABC-123 login | my-repo · ▶ ABC-123 1h 05m +1 running
```

## Install

At the prompt of a Claude Code terminal session:

```
/plugin install timer --marketplace jfeid/claude-timer
```

Answer `y` to add the marketplace, then pick a scope (user scope loads it in
every session). From a shell: `claude plugin install timer --marketplace jfeid/claude-timer`.

On Windows, install [Git for Windows](https://gitforwindows.org/) first; see
[Requirements](#requirements).

## Use

```
/timer on ABC-123          start or resume a task
/timer on ABC-1,ABC-2      start several tasks
/timer pause               pause the session's task
/timer off                 stop the session's task and print its total
/timer status              live state and elapsed time per task
/timer report [--split]    tracked and quarter-rounded totals
/timer day [DATE] [--all]  one day: per-task time, wall clock, timeline
/timer month [MM-YYYY]     billable hours per day and per task
```

`/timer` runs the script directly and prints its output, with no model turn,
so it is instant and costs no tokens. When the script cannot tell which task
you mean, Claude asks you. `/timer` comes from the plugin's UI hooks (mods);
on Claude Code versions without them, ask Claude in plain words and it runs
the same actions through the plugin's skill.

You can also just ask Claude ("start the timer for ABC-123", "how long have I
worked today?"); the skill is picked up from the request.

Without a task name, `on`, `pause`, `resume` and `off` act on the session's
task: the session name (`/rename ABC-123 login`) when it is a known task, or
else the first ticket key in it. When that does not resolve, Claude asks which
task to act on.

Overlapping tasks each count the full wall time by default; `--split` divides
shared time between them. Use the split figures when billing.

### The script

The plugin puts `timer.sh` on the Bash tool's PATH, so your own commands,
skills and scripts run by Claude can call it directly:

```
timer.sh status
timer.sh day yesterday --tsv     machine-readable rows
timer.sh month 08-2026 --tsv
timer.sh where                   path of this project's log
```

To let it run without a permission prompt, add `"Bash(timer.sh:*)"` to
`permissions.allow` in `~/.claude/settings.json`. The `/timer` skill already
allows it for itself.

### The footer

`SESSION | PROJECT · TIMER`:

- `SESSION` is the session name (`/rename`), `PROJECT` the timer project.
- `TIMER` is the session's task when it has a timer, else the first running
  task of the project. `▶` running, `‖` paused, `■` stopped or no timer.
- `+N running`: other tasks of the project running at the same time.

It refreshes every 30 seconds, right after any `timer.sh` call, and on each
prompt. It needs a Claude Code version with plugin UI hooks (mods), in the
terminal or the desktop app. On other versions the timer works without the
footer.

## Data

One TSV file per project at `~/.claude/timer/logs/<project>.tsv`, with the
columns `task`, `event` (`START`, `PAUSE`, `RESUME`, `STOP`), `epoch` and
`timestamp`. It is plain text and can be edited by hand. Nothing is sent
anywhere.

Settings, as environment variables:

| Variable | Default | Effect |
|---|---|---|
| `TIMER_HOME` | `~/.claude/timer` | where `logs/` lives |
| `TIMER_PROJECT` | git top-level folder name | force the project name |
| `TIMER_QUARTER` | `900` | rounding step in seconds |

## Requirements

- bash (3.2 or later) and the usual shell tools: present on Linux and macOS.
- Windows: [Git for Windows](https://gitforwindows.org/), which provides Git
  Bash. `/timer` runs the script with it, found through
  `CLAUDE_CODE_GIT_BASH_PATH` or next to `git`. Without it (PowerShell only)
  the script, `/timer` and the skill do not work.

Optional:

- `jq` is used for reading the session name when installed; without it a
  plain text match is used.
- Dates: with GNU `date` (Linux, Git Bash on Windows, or `gdate` from
  `brew install coreutils` on macOS) `day` takes anything `date -d` reads,
  such as `"last friday"`. With the macOS `date` it takes `today`,
  `yesterday`, `tomorrow` or `YYYY-MM-DD`.

Used daily on Linux. CI runs the script's tests on Linux, macOS and Windows
(Git Bash); the `/timer` command and the footer are tested on Linux and
Windows (Windows Terminal with Git for Windows), not yet on macOS. Reports
from other platforms are welcome in the issues.

## Develop

```
claude --plugin-dir .          load this folder for one session
claude plugin validate .
claude plugin test .
bash tests/timer-cli.sh        timer.sh end to end (CI runs it on Linux, macOS, Windows)
```

## License

MIT
