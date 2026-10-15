import { describe, expect, test } from 'claude-code/testing'

// Stands for the engine beneath the mod.
function engine(on: any, env: Record<string, string>, crook = { exitCode: 0, stdout: 'Fix the build\nplan 1/3', stderr: '' }) {
  on('session.start', (_$: any, e: any) => ({ sessionId: 's', cwd: e.cwd }))
  on('command.register', () => ({ value: undefined }))
  on('tool.register', () => ({ value: undefined }))
  on('session.id', () => ({ value: 's1' }))
  on('clock.now', () => ({ value: 1000 }))
  on('env.get', (_$: any, e: any) => ({ value: env[e.name] }))
  on('process.run', () => ({ value: { ...crook, isStdoutTruncated: false, isStderrTruncated: false } }))
  on('prompt.submit', (_$: any, e: any) => ({ text: e.text, context: e.context }))
  on('tool.check', () => ({ decision: 'ask' }))
}

describe('shepherd-probe', () => {
  test('attaches the task to the first prompt only', async ($, on) => {
    engine(on, { SHEPHERD_TASK: '7' })
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    const first: any = await $.prompt.submit({ text: 'hello' } as any)
    expect(JSON.stringify(first.context)).toContain('Fix the build')
    const second: any = await $.prompt.submit({ text: 'again' } as any)
    expect(second.context).toBeUndefined()
  })

  test('attaches nothing when there is no task', async ($, on) => {
    engine(on, {}, { exitCode: 1, stdout: '', stderr: 'no task' })
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    const first: any = await $.prompt.submit({ text: 'hello' } as any)
    expect(first.context).toBeUndefined()
  })

  test('denies the close tool', async ($, on) => {
    engine(on, {})
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    const result: any = await $.tool.call({ tool: 'mcp__shepherd-probe__probe_close' } as any)
    expect(JSON.stringify(result)).toContain('only Adam can mark a task done')
  })

  test('leaves a permission prompt alone unless told to hold it', async ($, on) => {
    engine(on, {})
    await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' } as any)
    const verdict: any = await $.tool.check({ tool: 'Bash', input: { command: 'date' } } as any)
    expect(verdict.decision).toBe('ask')
  })
})
