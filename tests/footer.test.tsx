import { describe, expect, test } from 'claude-code/testing'
import type { TestBody } from 'claude-code/testing'

import {
  answerArgv,
  asBlock,
  bashFromExecPath,
  boundProject,
  boundTask,
  candidates,
  fmt,
  icons,
  isSafeId,
  isWindowsPath,
  pick,
  question,
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

  test("the session file's last line for the project wins", async () => {
    const file = 'proj\tABC-1\nother\tZZZ-1\nproj\tABC-2\n'
    expect(boundTask(file, 'proj')).toBe('ABC-2')
    expect(boundTask(file, 'other')).toBe('ZZZ-1')
    expect(boundTask(file, 'none')).toBe(null)
    expect(boundTask('', 'proj')).toBe(null)
  })

  test("the session's project is the project of its last named task", async () => {
    expect(boundProject('outer\tA-1\ninner\tB-1\nouter\tA-2\n')).toBe('outer')
    expect(boundProject('')).toBe(null)
  })

  test('session ids are file names only', async () => {
    expect(isSafeId('5f3c2a10-1b2c-4d5e-8f90-123456789abc')).toBe(true)
    expect(isSafeId('../x')).toBe(false)
    expect(isSafeId('')).toBe(false)
  })

  test('the session task wins, others are counted', async () => {
    const f = pick('ABC-556', 'proj', totals(LOG, NOW))
    expect(f.task).toBe('ABC-556')
    expect(f.othersRunning).toBe(1)
    expect(pick('OLD-1', 'proj', totals(LOG, NOW)).task).toBe('OLD-1')
  })

  test('without a session task, a running one shows', async () => {
    expect(pick(null, 'proj', totals(LOG, NOW)).task).toBe('ABC-556')
    expect(pick('NEW-1', 'proj', totals(LOG, NOW)).task).toBe('ABC-556')
  })

  test('nothing open', async () => {
    const f = pick(null, 'proj', totals('', NOW))
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

  test('multi-line output is fenced, one line is not', async () => {
    expect(asBlock('ABC-1 started')).toBe('ABC-1 started')
    expect(asBlock('TASK\n----')).toBe('\n```\nTASK\n----\n```')
  })

  test('pause and stop icons: emoji symbols, plain text on Windows', async () => {
    expect(icons(false).PAUSED).toBe('⏸')
    expect(icons(false).STOPPED).toBe('⏹')
    expect(icons(true).PAUSED).toBe('‖')
    expect(icons(true).NONE).toBe('■')
    expect(icons(true).RUNNING).toBe(icons(false).RUNNING)
  })

  test('format', async () => {
    expect(fmt(45 * 60)).toBe('45m')
    expect(fmt(3900)).toBe('1h 05m')
  })
})

describe('the question when no task can be picked', () => {
  const OUT = 'No task given, and this session has not named one yet.\nOpen: ABC-1, ABC-2\nAsk which to stop, then run: timer.sh off <task[,task]|--all>'

  test('candidates come from the label line', async () => {
    expect(candidates(OUT)).toEqual(['ABC-1', 'ABC-2'])
    expect(candidates('Last task: OLD-1')).toEqual(['OLD-1'])
    expect(candidates('Nothing to stop.')).toEqual([])
  })

  test('all tasks for two or more, no change beside one, four options at most', async () => {
    expect(question('off', ['A', 'B']).options).toEqual(['A', 'B', 'All listed tasks'])
    expect(question('on', ['A']).options).toEqual(['A', 'Change nothing'])
    expect(question('off', ['A', 'B', 'C', 'D', 'E']).options).toEqual(['A', 'B', 'C', 'All listed tasks'])
    expect(question('pause', ['A']).text).toBe('Which task for /timer pause?')
  })

  test('the answer becomes the arguments', async () => {
    expect(answerArgv('off', 'ABC-2')).toEqual(['off', 'ABC-2'])
    expect(answerArgv('off', 'All listed tasks')).toEqual(['off', '--all'])
    expect(answerArgv('on', 'Change nothing')).toBe(null)
    expect(answerArgv('on', ' NEW-7 ')).toEqual(['on', 'NEW-7'])
  })

  test('tasks named All or Cancel are tasks, not choices', async () => {
    expect(question('off', ['All', 'OTHER-1']).options).toEqual(['All', 'OTHER-1', 'All listed tasks'])
    expect(answerArgv('off', 'All')).toEqual(['off', 'All'])
    expect(answerArgv('on', 'Cancel')).toEqual(['on', 'Cancel'])
  })
})

const HOME = '/home/u'

test('the footer shows the project of the session root and the session task', async ($, on) => {
  on('env.get', (_, e) => ({ value: e.name === 'HOME' ? HOME : undefined }))
  on('session.id', () => ({ value: 'sid-1' }))
  // The shell moved into a nested repository; the session's root did not.
  on('session.cwd', () => ({ value: '/work/my repo/internal' }))
  on('session.root', () => ({ value: '/work/my repo' }))
  // git answers with the top level of the folder it runs in.
  on('process.run', (_, e) => ({
    value: {
      exitCode: 0,
      stdout: `${e.init?.cwd ?? ''}\n`,
      stderr: '',
      isStdoutTruncated: false,
      isStderrTruncated: false,
    },
  }))
  on('fs.exists', () => ({ value: true }))
  on('fs.read', (_, e) => ({
    value: e.path === `${HOME}/.claude/timer/sessions/sid-1` ? 'my-repo\tXYZ-9\n' : LOG,
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
    plugin: 'worklog-timer',
    component: 'SessionMode',
    requestId: 'mode',
    surface: 'terminal',
    props: { modes: [] },
  })
  const project = await ui.find({ type: 'Text', text: /·/ })
  expect(project?.text).toBe('my-repo · ')
  const timer = await ui.find({ type: 'Text', text: /▶/ })
  expect(timer?.text).toBe('▶ XYZ-9 30m')
  const others = await ui.find({ type: 'Text', text: /running/ })
  expect(others?.text).toBe(' +1 running')
  await ui.unmount()
})

const TYPED = {
  origin: { kind: 'composer' },
  presentation: { isFullscreen: true, columns: 120 },
} as const

type Run = { argv: readonly string[]; env?: Record<string, string> }

// The engine around the plugin for a /timer run: the script answers each run
// from `script`, in turn.
async function startWith(
  $: Parameters<TestBody>[0],
  on: Parameters<TestBody>[1],
  script: { exitCode: number; stdout: string }[],
  runs: Run[],
) {
  on('env.get', (_, e) => ({ value: e.name === 'HOME' ? HOME : undefined }))
  on('session.id', () => ({ value: 'sid-1' }))
  on('session.root', () => ({ value: '/work/repo' }))
  on('process.run', (_, e) => {
    const isTimer = (e.argv[0] ?? '').endsWith('/bin/timer.sh')
    const answer = isTimer ? (script[runs.length] ?? { exitCode: 0, stdout: '' }) : null
    if (isTimer) runs.push({ argv: e.argv.slice(1), env: e.init?.env })
    return {
      value: {
        exitCode: answer ? answer.exitCode : 0,
        stdout: answer ? answer.stdout : '/work/repo\n',
        stderr: '',
        isStdoutTruncated: false,
        isStderrTruncated: false,
      },
    }
  })
  on('fs.exists', () => ({ value: false }))
  on('clock.now', () => ({ value: NOW * 1000 }))
  on('clock.every', () => ({ value: undefined }))
  on('command.register', () => ({ value: { command: 'timer' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: '/work/repo', surface: 'terminal', isInteractive: true })
}

test('/timer runs the script with the session id', async ($, on) => {
  const runs: Run[] = []
  await startWith($, on, [{ exitCode: 0, stdout: 'ABC-1 paused\n' }], runs)

  const r = await $.command.run({ ...TYPED, command: 'timer', args: 'pause ABC-1' })
  expect(r.text).toBe('ABC-1 paused')
  expect(runs[0]?.argv).toEqual(['pause', 'ABC-1'])
  expect(runs[0]?.env).toEqual({ TIMER_SESSION_ID: 'sid-1' })
})

test('/timer asks which task when the script cannot pick one', async ($, on) => {
  const runs: Run[] = []
  let asked: { question: string; options: { label: string }[] } | undefined
  on('tool.call', { tool: 'AskUserQuestion' }, (_, e) => {
    const q = e.questions[0]!
    asked = { question: q.question, options: q.options }
    return { result: { questions: e.questions, answers: { [q.question]: 'ABC-2' } } }
  })
  await startWith(
    $,
    on,
    [
      { exitCode: 2, stdout: 'No task given, and this session has not named one yet.\nOpen: ABC-1, ABC-2\n' },
      { exitCode: 0, stdout: 'ABC-2 stopped — 10m (600s)\n' },
    ],
    runs,
  )

  const r = await $.command.run({ ...TYPED, command: 'timer', args: 'off' })
  expect(asked?.question).toBe('Which task for /timer off?')
  expect(asked?.options.map(o => o.label)).toEqual(['ABC-1', 'ABC-2', 'All listed tasks'])
  expect(runs.map(x => x.argv)).toEqual([['off'], ['off', 'ABC-2']])
  expect(r.text).toBe('ABC-2 stopped — 10m (600s)')
})
