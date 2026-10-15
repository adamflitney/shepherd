declare module 'claude-code' {
  interface PluginState {
    'shepherd-probe': { task: string; waiting: string; presses: number }
  }
}

