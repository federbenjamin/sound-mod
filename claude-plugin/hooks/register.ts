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

type Settings = { tracks: number; player: string; mode: string; muffling_max: number; muffling_min: number }

async function writeConfig($: EngineInterface, home: string, settings: Settings) {
  await $.fs.write(`${home}/${STATE_DIR}/config.json`, JSON.stringify(settings))
}

async function readHome($: EngineInterface) {
  const { stdout } = await $.process.run(['/bin/sh', '-c', 'printf %s "$HOME"'])
  return stdout.trim()
}

type Reporter = {
  home: string
  ready?: Promise<void>
  heartbeat?: { cancel(): void }
  isWorking(): boolean
}

// Runs once per session, from whichever hook fires first: a session that enabled the plugin mid-way
// (/reload-plugins) never sees session.start.
async function setUp($: EngineInterface, reporter: Reporter, settings: Settings) {
  reporter.home = await readHome($)
  await writeConfig($, reporter.home, settings)
  await writeSession($, reporter.home, reporter.isWorking())
  reporter.heartbeat = $.clock.every(HEARTBEAT_MS, () => void writeSession($, reporter.home, reporter.isWorking()).catch(() => undefined))
}

function ready($: EngineInterface, reporter: Reporter, settings: Settings) {
  reporter.ready ??= setUp($, reporter, settings)
  return reporter.ready
}

export const register: Register = (on, options) => {
  const settings: Settings = {
    tracks: Number(options.tracks ?? 4),
    player: String(options.player ?? 'spotify'),
    mode: String(options.mode ?? 'instruments'),
    muffling_max: Number(options.muffling_max ?? 7),
    muffling_min: Number(options.muffling_min ?? 0),
  }

  let turnActive = false
  const waiting = new Set<string>()
  const reporter: Reporter = { home: '', isWorking: () => turnActive && waiting.size === 0 }

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await ready($, reporter, settings)
    return started
  })

  on('turn.start', async ($, e, next) => {
    await ready($, reporter, settings)
    if (e.agentId === undefined) {
      turnActive = true
      waiting.clear()
      await writeSession($, reporter.home, reporter.isWorking())
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    await ready($, reporter, settings)
    if (e.agentId === undefined) {
      turnActive = false
      waiting.clear()
      await writeSession($, reporter.home, reporter.isWorking())
    }
    return next(e)
  })

  // A permission dialog: an `ask` verdict on a real main-loop call that a person (not the host's classifier) answers.
  on('tool.check', async ($, e, next) => {
    const verdict = await next(e)
    if (e.agentId === undefined && e.tool_use_id !== undefined && e.approver === 'person' && verdict.decision === 'ask') {
      await ready($, reporter, settings)
      waiting.add(e.tool_use_id)
      await writeSession($, reporter.home, reporter.isWorking())
    }
    return verdict
  })

  // A question or a plan put to the person waits for as long as the call runs; any call's end clears its ask.
  on('tool.call', async ($, e, next) => {
    if (e.agentId !== undefined) return next(e)
    await ready($, reporter, settings)
    const id = e.tool_use_id ?? `${e.tool}:${await $.clock.now()}`
    if (DIALOG_TOOLS.has(e.tool)) {
      waiting.add(id)
      await writeSession($, reporter.home, reporter.isWorking())
    }
    const result = await next(e)
    if (waiting.delete(id)) await writeSession($, reporter.home, reporter.isWorking())
    return result
  })

  on('session.end', async ($, e, next) => {
    turnActive = false
    waiting.clear()
    reporter.heartbeat?.cancel()
    reporter.heartbeat = undefined
    await writeSession($, reporter.home, reporter.isWorking())
    return next(e)
  })
}
