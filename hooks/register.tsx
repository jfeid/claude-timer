import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Footer, TimerState } from '../types'

// Shows "SESSION | PROJECT · ▶ TASK 1h 05m" at the right of the prompt footer.
// Reads the same log as ~/.claude/timer/timer.sh, resolved the same way:
// project = basename of the git top level (or TIMER_PROJECT), task = the
// session name when it is a known task, else the first ticket key in it.

const footer = atom({ plugin: 'timer', key: 'footer' } as const, null, {
  shape: 'footer-1',
})

const REFRESH_MS = 30_000
const TICKET = /\b[A-Z][A-Z0-9]+-[0-9]+\b/

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

// Same as timer.sh's session_task().
export function sessionTask(name: string, known: Totals): string | null {
  if (!name) return null
  if (known.has(name)) return name
  return name.toUpperCase().match(TICKET)?.[0] ?? name
}

export function pick(
  session: string,
  project: string,
  all: Totals,
): Footer {
  const running = [...all].filter(([, r]) => r.state === 'RUNNING').map(([t]) => t)
  const own = sessionTask(session, all)
  const ownRow = own ? all.get(own) : undefined
  // The session's own task wins whenever it has a timer; otherwise show
  // what is running in this project, so a forgotten timer is still visible.
  const task = ownRow ? own : (running[0] ?? null)
  const row = task ? all.get(task) : undefined
  return {
    session,
    project,
    task,
    state: row?.state ?? 'NONE',
    seconds: row?.seconds ?? 0,
    othersRunning: running.filter(t => t !== task).length,
  }
}

export function fmt(s: number): string {
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  return h > 0 ? `${h}h ${String(m).padStart(2, '0')}m` : `${m}m`
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
  const base = top.replace(/\/+$/, '').split('/').pop() ?? ''
  return base.replace(/[^A-Za-z0-9._-]/g, '-')
}

// The session's name, from ~/.claude/sessions/<pid>.json (the file whose
// sessionId is ours), as timer.sh reads it.
let sessionFile: string | null = null
async function sessionName($: EngineInterface, home: string): Promise<string> {
  const id = await $.session.id()
  const readName = async (path: string): Promise<string | null> => {
    try {
      const j = JSON.parse(await $.fs.read(path)) as { sessionId?: string; name?: string }
      return j.sessionId === id ? (j.name ?? '') : null
    } catch {
      return null
    }
  }
  if (sessionFile) {
    const name = await readName(sessionFile)
    if (name !== null) return name
    sessionFile = null
  }
  const dir = `${home}/.claude/sessions`
  for (const entry of await $.fs.list(dir)) {
    if (entry.kind !== 'file' || !entry.name.endsWith('.json')) continue
    const path = `${dir}/${entry.name}`
    const name = await readName(path)
    if (name !== null) {
      sessionFile = path
      return name
    }
  }
  return ''
}

let busy = false
async function refresh($: EngineInterface): Promise<void> {
  if (busy) return
  busy = true
  try {
    const home = (await $.env.get('HOME')) ?? ''
    const root = (await $.env.get('TIMER_HOME')) ?? `${home}/.claude/timer`
    const cwd = await $.session.cwd()
    const [project, session] = await Promise.all([
      projectSlug($, cwd),
      sessionName($, home),
    ])
    const logPath = `${root}/logs/${project}.tsv`
    const log = (await $.fs.exists(logPath)) ? await $.fs.read(logPath) : ''
    const now = Math.floor((await $.clock.now()) / 1000)
    const next = pick(session, project, totals(log, now))
    await update($, footer, () => next)
  } catch (err) {
    $.ui.log(`timer: refresh failed: ${String(err)}`, { to: 'debug' })
  } finally {
    busy = false
  }
}

const ICON: Record<TimerState, string> = {
  RUNNING: '▶',
  PAUSED: '⏸',
  STOPPED: '⏹',
  NONE: '⏹',
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

async function runTimer(
  $: EngineInterface,
  argv: string[],
): Promise<{ code: number; out: string }> {
  const home = (await $.env.get('HOME')) ?? ''
  const session = await sessionName($, home).catch(() => '')
  const r = await $.process.run([`${$.plugin.root}/bin/timer.sh`, ...argv], {
    cwd: await $.session.cwd(),
    // The script finds the session name from CLAUDE_PID, which a mod's child
    // may not have; hand it the name the footer already resolved.
    env: session ? { TIMER_SESSION_NAME: session } : {},
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
        description: 'Work timer: on, pause, resume, off, status, report, day, month',
        argumentHint: '[on|pause|resume|off|status|report|day|month] [task,...|--all|DATE]',
      })
    } catch (err) {
      // Another command already owns /timer; the footer still works.
      $.ui.log(`timer: /timer not registered: ${String(err)}`)
    }
    return started
  })

  // Runs timer.sh at once, with no model turn. Only when the script cannot
  // pick a task (exit 2) is Claude asked to put the question to the person.
  on('command.run', { command: 'timer' }, async ($, e) => {
    const argv = timerArgv(e.args)
    const shown = `/timer ${argv.join(' ')}`.trimEnd()
    let res: { code: number; out: string }
    try {
      res = await runTimer($, argv)
    } catch (err) {
      return { text: `timer.sh failed: ${String(err)}` }
    }
    void refresh($)
    const out = res.out || '(no output)'
    if (res.code === 2) {
      const verb = argv[0] ?? 'status'
      const text =
        `I ran \`${shown}\`, but it could not pick a task. timer.sh printed:\n\n${out}\n\n` +
        'Ask me which task to act on with AskUserQuestion: one option per listed ' +
        'task, plus "All" (the --all form) when there are two or more. Then run ' +
        `\`timer.sh ${verb} <choice>\` and report its output plainly.`
      // A prompt submitted from inside this run would wait on the run itself;
      // send it once the command has finished.
      $.clock.after(50, () => void $.prompt.submit({ text }))
      return { text: out }
    }
    return { text: out, context: [`${shown} printed:\n${out}`] }
  }).catch(($, e, next) => (next.called ? next(e) : { text: 'timer: the command failed to run' }))

  // Pick up /timer on|pause|off at once instead of on the next tick.
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const ran = await next(e)
    if (e.command.includes('timer.sh')) void refresh($)
    return ran
  }).catch(($, e, next) => next(e))

  on('prompt.submit', ($, e, next) => {
    void refresh($)
    return next(e)
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'SessionMode' }, async ($, e, next) => {
    const f = await read($, footer)
    if (!f) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    const session = f.session ? f.session.slice(0, 40) : 'unnamed'
    const timer = f.task
      ? `${ICON[f.state]} ${f.task} ${fmt(f.seconds)}`
      : `${ICON.NONE} no timer`
    return (
      <Box>
        {e.props.modes.length > 0 && (
          <Text dimColor>{e.props.modes.join(' & ')} · </Text>
        )}
        <Text dimColor>
          {session} | {f.project} ·{' '}
        </Text>
        <Text color={COLOR[f.state]}>{timer}</Text>
        {f.othersRunning > 0 && (
          <Text color="warning"> +{f.othersRunning} running</Text>
        )}
      </Box>
    )
  })
}
