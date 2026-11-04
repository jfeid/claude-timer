# Privacy

Worklog Timer (`worklog-timer`) is a Claude Code plugin by Giannis Feidaros
([jfeid](https://github.com/jfeid)). This is what it handles.

## What it stores

On your computer only, under `~/.claude/timer/` (or `TIMER_HOME`):

- **Timer logs**, one per project (`logs/<project>.tsv`): the task names you
  give, such as ticket keys, and the time of each start, pause, resume and
  stop. The project name is the folder name of the git repository.
- **Session files** (`sessions/<session id>`): for each Claude Code session,
  the project and the last task you named there.

Task names are whatever you type. If you put a customer's name or other
personal data in a task name, it is stored in these files like any other.

## What it reads

The files above, the current folder's git top-level path, the session's id
and folder as Claude Code gives them to plugins, and the environment
variables listed in the README. It does not read Claude Code's own files,
your conversation history, transcripts or memory.

## What leaves your computer

Nothing is sent by the plugin. There is no server, account, telemetry or
analytics.

The output of `/timer` and of `timer.sh` (task names, times, reports) is
shown in your Claude Code conversation, and becomes part of what Claude
Code sends to Anthropic for that conversation, under the terms you use
Claude Code with.

## Keeping and deleting

The files are kept until you delete them. Session files untouched for 30
days are removed automatically.

- Delete one task: `timer.sh cancel <task>`.
- Delete everything: remove `~/.claude/timer/` (or your `TIMER_HOME`).
- Uninstalling the plugin leaves the files in place.

## Contact

Giannis Feidaros, [jfeid on GitHub](https://github.com/jfeid),
info@maxweb.gr. Questions can also go to the
[GitHub issues](https://github.com/jfeid/claude-timer/issues).
