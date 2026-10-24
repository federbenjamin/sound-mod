import type { EngineInterface, Register } from 'claude-code'

// The daemon reads these files; the shape is `contract/README.md` at the repo root.
const STATE_DIR = '.local/state/stemmix'
const HEARTBEAT_MS = 2000
const DIALOG_TOOLS = new Set(['AskUserQuestion', 'ExitPlanMode'])

async function writeSession($: EngineInterface, home: string, working: boolean) {
  if (home === '') return
  const id = await $.session.id()
  const updatedAt = await $.clock.now()
  await $.fs.write(`${home}/${STATE_DIR}/sessions/${id}.json`, JSON.stringify({ working, updatedAt }))
}

async function writeConfig($: EngineInterface, home: string, tracks: number, player: string) {
  await $.fs.write(`${home}/${STATE_DIR}/config.json`, JSON.stringify({ tracks, player }))
}

async function readHome($: EngineInterface) {
  const { stdout } = await $.process.run(['/bin/sh', '-c', 'printf %s "$HOME"'])
  return stdout.trim()
}

export const register: Register = (on, options) => {
  const tracks = Number(options.tracks ?? 5)
  const player = String(options.player ?? 'spotify')

  let home = ''
  let turnActive = false
  const waiting = new Set<string>()
  let heartbeat: { cancel(): void } | undefined

  const isWorking = () => turnActive && waiting.size === 0

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    home = await readHome($)
    await writeConfig($, home, tracks, player)
    await writeSession($, home, isWorking())
    heartbeat = $.clock.every(HEARTBEAT_MS, () => void writeSession($, home, isWorking()).catch(() => undefined))
    return started
  })

  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined) {
      turnActive = true
      waiting.clear()
      await writeSession($, home, isWorking())
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      turnActive = false
      waiting.clear()
      await writeSession($, home, isWorking())
    }
    return next(e)
  })

  // A permission dialog: an `ask` verdict on a real main-loop call that a person (not the host's classifier) answers.
  on('tool.check', async ($, e, next) => {
    const verdict = await next(e)
    if (e.agentId === undefined && e.tool_use_id !== undefined && e.approver === 'person' && verdict.decision === 'ask') {
      waiting.add(e.tool_use_id)
      await writeSession($, home, isWorking())
    }
    return verdict
  })

  // A question or a plan put to the person waits for as long as the call runs; any call's end clears its ask.
  on('tool.call', async ($, e, next) => {
    if (e.agentId !== undefined) return next(e)
    const id = e.tool_use_id ?? `${e.tool}:${await $.clock.now()}`
    if (DIALOG_TOOLS.has(e.tool)) {
      waiting.add(id)
      await writeSession($, home, isWorking())
    }
    const result = await next(e)
    if (waiting.delete(id)) await writeSession($, home, isWorking())
    return result
  })

  on('session.end', async ($, e, next) => {
    turnActive = false
    waiting.clear()
    heartbeat?.cancel()
    heartbeat = undefined
    await writeSession($, home, false)
    return next(e)
  })
}
