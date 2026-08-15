/**
 * dsh-subagent-cwd — enhanced subagent delegation tools with per-call
 * working-directory control, for DeepSeek Harness.
 *
 * Everything in `dsh-subagent-tools`, plus a per-call `cwd` parameter. The
 * `cwd` parameter is the one capability that cannot be delivered by a pure
 * plugin: `SubagentStartRequest` has no cwd field, and the in-process drive
 * layer (foreground `startInProcessRun` and the continuable manager's child
 * creation) never forwards a per-call cwd into the child session meta.
 * Therefore this package ships the two in-process provider patches it needs:
 *
 *   patches/01-in-process-driver.patch   foreground child meta merge
 *   patches/02-subagent-bundle.patch     continuable child create.meta merge
 *
 * Install this package INSTEAD of dsh-subagent-tools (they expose the same
 * tool surface; installing both collides).
 *
 * @module dsh-subagent-cwd
 */

import z from '@deepseek-ai/schemastery'
import { defineTool } from '@deepseek-ai/dsh-tools'
import { assertSubagentMaxDepth, settleRun } from '@deepseek-ai/dsh-subagent'
import { readFile, readdir } from 'node:fs/promises'
import { statSync } from 'node:fs'
import { isAbsolute, join } from 'node:path'
import { parse as parseYaml } from 'yaml'
import { dshHomePath } from '@deepseek-ai/dsh-home-paths'

export const name = 'dsh-subagent-cwd'
export const inject = ['tools', 'subagents', 'systemPrompt']

/** Prompt order after bounded delegation policy and before child reporting. */
const SUBAGENT_SECTION_ORDER = 116.5

/** Config: which registered provider this tool delegates to, plus child defaults. */
export const Config = z.object({
  provider: z.string().required(),
  toolName: z.string().default('subagent'),
  enableRunInBackground: z.boolean().default(true),
  backgroundMode: z.union(['one-shot', 'continuable']).default('one-shot'),
  // Prevent Schemastery from materializing omitted agentOptions as `{}`.
  agentOptions: z.object({
    provider: z.string(),
    model: z.string(),
    maxTokens: z.number().step(1).min(1).max(Number.MAX_SAFE_INTEGER),
  }).default(undefined),
  persona: z.string(),
  // Preserve omission; Schemastery's `{ allow: [] }` default would deny every tool.
  toolFilter: z.object({
    allow: z.array(z.string()).default(undefined),
    deny: z.array(z.string()).default(undefined),
  }).default(undefined),
  maxDepth: z.union([z.natural().max(Number.MAX_SAFE_INTEGER), z.const('provider-managed')]).default(3),
  // Optional list of `@preset:` references surfaced in the tool schema, so the
  // model knows which presets exist on THIS deployment. Omit to stay generic.
  presetHints: z.array(z.string()).default(undefined),
})

/** Validate a per-call cwd override: absolute and an accessible directory. */
function assertCwd(cwd) {
  if (!isAbsolute(cwd)) throw new Error(`dsh-subagent-cwd: cwd must be an absolute path: ${cwd}`)
  let stat
  try {
    stat = statSync(cwd)
  } catch (error) {
    throw new Error(`dsh-subagent-cwd: cwd is not an accessible directory: ${cwd} (${String(error)})`)
  }
  if (!stat.isDirectory()) throw new Error(`dsh-subagent-cwd: cwd is not a directory: ${cwd}`)
  return cwd
}

/**
 * Resolve a per-call persona argument. A plain string is used as-is; a
 * `@preset:<id>` value loads the named agent preset's persona text from its
 * composition file (`<dshHome>/.agent-presets/<id>/agent.cordis.yml`), so the
 * caller can reference a preset by name instead of inlining its full text.
 * `id` may be the preset's directory id or its display name (preset.yml
 * `name`).
 */
async function resolvePersona(persona) {
  if (typeof persona !== 'string' || !persona.startsWith('@preset:')) return persona
  const id = persona.slice('@preset:'.length).trim()
  if (id.length === 0) throw new Error('dsh-subagent-cwd: empty preset id after `@preset:`')
  const presetsRoot = dshHomePath('.agent-presets')
  let file = join(presetsRoot, id, 'agent.cordis.yml')
  try {
    await readFile(file, 'utf8')
  } catch {
    file = await resolvePresetByDisplayName(presetsRoot, id)
  }
  let raw
  try {
    raw = await readFile(file, 'utf8')
  } catch (error) {
    throw new Error(`dsh-subagent-cwd: cannot read agent preset "${id}" (${file}): ${String(error)}`)
  }
  const doc = parseYaml(raw)
  const entry = Array.isArray(doc)
    ? doc.find((row) => row !== null && typeof row === 'object' && row.id === 'persona')
    : undefined
  const text = entry !== undefined && entry.config !== undefined && typeof entry.config.text === 'string'
    ? entry.config.text
    : undefined
  if (text === undefined) {
    throw new Error(`dsh-subagent-cwd: agent preset "${id}" has no persona text (no \`id: persona\` entry with a string config.text)`)
  }
  return text
}

/** Map a preset display name (preset.yml `name`) to its composition file path. */
async function resolvePresetByDisplayName(presetsRoot, displayName) {
  let dirs
  try {
    dirs = await readdir(presetsRoot, { withFileTypes: true })
  } catch (error) {
    throw new Error(`dsh-subagent-cwd: cannot list agent presets (${presetsRoot}): ${String(error)}`)
  }
  for (const dir of dirs) {
    if (!dir.isDirectory()) continue
    const metaFile = join(presetsRoot, dir.name, 'preset.yml')
    let metaRaw
    try {
      metaRaw = await readFile(metaFile, 'utf8')
    } catch {
      continue
    }
    const meta = parseYaml(metaRaw)
    if (meta !== null && typeof meta === 'object' && meta.name === displayName) {
      return join(presetsRoot, dir.name, 'agent.cordis.yml')
    }
  }
  throw new Error(`dsh-subagent-cwd: agent preset "${displayName}" not found under ${presetsRoot} (checked directory id and preset.yml display name)`)
}

/**
 * Resolve a per-call preset argument into a preset DIRECTORY ID (the id
 * `dsh-agent-presets.recompose()` expects). Accepts a bare directory id
 * (`anchored-standard`), an `@preset:` reference (`@preset:anchored-standard`),
 * or a display name from the preset's `preset.yml` (`Anchored Standard
 * (experimental)`).
 * @param preset - the raw per-call preset argument, if any.
 * @returns the preset directory id.
 * @throws when the argument is not a string or no preset matches.
 */
async function resolvePresetId(preset) {
  if (typeof preset !== 'string' || preset.length === 0) {
    throw new Error('dsh-subagent-cwd: preset must be a non-empty string')
  }
  const id = preset.startsWith('@preset:') ? preset.slice('@preset:'.length).trim() : preset.trim()
  if (id.length === 0) throw new Error('dsh-subagent-cwd: empty preset id after `@preset:`')
  const presetsRoot = dshHomePath('.agent-presets')
  // Directory id wins (cheap, no display-name scan).
  try {
    await readFile(join(presetsRoot, id, 'agent.cordis.yml'), 'utf8')
    return id
  } catch {
    // Fall through to display-name resolution.
  }
  return await resolvePresetIdByDisplayName(presetsRoot, id)
}

/** Map a preset display name (preset.yml `name`) to its directory id. */
async function resolvePresetIdByDisplayName(presetsRoot, displayName) {
  let dirs
  try {
    dirs = await readdir(presetsRoot, { withFileTypes: true })
  } catch (error) {
    throw new Error(`dsh-subagent-cwd: cannot list agent presets (${presetsRoot}): ${String(error)}`)
  }
  for (const dir of dirs) {
    if (!dir.isDirectory()) continue
    const metaFile = join(presetsRoot, dir.name, 'preset.yml')
    let metaRaw
    try {
      metaRaw = await readFile(metaFile, 'utf8')
    } catch {
      continue
    }
    const meta = parseYaml(metaRaw)
    if (meta !== null && typeof meta === 'object' && meta.name === displayName) {
      return dir.name
    }
  }
  throw new Error(`dsh-subagent-cwd: agent preset "${displayName}" not found under ${presetsRoot} (checked directory id and preset.yml display name)`)
}

/** Resolve a per-call model argument into an explicit provider/model pair. */
function resolveModelRoute(model) {
  if (typeof model !== 'string') return { provider: undefined, model: undefined }
  const slash = model.indexOf('/')
  if (slash === -1) return { provider: undefined, model }
  return { provider: model.slice(0, slash), model: model.slice(slash + 1) }
}

/** Render text blocks from the canonical JSON block array without trusting arbitrary values. */
function outputValueText(values) {
  return values
    .filter((value) =>
      typeof value === 'object' && value !== null && !Array.isArray(value)
      && value.type === 'text' && typeof value.text === 'string')
    .map((value) => value.text)
    .join('')
}

/** Settle pending startup without rejecting the task producer contract. */
async function settleStart(start, signal) {
  try {
    return await settleRun(await start)
  } catch (error) {
    return signal.aborted
      ? { status: 'killed' }
      : { status: 'failed', detail: String(error) }
  }
}

/** A non-`completed` stop reason means the child did not finish cleanly. */
function stopReasonError(result) {
  switch (result.stopReason) {
    case 'completed':
      return undefined
    case 'aborted':
      return 'subagent run was cancelled'
    case 'error':
      return 'subagent run failed'
    case 'max-tokens':
      return 'subagent run hit its token limit before finishing'
    case 'refusal':
      return 'subagent declined the task'
    default:
      return `subagent run ended abnormally (${String(result.stopReason)})`
  }
}

/** Append the child's preserved partial answer to a stop-reason error. */
function withPartialText(error, output) {
  const text = output
    .filter((block) => block.type === 'text')
    .map((block) => block.text)
    .join('')
  return text.length === 0 ? error : `${error}\nPartial output before the run ended:\n${text}`
}

/** Collect and release one foreground run without letting disposal replace an independent result failure. */
async function settleForegroundRun(run) {
  const [execution] = await Promise.allSettled([
    run.result.then((result) => {
      const error = stopReasonError(result)
      if (error !== undefined) {
        throw new Error(withPartialText(error, result.output))
      }
      return {
        kind: 'foreground',
        runId: run.id,
        output: result.output,
      }
    }),
  ])
  const [disposal] = await Promise.allSettled([Promise.resolve().then(() => run.dispose())])
  if (execution.status === 'rejected') {
    if (disposal.status === 'rejected') {
      throw new AggregateError(
        [execution.reason, disposal.reason],
        `subagent run failed: ${String(execution.reason)}; dispose failed: ${String(disposal.reason)}`,
      )
    }
    throw execution.reason
  }
  if (disposal.status === 'rejected') throw disposal.reason
  return execution.value
}

/** Model-facing wording from the provider's conversation-history descriptor. */
function providerWording(inheritsConversation) {
  if (inheritsConversation) {
    return {
      description:
        'Delegate a task to a subagent that inherits this conversation: a child agent seeded with all '
        + 'completed turns so far (it does not see the current in-flight turn). Use this when the subtask '
        + 'builds on this conversation\'s context — a follow-up analysis, '
        + 'a review, a continuation — without consuming this conversation\'s context for the work itself. '
        + 'You receive its result, not its intermediate steps.',
      promptDescription:
        'The task for the subagent. It already sees this conversation\'s completed turns, so build on them '
        + 'freely and state only what is new.',
    }
  }
  return {
    description:
      'Delegate a self-contained task to a subagent (a separate agent that works in its own context) '
      + 'to offload focused, independent work — research, a scoped '
      + 'implementation, an analysis — so it does not consume this conversation\'s context. The subagent '
      + 'returns its result, not its intermediate steps. Give it a '
      + 'complete, standalone prompt: it does not see this conversation.',
    promptDescription:
      'The complete, self-contained task for the subagent. It does not share this '
      + 'conversation\'s context, so include everything it needs.',
  }
}

/** Resolve the model's optional scheduling request into one execution route. */
function resolveDelegationRun(request, options) {
  if (!options.backgroundEnabled) {
    if (request.run_in_background === true) {
      throw new Error('run_in_background is disabled for this tool instance (enableRunInBackground: false)')
    }
    return { runInBackground: false }
  }
  return {
    runInBackground: request.run_in_background ?? options.continuable,
  }
}

export function apply(ctx, config) {
  if (config.maxDepth !== 'provider-managed') assertSubagentMaxDepth(config.maxDepth)
  if (config.toolFilter !== undefined && config.toolFilter.allow === undefined && config.toolFilter.deny === undefined) {
    throw new Error('dsh-subagent-cwd: `toolFilter` is configured but names neither `allow` nor `deny` — remove the key or fill the filter')
  }
  const backgroundEnabled = config.enableRunInBackground !== false
  const continuable = (config.backgroundMode ?? 'one-shot') === 'continuable'
  const toolName = config.toolName ?? 'subagent'

  let disposeTool
  const mount = (provider) => {
    if (typeof config.maxDepth === 'number' && !provider.capabilities.depthLimit) {
      throw new Error(
        `dsh-subagent-cwd: provider "${provider.name}" cannot enforce maxDepth (no depthLimit capability) — `
        + 'set maxDepth: \'provider-managed\' to leave the recursion budget to the provider',
      )
    }
    const wording = providerWording(provider.inheritsParentContext)
    if (continuable && provider.prepareContinuable === undefined) {
      throw new Error(
        `dsh-subagent-cwd: provider "${provider.name}" does not support \`backgroundMode: continuable\``,
      )
    }
    disposeTool = ctx.tools.register(defineTool({
      name: toolName,
      description: wording.description + (backgroundEnabled
        ? continuable
          ? ' This tool runs in the background by default, immediately returns a durable subagent id, and keeps the child conversation available for later turns. When that run settles, the runtime sends the parent a notice containing its outcome and any final assistant message; `send_message` starts a later turn in the same child conversation. Set `run_in_background: false` only when your next action depends on receiving the result.'
          : ' This call waits for the result by default. Set `run_in_background: true` to return a job id; collect with `job_output` and stop with `job_kill`.'
        : ' This call waits for the subagent and returns its result.'),
      parameters: {
        description: {
          type: 'string',
          required: true,
          description: 'A short (3-5 word) description of the delegated task, for display.',
        },
        prompt: {
          type: 'string',
          required: true,
          description: wording.promptDescription,
        },
        ...backgroundEnabled ? {
          run_in_background: {
            type: 'boolean',
            description: continuable
              ? 'Whether to run in the background and return a durable subagent id immediately. Defaults to true. Set false to wait for the result when your next action depends on it.'
              : 'Whether to run as a background job and return its id. Defaults to false; collect with job_output or stop with job_kill.',
          },
        } : {},
        // ── per-call overrides (same as dsh-subagent-tools) ────────────────
        model: {
          type: 'string',
          description: 'Optional per-call LLM model override for this child. Accepts a bare model id (`k3`) or a `provider/model` composite (`kimi-code/k3`) that also switches the LLM provider. Overrides the instance config and the parent route.',
        },
        provider: {
          type: 'string',
          description: 'Optional per-call subagent provider override (defaults to the configured provider, e.g. spawn/fork).',
        },
        persona: {
          type: 'string',
          description: 'Optional per-call persona text that shadows the deployment/preset persona for this child, or an `@preset:<id>` reference (display name or directory id) to load a saved agent preset\'s persona.'
            + (config.presetHints !== undefined && config.presetHints.length > 0
              ? ` Available presets on this deployment: ${config.presetHints.map((p) => p.startsWith('@preset:') ? p : `@preset:${p}`).join(', ')}.`
              : ''),
        },
        toolFilter: {
          type: 'object',
          additionalProperties: false,
          properties: {
            allow: { type: 'array', items: { type: 'string' } },
            deny: { type: 'array', items: { type: 'string' } },
          },
          description: 'Optional per-call tool allow/deny filter applied to this child (overrides the instance config).',
        },
        // ── cwd (this package only; requires the in-process provider patches) ──────
        cwd: {
          type: 'string',
          description: 'Optional absolute working directory for this child (defaults to the parent session cwd). Pointing it at a directory without workspace instructions (e.g. AGENTS.md) keeps project engineering rules out of the child\'s context. Requires the in-process provider patches from patches/ (install.ps1 / install.sh).',
        },
        // ── preset (this package only; requires the in-process provider patches) ────
        preset: {
          type: 'string',
          description: 'Optional per-call agent preset override for this child: recomposes the child onto a DIFFERENT preset\'s composition (tools, prompt sections, plugins) instead of inheriting the parent session\'s preset. Accepts a preset directory id (`anchored-standard`), an `@preset:<id>` reference, or a display name from the preset\'s preset.yml. Only meaningful for a fresh child before it has produced anything; requires the in-process provider patches from patches/ (install.ps1 / install.sh).',
        },
      },
      output: {
        schema: {
          oneOf: [
            {
              type: 'object',
              additionalProperties: false,
              properties: {
                kind: { type: 'string', required: true, const: 'background' },
                jobId: { type: 'string', required: true },
              },
            },
            {
              type: 'object',
              additionalProperties: false,
              properties: {
                kind: { type: 'string', required: true, const: 'continuable' },
                subagentId: { type: 'string', required: true },
              },
            },
            {
              type: 'object',
              additionalProperties: false,
              properties: {
                kind: { type: 'string', required: true, const: 'foreground' },
                runId: { type: 'string', required: true },
                output: { type: 'array', required: true, items: { type: 'json' } },
              },
            },
          ],
        },
        render: (_args, value) => [{
          type: 'text',
          text: value.kind === 'background'
            ? `started background subagent task ${value.jobId}`
            : value.kind === 'continuable'
              ? `started subagent ${value.subagentId}`
              : outputValueText(value.output),
        }],
      },
      isConcurrencySafe: () => true,
      async execute(args, exec) {
        const parent = exec.agent
        if (!parent) {
          throw new Error('subagent tool requires a calling agent (exec.agent was undefined)')
        }

        // Per-call overrides (args) take precedence over instance config.
        // NOTE: `provider` selects the SUBAGENT backend (spawn/fork/...) and is
        // passed to ctx.subagents.start/startContinuable — it is NOT an LLM
        // provider. LLM provider routing is covered by the composite `model`
        // id (`kimi-code/k3`) or the instance `agentOptions.provider`.
        const persona = await resolvePersona(args.persona ?? config.persona)
        const toolFilter = args.toolFilter ?? config.toolFilter
        const route = resolveModelRoute(args.model)
        const llmProvider = route.provider
        const llmModel = route.model
        const subagentProvider = args.provider ?? config.provider
        const presetId = args.preset !== undefined ? await resolvePresetId(args.preset) : undefined

        const maxDepth = typeof config.maxDepth === 'number' ? config.maxDepth : undefined
        const request = {
          label: args.description,
          prompt: [{ type: 'text', text: args.prompt }],
          parent,
          ...(config.agentOptions !== undefined || llmProvider !== undefined || llmModel !== undefined)
            ? { agentOptions: {
                ...(config.agentOptions !== undefined ? config.agentOptions : {}),
                ...(llmProvider !== undefined ? { provider: llmProvider } : {}),
                ...(llmModel !== undefined ? { model: llmModel } : {}),
              } }
            : {},
          ...persona !== undefined ? { persona } : {},
          ...toolFilter !== undefined ? { toolFilter } : {},
          ...args.cwd !== undefined ? { cwd: assertCwd(args.cwd) } : {},
          ...presetId !== undefined ? { preset: presetId } : {},
          ...maxDepth !== undefined ? { maxDepth } : {},
        }

        const runSpec = resolveDelegationRun(args, { backgroundEnabled, continuable })
        if (runSpec.runInBackground) {
          if (continuable) {
            const started = await ctx.subagents.startContinuable({
              provider: subagentProvider,
              label: args.description,
              request,
              signal: exec.signal,
            })
            return { kind: 'continuable', subagentId: started.childId }
          }
          const jobs = ctx.get('jobs')
          if (jobs === undefined) {
            throw new Error('background jobs unavailable: load @deepseek-ai/dsh-jobs and @deepseek-ai/dsh-tool-jobs')
          }
          const id = jobs.start({
            kind: 'subagent',
            label: args.description,
            owner: parent,
            run: () => {
              const controller = new AbortController()
              const start = ctx.subagents.start(subagentProvider, { ...request, signal: controller.signal })
              return {
                cancel: (reason) => {
                  controller.abort(reason ?? 'background subagent task killed')
                },
                done: settleStart(start, controller.signal),
              }
            },
          })
          return { kind: 'background', jobId: id }
        }

        const run = await ctx.subagents.start(subagentProvider, {
          ...request,
          signal: exec.signal,
        })
        return settleForegroundRun(run)
      },
    }))
  }

  ctx.on('subagent/provider-added', (provider) => {
    if (provider.name === config.provider && disposeTool === undefined) mount(provider)
  })
  ctx.on('subagent/provider-removed', (name) => {
    if (name !== config.provider || disposeTool === undefined) return
    disposeTool()
    disposeTool = undefined
  })
  const present = ctx.subagents.getProvider(config.provider)
  if (present !== undefined) {
    mount(present)
  } else {
    ctx.logger.info(`subagent provider "${config.provider}" not registered yet; the "${toolName}" tool will register when it appears`)
  }
  if (backgroundEnabled && continuable) {
    ctx.systemPrompt.section({
      name: `tool:${toolName}`,
      order: SUBAGENT_SECTION_ORDER,
      text: (context) => disposeTool === undefined || ctx.tools.get(toolName, context.scope) === undefined
        ? ''
        : `Use ${toolName} in the background by default. Start independent delegations together in one assistant message and continue useful work while they run. Set \`run_in_background: false\` only when your next action depends on that subagent's result. When a background run settles, the runtime sends you a notice containing its outcome and any final assistant message.`,
    })
  }
}
