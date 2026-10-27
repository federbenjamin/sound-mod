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
async function setUp($: EngineInterface, reporter: Reporter) {
  reporter.home = await readHome($)
  await writeSession($, reporter.home, reporter.isWorking())
  reporter.heartbeat = $.clock.every(HEARTBEAT_MS, () => void writeSession($, reporter.home, reporter.isWorking()).catch(() => undefined))
}

function ready($: EngineInterface, reporter: Reporter) {
  reporter.ready ??= setUp($, reporter)
  return reporter.ready
}

export const register: Register = on => {
  let turnActive = false
  const waiting = new Set<string>()
  const reporter: Reporter = { home: '', isWorking: () => turnActive && waiting.size === 0 }

  on('session.start', async ($, e, next) => {
    const started = await next(e)
    await ready($, reporter)
    return started
  })

  on('turn.start', async ($, e, next) => {
    await ready($, reporter)
    if (e.agentId === undefined) {
      turnActive = true
      waiting.clear()
      await writeSession($, reporter.home, reporter.isWorking())
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    await ready($, reporter)
    if (e.agentId === undefined) {
      turnActive = false
      waiting.clear()
      await writeSession($, reporter.home, reporter.isWorking())
    }
    return next(e)
  })

  // A question or a plan put to the person waits for as long as the call runs. A permission ask does not count:
  // in auto mode the classifier settles it with no dialog, and a plugin cannot read the session's mode.
  on('tool.call', async ($, e, next) => {
    if (e.agentId !== undefined) return next(e)
    await ready($, reporter)
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
