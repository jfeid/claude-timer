# Privacy

Worklog Timer (`worklog-timer`) is a Claude Code plugin by Giannis Feidaros
([jfeid](https://github.com/jfeid)). This is what it handles.

## What it stores

On your computer only, under `~/.claude/timer/` (or `TIMER_HOME`):

- **Timer logs**, one per project (`logs/<project>.tsv`): the task names you
  give, such as ticket keys, and the time of each start, pause, resume and
  stop. The project name is the folder name of the git repository.
- **Session files** (`sessions/<session id>`): for each Claude Code session,
  the project, the last task you named there, and the session's name at
  that moment.

Task names are whatever you type. If you put a customer's name or other
personal data in a task name, it is stored in these files like any other.

## What it reads

The files above, the current folder's git top-level path, the session's id
and folder as Claude Code gives them to plugins, and the environment
variables listed in the README.

From Claude Code's own files it reads only the session's entry in
`~/.claude/sessions/<pid>.json`, for three fields: `sessionId` (to find this
session's entry), `name` and `nameSource` (to use the name you gave the
session as its task, and to skip names Claude generated). It does not read
your conversation history, transcripts, memory, settings or credentials.

## What leaves your computer

Nothing. The plugin makes no network connections: it has no server, account,
telemetry, analytics or update check, and everything it reads and writes
stays on your computer.

One thing to know: the output of `/timer` and of `timer.sh` (task names,
times, reports) is shown in your Claude Code conversation, and Claude Code
sends the conversation to Anthropic, as it does with any command's output,
under the terms you use Claude Code with. The plugin adds nothing else to
it: not the logs, and not the session files.

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
