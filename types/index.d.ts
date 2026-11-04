export type TimerState = 'RUNNING' | 'PAUSED' | 'STOPPED' | 'NONE'

export type Footer = {
  session: string
  project: string
  // Task shown in the footer, null when nothing is open in this project.
  task: string | null
  state: TimerState
  seconds: number
  // Other tasks of this project running at the same time.
  othersRunning: number
}

declare module 'claude-code' {
  interface PluginState {
    'timer': { footer: Shaped<Footer | null> }
  }
}
