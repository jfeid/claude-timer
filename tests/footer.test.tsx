import { describe, expect, test } from 'claude-code/testing'
import type { TestBody } from 'claude-code/testing'

import {
  bashFromExecPath,
  fmt,
  isWindowsPath,
  pick,
  sessionTask,
  slugOf,
  timerArgv,
  totals,
} from '../hooks/register'

// The test environment has timers; its lib (es2023, no DOM) does not declare them.
declare const setTimeout: (fn: () => void, ms: number) => unknown

const T0 = 1_792_739_770
const LOG = [
  `ABC-556\tSTART\t${T0}\t-`,
  `ABC-556\tPAUSE\t${T0 + 600}\t-`,
  `ABC-556\tRESUME\t${T0 + 1200}\t-`,
  `XYZ-9\tSTART\t${T0 + 1800}\t-`,
  `OLD-1\tSTART\t${T0}\t-`,
  `OLD-1\tSTOP\t${T0 + 60}\t-`,
  '',
].join('\n')
const NOW = T0 + 3600

describe('log parsing', () => {
  test('totals match timer.sh', async () => {
    const all = totals(LOG, NOW)
    expect(all.get('ABC-556')).toEqual({ seconds: 600 + 2400, state: 'RUNNING' })
    expect(all.get('XYZ-9')).toEqual({ seconds: 1800, state: 'RUNNING' })
    expect(all.get('OLD-1')).toEqual({ seconds: 60, state: 'STOPPED' })
  })

  test('session name resolves to a task', async () => {
    const all = totals(LOG, NOW)
    expect(sessionTask('ABC-556', all)).toBe('ABC-556')
    expect(sessionTask('fix abc-556 login', all)).toBe('ABC-556')
    expect(sessionTask('', all)).toBe(null)
  })

  test('the session task wins, others are counted', async () => {
    const f = pick('ABC-556 login', 'proj', totals(LOG, NOW))
    expect(f.task).toBe('ABC-556')
    expect(f.othersRunning).toBe(1)
  })

  test('without a session task, a running one shows', async () => {
    const f = pick('timer-status-ui', 'proj', totals(LOG, NOW))
    expect(f.task).toBe('ABC-556')
    expect(f.state).toBe('RUNNING')
  })

  test('nothing open', async () => {
    const f = pick('x', 'proj', totals('', NOW))
    expect(f.task).toBe(null)
    expect(f.state).toBe('NONE')
  })

  test('/timer arguments split like a shell would', async () => {
    expect(timerArgv('')).toEqual([])
    expect(timerArgv('  on ABC-1,ABC-2 ')).toEqual(['on', 'ABC-1,ABC-2'])
    expect(timerArgv('day "last friday" --all')).toEqual(['day', 'last', 'friday', '--all'])
  })

  test('project slug from a POSIX or Windows path', async () => {
    expect(slugOf('/work/my repo/')).toBe('my-repo')
    expect(slugOf('C:\\Users\\u\\proj')).toBe('proj')
    expect(slugOf('C:/Users/u/proj')).toBe('proj')
  })

  test('Git Bash next to git on Windows', async () => {
    expect(isWindowsPath('C:\\Users\\u\\.claude')).toBe(true)
    expect(isWindowsPath('/home/u/.claude')).toBe(false)
    expect(bashFromExecPath('C:/Program Files/Git/mingw64/libexec/git-core\n')).toBe(
      'C:/Program Files/Git/bin/bash.exe',
    )
    expect(bashFromExecPath('/usr/lib/git-core')).toBe(null)
  })

  test('format', async () => {
    expect(fmt(45 * 60)).toBe('45m')
    expect(fmt(3900)).toBe('1h 05m')
  })
})

test('the footer shows session, project and the session task', async ($, on) => {
  const HOME = '/home/u'
  on('env.get', (_, e) => ({ value: e.name === 'HOME' ? HOME : undefined }))
  on('session.id', () => ({ value: 'sid-1' }))
  on('session.cwd', () => ({ value: '/work/my repo' }))
  on('process.run', () => ({
    value: {
      exitCode: 0,
      stdout: '/work/my repo\n',
      stderr: '',
      isStdoutTruncated: false,
      isStderrTruncated: false,
    },
  }))
  on('fs.list', () => ({ value: [{ name: '42.json', kind: 'file', size: 1, mtimeMs: 0, isLink: false }] }))
  on('fs.exists', () => ({ value: true }))
  on('fs.read', (_, e) => ({
    value: e.path.endsWith('.json')
      ? JSON.stringify({ sessionId: 'sid-1', name: 'ABC-556 login' })
      : LOG,
  }))
  on('clock.now', () => ({ value: NOW * 1000 }))
  on('clock.every', () => ({ value: undefined }))
  on('command.register', () => ({ value: { command: 'timer' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })

  await $.session.start({ cwd: '/work/my repo', surface: 'terminal', isInteractive: true })
  // The refresh runs in the background; give it a moment to land.
  await new Promise<void>(r => setTimeout(r, 50))

  const ui = await $.ui.mount({
    plugin: 'timer',
    component: 'SessionMode',
    requestId: 'mode',
    surface: 'terminal',
    props: { modes: [] },
  })
  const names = await ui.find({ type: 'Text', text: /\|/ })
  expect(names?.text).toBe('ABC-556 login | my-repo · ')
  const timer = await ui.find({ type: 'Text', text: /▶/ })
  expect(timer?.text).toBe('▶ ABC-556 50m')
  const others = await ui.find({ type: 'Text', text: /running/ })
  expect(others?.text).toBe(' +1 running')
  await ui.unmount()
})

const TYPED = {
  origin: { kind: 'composer' },
  presentation: { isFullscreen: true, columns: 120 },
} as const

type Run = { argv: readonly string[]; env?: Record<string, string> }

// The engine around the plugin for a /timer run: the script answers `script`.
async function startWith(
  $: Parameters<TestBody>[0],
  on: Parameters<TestBody>[1],
  script: { exitCode: number; stdout: string },
  runs: Run[],
) {
  on('env.get', (_, e) => ({ value: e.name === 'HOME' ? '/home/u' : undefined }))
  on('session.id', () => ({ value: 'sid-1' }))
  on('session.cwd', () => ({ value: '/work/repo' }))
  on('process.run', (_, e) => {
    const isTimer = (e.argv[0] ?? '').endsWith('/bin/timer.sh')
    if (isTimer) runs.push({ argv: e.argv.slice(1), env: e.init?.env })
    return {
      value: {
        exitCode: isTimer ? script.exitCode : 0,
        stdout: isTimer ? script.stdout : '/work/repo\n',
        stderr: '',
        isStdoutTruncated: false,
        isStderrTruncated: false,
      },
    }
  })
  on('fs.list', () => ({ value: [{ name: '42.json', kind: 'file', size: 1, mtimeMs: 0, isLink: false }] }))
  on('fs.exists', () => ({ value: false }))
  on('fs.read', () => ({ value: JSON.stringify({ sessionId: 'sid-1', name: 'ABC-1 login' }) }))
  on('clock.now', () => ({ value: NOW * 1000 }))
  on('clock.every', () => ({ value: undefined }))
  on('clock.after', () => ({ value: undefined }))
  on('command.register', () => ({ value: { command: 'timer' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: '/work/repo', surface: 'terminal', isInteractive: true })
}

test('/timer runs the script and prints its output', async ($, on) => {
  const runs: Run[] = []
  await startWith($, on, { exitCode: 0, stdout: 'ABC-1 paused at 50m\n' }, runs)

  const r = await $.command.run({ ...TYPED, command: 'timer', args: 'pause ABC-1' })
  expect(r.text).toBe('ABC-1 paused at 50m')
  expect(runs[0]?.argv).toEqual(['pause', 'ABC-1'])
  expect(runs[0]?.env).toEqual({ TIMER_SESSION_NAME: 'ABC-1 login' })
})

test('/timer hands the question to Claude when no task can be picked', async ($, on) => {
  const runs: Run[] = []
  let asked = ''
  on('prompt.submit', (_, e) => {
    asked = e.text
    return { text: e.text }
  })
  await startWith($, on, { exitCode: 2, stdout: 'Running: ABC-1 ABC-2\n' }, runs)

  const r = await $.command.run({ ...TYPED, command: 'timer', args: 'off' })
  await new Promise<void>(res => setTimeout(res, 50))
  expect(r.text).toBe('Running: ABC-1 ABC-2')
  expect(asked).toContain('AskUserQuestion')
  expect(asked).toContain('`timer.sh off <choice>`')
})
