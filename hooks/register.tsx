import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Footer, TimerState } from '../types'

// Shows "PROJECT · ▶ TASK 1h 05m" at the right of the prompt footer.
// Reads the same files as bin/timer.sh, resolved the same way:
// project = TIMER_PROJECT, else the project of the session's named task, else
// the basename of the git top level of the session's root folder; task = the
// session's task: the session's name when the person set it (read from Claude
// Code's sessions/<pid>.json) unless a task was named since, which timer.sh
// keeps in <TIMER_HOME>/sessions/<session id>.

const footer = atom({ plugin: 'worklog-timer', key: 'footer' } as const, null, {
  shape: 'footer-2',
})

const REFRESH_MS = 30_000

type Totals = Map<string, { seconds: number; state: TimerState }>

// Same rules as timer.sh's totals(): START/RESUME open an interval,
// PAUSE/STOP close it; an open interval runs to now.
export function totals(log: string, nowSec: number): Totals {
  const out: Totals = new Map()
  const open = new Map<string, number>()
  const last = new Map<string, string>()
  for (const line of log.split('\n')) {
    const [task, ev, ts] = line.split('\t')
    if (!task || !ev || !ts) continue
    const t = Number(ts)
    if (!out.has(task)) out.set(task, { seconds: 0, state: 'NONE' })
    const row = out.get(task)!
    if (ev === 'START' || ev === 'RESUME') {
      if (!open.has(task)) open.set(task, t)
    } else if (ev === 'PAUSE' || ev === 'STOP') {
      const from = open.get(task)
      if (from !== undefined) {
        row.seconds += t - from
        open.delete(task)
      }
    }
    last.set(task, ev)
  }
  for (const [task, row] of out) {
    const from = open.get(task)
    if (from !== undefined) {
      row.seconds += nowSec - from
      row.state = 'RUNNING'
    } else {
      row.state = last.get(task) === 'PAUSE' ? 'PAUSED' : 'STOPPED'
    }
  }
  return out
}

// Same as timer.sh's bound_line(): the last "project<TAB>task<TAB>name" line
// of the session file for this project, name being the session's name when
// the task was named.
export function boundTask(
  sessionFile: string,
  project: string,
): { task: string; name: string } | null {
  let bound: { task: string; name: string } | null = null
  for (const line of sessionFile.split('\n')) {
    const [p, t, n] = line.split('\t')
    if (p === project && t) bound = { task: t, name: n ?? '' }
  }
  return bound
}

// Same as timer.sh's session_task(): the session's name when it was set or
// changed after the last task named in this project, else that task.
export function sessionTask(sessionFile: string, project: string, name: string): string | null {
  const bound = boundTask(sessionFile, project)
  if (name && name !== (bound?.name ?? '')) return name
  return bound?.task ?? null
}

// Same as timer.sh's session_name(), for one Claude Code session file: null
// when the file is another session's (or unreadable); '' when the name is one
// Claude generated (nameSource "derived") or holds spaces or commas, which
// cannot be a task; else the name the person set.
export function nameFromSessionFile(json: string, id: string): string | null {
  let j: { sessionId?: unknown; name?: unknown; nameSource?: unknown }
  try {
    j = JSON.parse(json) as typeof j
  } catch {
    return null
  }
  if (!j || j.sessionId !== id) return null
  const name = typeof j.name === 'string' && j.nameSource !== 'derived' ? j.name : ''
  return /[\s,]/.test(name) ? '' : name
}

// Same as timer.sh's project_slug() in a session: the project of the
// session file's last line, the project the session last named a task in.
export function boundProject(sessionFile: string): string | null {
  let project: string | null = null
  for (const line of sessionFile.split('\n')) {
    const [p, t] = line.split('\t')
    if (p && t) project = p
  }
  return project
}

// Session ids timer.sh accepts as a file name.
export const isSafeId = (id: string): boolean => /^[A-Za-z0-9_-]+$/.test(id)

export function pick(bound: string | null, project: string, all: Totals): Footer {
  const running = [...all].filter(([, r]) => r.state === 'RUNNING').map(([t]) => t)
  // The session's own task wins whenever it has a timer; otherwise show
  // what is running in this project, so a forgotten timer is still visible.
  const task = bound && all.has(bound) ? bound : (running[0] ?? null)
  const row = task ? all.get(task) : undefined
  return {
    project,
    task,
    state: row?.state ?? 'NONE',
    seconds: row?.seconds ?? 0,
    othersRunning: running.filter(t => t !== task).length,
  }
}

export function fmt(s: number): string {
  // Not `h`: JSX in this file compiles to calls of h.
  const hours = Math.floor(s / 3600)
  const mins = Math.floor((s % 3600) / 60)
  return hours > 0 ? `${hours}h ${String(mins).padStart(2, '0')}m` : `${mins}m`
}

async function projectSlug($: EngineInterface, cwd: string): Promise<string> {
  const forced = await $.env.get('TIMER_PROJECT')
  if (forced) return forced
  let top = cwd
  try {
    const git = await $.process.run(['git', 'rev-parse', '--show-toplevel'], {
      cwd,
      timeoutMs: 5000,
    })
    if (git.exitCode === 0 && git.stdout.trim()) top = git.stdout.trim()
  } catch {
    // not a repository, or git missing: fall back to the directory
  }
  return slugOf(top)
}

// The last path segment, `/` or `\` separated, as a log file name.
export function slugOf(top: string): string {
  const base = top.replace(/[\\/]+$/, '').split(/[\\/]/).pop() ?? ''
  return base.replace(/[^A-Za-z0-9._-]/g, '-')
}

// HOME, or USERPROFILE on Windows where HOME is usually unset; Git Bash sets
// its HOME from USERPROFILE too, so timer.sh reads the same folders.
async function homeDir($: EngineInterface): Promise<string> {
  return (await $.env.get('HOME')) || (await $.env.get('USERPROFILE')) || ''
}

// TIMER_HOME, else ~/.claude/timer.
async function timerHome($: EngineInterface): Promise<string> {
  return (await $.env.get('TIMER_HOME')) || `${await homeDir($)}/.claude/timer`
}

// The session's name when the person set it, from the file in Claude Code's
// sessions/ folder whose sessionId is this session's ('' when none), as
// timer.sh reads it. The file found is remembered for the next refresh.
let sessionPath: string | null = null
async function sessionName($: EngineInterface): Promise<string> {
  const id = await $.session.id()
  const nameIn = async (path: string): Promise<string | null> => {
    try {
      return nameFromSessionFile(await $.fs.read(path), id)
    } catch {
      return null
    }
  }
  if (sessionPath) {
    const name = await nameIn(sessionPath)
    if (name !== null) return name
    sessionPath = null
  }
  const config = (await $.env.get('CLAUDE_CONFIG_DIR')) || `${await homeDir($)}/.claude`
  const dir = `${config}/sessions`
  if (!(await $.fs.exists(dir).catch(() => false))) return ''
  for (const entry of await $.fs.list(dir)) {
    if (entry.kind !== 'file' || !entry.name.endsWith('.json')) continue
    const name = await nameIn(`${dir}/${entry.name}`)
    if (name !== null) {
      sessionPath = `${dir}/${entry.name}`
      return name
    }
  }
  return ''
}

export const isWindowsPath = (p: string): boolean => /^[A-Za-z]:[\\/]|^\\\\/.test(p)

// Git's install folder from `git --exec-path`
// (<Git>/mingw64/libexec/git-core), and its bash.exe.
export function bashFromExecPath(execPath: string): string | null {
  const path = execPath.trim()
  const root = path.replace(/[\\/]+(mingw64|mingw32|clangarm64|ucrt64)[\\/]+libexec[\\/]+git-core$/i, '')
  return root && root !== path ? `${root}/bin/bash.exe` : null
}

// On Windows a .sh file does not run by itself, and `bash` on PATH is often
// WSL's, which cannot see C:\ paths. Use Git Bash, found the way Claude
// Code finds it: CLAUDE_CODE_GIT_BASH_PATH, then next to git.
let gitBash: string | null = null
async function findGitBash($: EngineInterface): Promise<string | null> {
  if (gitBash) return gitBash
  const candidates: string[] = []
  const set = await $.env.get('CLAUDE_CODE_GIT_BASH_PATH')
  if (set) candidates.push(set)
  try {
    const r = await $.process.run(['git', '--exec-path'], { timeoutMs: 5000 })
    const bash = r.exitCode === 0 ? bashFromExecPath(r.stdout) : null
    if (bash) candidates.push(bash)
  } catch {
    // git missing: try the default install folder
  }
  candidates.push('C:/Program Files/Git/bin/bash.exe')
  for (const c of candidates) {
    if (await $.fs.exists(c).catch(() => false)) return (gitBash = c)
  }
  return null
}

async function readIfExists($: EngineInterface, path: string): Promise<string> {
  return (await $.fs.exists(path)) ? await $.fs.read(path) : ''
}

let busy = false
async function refresh($: EngineInterface): Promise<void> {
  if (busy) return
  busy = true
  try {
    const root = await timerHome($)
    const id = await $.session.id()
    const binding = isSafeId(id) ? await readIfExists($, `${root}/sessions/${id}`) : ''
    // As timer.sh: TIMER_PROJECT, else the project of the session's named
    // task, else the git top level of the session's root folder.
    const project =
      (await $.env.get('TIMER_PROJECT')) ||
      boundProject(binding) ||
      (await projectSlug($, await $.session.root()))
    const log = await readIfExists($, `${root}/logs/${project}.tsv`)
    const now = Math.floor((await $.clock.now()) / 1000)
    const name = await sessionName($).catch(() => '')
    const next = pick(sessionTask(binding, project, name), project, totals(log, now))
    await update($, footer, () => next)
  } catch (err) {
    $.ui.log(`timer: refresh failed: ${String(err)}`, { to: 'debug' })
  } finally {
    busy = false
  }
}

// ⏸ and ⏹ where the terminal draws them as text. Windows Terminal draws
// them as two-column emoji over the next character, so Windows (a C:\ plugin
// folder) gets plain text symbols.
export function icons(isWindows: boolean): Record<TimerState, string> {
  return isWindows
    ? { RUNNING: '▶', PAUSED: '‖', STOPPED: '■', NONE: '■' }
    : { RUNNING: '▶', PAUSED: '⏸', STOPPED: '⏹', NONE: '⏹' }
}
const COLOR: Record<TimerState, 'success' | 'warning' | 'error'> = {
  RUNNING: 'success',
  PAUSED: 'warning',
  STOPPED: 'error',
  NONE: 'error',
}

// `/timer <args>` as the person typed it, split the way the shell would hand
// the words to timer.sh (which joins and re-splits them itself).
export function timerArgv(args: string): string[] {
  return args.replace(/["']/g, '').trim().split(/\s+/).filter(Boolean)
}

// Command output is drawn as Markdown after a "timer: " label, where a line
// of dashes under a table header turns it into a heading. Fence tables, on
// their own lines, so columns and rules stay.
export function asBlock(out: string): string {
  return out.includes('\n') ? '\n```\n' + out + '\n```' : out
}

// The tasks timer.sh listed when it could not pick one (exit 2), from its
// "Paused: A, B" (or Last task, Running, Open) line.
export function candidates(out: string): string[] {
  const m = out.match(/^(?:Paused|Last task|Running|Open): (.+)$/m)
  return m?.[1] ? m[1].split(',').map(t => t.trim()).filter(Boolean) : []
}

// The two choices that are not a task. Their labels hold a space, which no
// task name can (timer.sh splits names on spaces and commas), so a task
// named All or Cancel is never read as one of them.
export const ALL_TASKS = 'All listed tasks'
export const NO_CHANGE = 'Change nothing'

// The question for the person: up to four options, ALL_TASKS (the --all
// form) when there are two or more tasks, NO_CHANGE beside a single one. A
// task past the first three is typed under the dialog's Other.
export function question(verb: string, tasks: string[]): { text: string; options: string[] } {
  const options = tasks.length >= 2 ? [...tasks.slice(0, 3), ALL_TASKS] : [...tasks, NO_CHANGE]
  return { text: `Which task for /timer ${verb}?`, options }
}

// timer.sh arguments for the answer, or null when nothing should run. REST
// is what followed the verb when no task was named, such as trim's time.
export function answerArgv(verb: string, answer: string, rest: string[] = []): string[] | null {
  const a = answer.trim()
  if (!a || a === NO_CHANGE) return null
  if (a === ALL_TASKS) return [verb, '--all', ...rest]
  return [verb, ...timerArgv(a), ...rest]
}

async function runTimer(
  $: EngineInterface,
  argv: string[],
): Promise<{ code: number; out: string }> {
  const script = `${$.plugin.root}/bin/timer.sh`
  let cmd = [script]
  if (isWindowsPath($.plugin.root)) {
    const bash = await findGitBash($)
    if (!bash) {
      return {
        code: 1,
        out: 'timer: Git Bash not found. Install Git for Windows, or set CLAUDE_CODE_GIT_BASH_PATH to its bash.exe.',
      }
    }
    cmd = [bash, script.replace(/\\/g, '/')]
  }
  const r = await $.process.run([...cmd, ...argv], {
    // The session's root, where it started: a shell `cd` into a nested
    // repository (say internal/) does not move the session to another project.
    cwd: await $.session.root(),
    // The session id names the file where timer.sh keeps the session's task.
    // The script finds the session's name from CLAUDE_PID, which this child
    // does not have; hand it the name the footer reads ('' for none).
    env: {
      TIMER_SESSION_ID: await $.session.id(),
      TIMER_SESSION_NAME: await sessionName($).catch(() => ''),
    },
    timeoutMs: 30_000,
  })
  const out = [r.stdout, r.stderr].map(s => s.trimEnd()).filter(Boolean).join('\n')
  return { code: r.exitCode ?? 1, out }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    void refresh($)
    $.clock.every(REFRESH_MS, () => void refresh($))
    // A plain /timer. The skill is named work-timer so it does not claim
    // the name: a plugin skill called timer would own /timer.
    try {
      await $.command.register({
        name: 'timer',
        description: 'Work timer: on, pause, resume, off, trim, status, list, report, day, month',
        argumentHint: '[on|pause|resume|off|trim|status|list|report|day|month] [task,...|--all|DATE|HH:MM|-DURATION|running|paused|stopped]',
      })
    } catch (err) {
      // Another command already owns /timer; the footer still works.
      $.ui.log(`timer: /timer not registered: ${String(err)}`)
    }
    return started
  })

  // Runs timer.sh at once, with no model turn. When the script cannot pick a
  // task (exit 2), the person is asked which one, and the answer runs.
  on('command.run', { command: 'timer' }, async ($, e) => {
    let argv = timerArgv(e.args)
    let res = await runTimer($, argv)
    void refresh($)
    if (res.code === 2) {
      const verb = argv[0] ?? 'status'
      const tasks = candidates(res.out)
      if (tasks.length === 0) return { text: asBlock(res.out) }
      const q = question(verb, tasks)
      let answer: string
      try {
        answer = await $.ui.ask(q.text, { options: q.options, header: 'Timer' })
      } catch {
        // Dismissed: show what the script said and change nothing.
        return { text: asBlock(res.out) }
      }
      const again = answerArgv(verb, answer, argv.slice(1))
      if (!again) return { text: 'Nothing changed.' }
      argv = again
      res = await runTimer($, argv)
      void refresh($)
    }
    const out = res.out || '(no output)'
    return { text: asBlock(out), context: [`/timer ${argv.join(' ')} printed:\n${out}`] }
  }).catch(($, e, next) => next(e))

  // Pick up timer.sh runs from Claude's Bash tool at once, not on the next tick.
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const ran = await next(e)
    if (e.command.includes('timer.sh')) void refresh($)
    return ran
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => {
    const f = await read($, footer)
    if (!f) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    const icon = icons(isWindowsPath($.plugin.root))
    const timer = f.task
      ? `${icon[f.state]} ${f.task} ${fmt(f.seconds)}`
      : `${icon.NONE} no timer`
    return (
      <Box>
        {e.props.modes.length > 0 && (
          <Text dimColor>{e.props.modes.join(' & ')} · </Text>
        )}
        <Text dimColor>{f.project} · </Text>
        <Text color={COLOR[f.state]}>{timer}</Text>
        {f.othersRunning > 0 && (
          <Text color="warning"> +{f.othersRunning} running</Text>
        )}
      </Box>
    )
  })
}
