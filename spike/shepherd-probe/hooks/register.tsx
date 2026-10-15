import type { EngineInterface, Register } from 'claude-code'

const DIR = '$HOME/.shepherd-probe'
const CROOK = '$HOME/.shepherd/bin/crook'

const note = ($: EngineInterface, kind: string, data: Record<string, unknown> = {}) =>
  $.clock.now().then(t =>
    $.process
      .run(['sh', '-c', `mkdir -p ${DIR} && cat >> ${DIR}/log.jsonl`], {
        stdin: JSON.stringify({ t, kind, ...data }) + '\n',
        timeoutMs: 2000,
      })
      .catch(() => undefined),
  )

const takeDecision = ($: EngineInterface) =>
  $.process.run(['sh', '-c', `f=${DIR}/decision; [ -f "$f" ] && cat "$f" && rm -f "$f"`], { timeoutMs: 2000 })

const crook = ($: EngineInterface, args: string[]) =>
  $.process.run(['sh', '-c', `exec ${CROOK} "$@"`, 'crook', ...args], { timeoutMs: 5000 })

export const register: Register = on => {
  let taskId: string | undefined

  on('session.start', async ($, e, next) => {
    const result = await next(e)
    await $.command.register({ name: 'probe', description: 'Shepherd probe: open the pane, or /probe send <session> <text>' }).catch(() => {})
    await $.tool.register({
      name: 'probe_log',
      description: 'Probe: append a line to the shepherd task log.',
      inputSchema: { type: 'object', properties: { message: { type: 'string' } }, required: ['message'] },
    })
    await $.tool.register({ name: 'probe_close', description: 'Probe: try to close the task. Always denied.', inputSchema: { type: 'object', properties: {} } })

    taskId = await $.env.get('SHEPHERD_TASK')
    const started = await $.clock.now()
    const shown = taskId ? await crook($, ['task', 'show', taskId]).catch(() => undefined) : undefined
    const brief = shown && shown.exitCode === 0 ? shown.stdout.trim() : ''
    await $.state.set({ plugin: 'shepherd-probe', key: 'task' } as const, brief)
    await note($, 'session.start', {
      sessionId: await $.session.id(),
      taskId: taskId ?? null,
      crookExit: shown?.exitCode ?? null,
      crookMs: (await $.clock.now()) - started,
      briefChars: brief.length,
    })
    return result
  })

  on('prompt.compose', async ($, e, next) => {
    await note($, 'fired.prompt.compose')
    return next(e)
  })

  let briefed = false
  on('prompt.submit', async ($, e, next) => {
    if (briefed || e.command) return next(e)
    const { value } = await $.state.get({ plugin: 'shepherd-probe', key: 'task' } as const)
    briefed = true
    if (!value) return next(e)
    await note($, 'brief.attached', { chars: value.length })
    return next({ ...e, context: [...(e.context ?? []), `Your shepherd task:\n${value}`] })
  })

  on('tool.call', { tool: 'mcp__shepherd-probe__probe_log' }, async ($, e) => {
    const message = String((e as { message?: unknown }).message ?? '')
    const logged = taskId ? await crook($, ['task', 'log', taskId, message]).catch(() => undefined) : undefined
    await note($, 'tool.probe_log', { message, taskId: taskId ?? null, crookExit: logged?.exitCode ?? null })
    return { result: { ok: true }, text: taskId ? 'Logged to the task.' : 'No task on this session; logged to the probe file only.' }
  })

  on('tool.call', { tool: 'mcp__shepherd-probe__probe_close' }, async $ => {
    await note($, 'tool.probe_close.denied')
    return { deny: 'shepherd-probe: only Adam can mark a task done.' }
  })

  on('classic.PermissionRequest', async ($, e, next) => {
    await note($, 'fired.classic.PermissionRequest', { tool: e.tool_name })
    return next(e)
  })

  on('tool.check', async ($, e, next) => {
    const result = await next(e)
    if (result.decision !== 'ask') return result
    const mode = await $.env.get('SHEPHERD_PROBE_PERMS')
    await note($, 'perm.asked', { tool: e.tool, mode: mode ?? 'off' })
    if (mode !== 'hold') return result
    const limit = Number((await $.env.get('SHEPHERD_PROBE_WAIT_MS')) ?? 60000)
    const started = await $.clock.now()
    await $.state.set({ plugin: 'shepherd-probe', key: 'waiting' } as const, e.tool)
    while ((await $.clock.now()) - started < limit) {
      const word = (await takeDecision($)).stdout.trim()
      if (word === 'allow' || word === 'deny') {
        await $.state.set({ plugin: 'shepherd-probe', key: 'waiting' } as const, '')
        await note($, 'perm.answered', { word, afterMs: (await $.clock.now()) - started })
        return { decision: word, reason: word === 'deny' ? 'Denied from outside the session' : undefined }
      }
      await $.clock.sleep(500)
    }
    await $.state.set({ plugin: 'shepherd-probe', key: 'waiting' } as const, '')
    await note($, 'perm.timeout', { limitMs: limit })
    return result
  })

  on('command.run', { command: 'probe' }, async ($, e) => {
    const [verb, to, ...rest] = e.args.trim().split(/\s+/)
    if (verb === 'send' && to && rest.length) {
      const sent = await $.session.send({ to, text: rest.join(' ') })
      await note($, 'session.send', { to, result: JSON.stringify(sent) })
      return { text: `Sent to ${to}: ${JSON.stringify(sent)}` }
    }
    await $.ui.open({ id: 'probe', title: 'Probe' })
    return { text: 'Probe pane opened. Log: ~/.shepherd-probe/log.jsonl' }
  })

  on('ui.press', async ($, e, next) => {
    await note($, 'press', { surface: e.surface, element: e.element })
    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const { value: task = '' } = await $.state.get({ plugin: 'shepherd-probe', key: 'task' } as const)
    const { value: waiting = '' } = await $.state.get({ plugin: 'shepherd-probe', key: 'waiting' } as const)
    const { value: presses = 0 } = await $.state.get({ plugin: 'shepherd-probe', key: 'presses' } as const)
    return (
      <Box>
        <Text dimColor>
          probe · surface {e.surface} · task {task ? task.split('\n')[0] : 'none'} · pressed {presses}
          {waiting ? ` · waiting on ${waiting}` : ''}{' '}
        </Text>
        <Button
          key="ping"
          label="Ping"
          onPress={async () => {
            const held = await $.state.get({ plugin: 'shepherd-probe', key: 'presses' } as const)
            await $.state.set({ plugin: 'shepherd-probe', key: 'presses' } as const, (held.value ?? 0) + 1)
          }}
        />
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: 'probe' }, async ($, e) => {
    const { Box, Markdown } = $.ui.resolve(e)
    const { value: task = '' } = await $.state.get({ plugin: 'shepherd-probe', key: 'task' } as const)
    return (
      <Box flexDirection="column">
        <Markdown
          text={`## Probe\n\nSurface: **${e.surface}**\n\n| Check | Result |\n|---|---|\n| Markdown table | if you can read this, yes |\n| Task | ${task ? 'loaded' : 'none'} |\n\n${task}`}
        />
      </Box>
    )
  })

  on('session.end', async ($, e, next) => {
    const started = await $.clock.now()
    await note($, 'session.end.start', { reason: e.reason })
    const reply = await $.model.complete({ model: 'haiku', prompt: 'Reply with the single word OK.', maxTokens: 8 }).catch(() => undefined)
    await note($, 'session.end.model', { ms: (await $.clock.now()) - started, answered: reply?.isAnswered ?? false })
    return next(e)
  })
}
