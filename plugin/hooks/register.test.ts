import { expect, test } from 'claude-code/testing'

const SESSION_FILE = '/home/test/.local/state/stemmix/sessions/sess-1.json'

// Hooks stand for the engine; every fs.write the plugin makes is recorded.
function engine(on: any) {
  const writes: { path: string; text: string }[] = []
  on('fs.write', (_: any, e: any) => {
    writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('process.run', () => ({ value: { exitCode: 0, stdout: '/home/test', stderr: '' } }))
  on('session.id', () => ({ value: 'sess-1' }))
  on('clock.now', () => ({ value: 1000 }))
  on('clock.every', () => ({ value: undefined }))
  on('session.start', (_: any, e: any) => ({ cwd: e.cwd }))
  on('session.end', () => ({ sessionId: 'sess-1' }))
  const lastSession = () => {
    const w = writes.filter(x => x.path === SESSION_FILE).at(-1)
    return w && JSON.parse(w.text)
  }
  return { writes, lastSession }
}

const START = { cwd: '/', surface: 'terminal', isInteractive: true } as const

test('session.start writes config.json and an idle session file', { options: { tracks: 3, player: 'music' } }, async ($, on) => {
  const { writes, lastSession } = engine(on)
  await $.session.start(START)

  const config = writes.find(w => w.path === '/home/test/.local/state/stemmix/config.json')
  expect(JSON.parse(config!.text)).toEqual({ tracks: 3, player: 'music' })
  expect(lastSession()).toEqual({ working: false, updatedAt: 1000 })
  await $.session.end({})
})

test('a main-loop turn marks working; a subagent turn changes nothing', async ($, on) => {
  const { writes, lastSession } = engine(on)
  on('turn.start', () => ({ turnId: 't1' }))
  on('turn.complete', () => ({ text: '' }))
  await $.session.start(START)

  await $.turn.start({ text: 'go' })
  expect(lastSession().working).toBe(true)

  const count = writes.length
  await $.turn.start({ text: 'sub', agentId: 'a1' })
  expect(writes.length).toBe(count)
  expect(lastSession().working).toBe(true)

  await $.turn.complete({})
  expect(lastSession().working).toBe(false)
  await $.session.end({})
})

test('an ask verdict stops working until that tool call finishes', async ($, on) => {
  const { lastSession } = engine(on)
  on('turn.start', () => ({ turnId: 't1' }))
  on('tool.check', () => ({ decision: 'ask' }))
  on('classic.PermissionRequest', () => ({ decision: { behavior: 'allow' } }))
  on('tool.call', () => ({ result: {} }))
  await $.session.start(START)
  await $.turn.start({ text: 'go' })
  expect(lastSession().working).toBe(true)

  // The ask itself is raised as a real main-loop call a person answers.
  await $.tool.check({ tool: 'Bash', input: { command: 'ls' }, tool_use_id: 'tu-1', approver: 'person' })
  expect(lastSession().working).toBe(false)

  await $.tool.call({ tool: 'Bash', command: 'ls', tool_use_id: 'tu-1' })
  expect(lastSession().working).toBe(true)
  await $.session.end({})
})

test('session.end writes working false even mid-turn', async ($, on) => {
  const { lastSession } = engine(on)
  on('turn.start', () => ({ turnId: 't1' }))
  await $.session.start(START)
  await $.turn.start({ text: 'go' })
  expect(lastSession().working).toBe(true)

  await $.session.end({})
  expect(lastSession().working).toBe(false)
})
