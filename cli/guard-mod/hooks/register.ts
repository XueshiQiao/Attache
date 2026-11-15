// Attaché privacy guard for Claude Code.
//
// A thin shim: every decision about what is private is attache-cli's
// (`attache-cli guard …`), so the rules have one implementation, shared with
// the Codex and agy hooks and with the app's "Try it" tab. This module only
// decides where to call it.
//
// Where, and why each place (measured on Claude Code 2.1.325, 2026-11-15):
//
//   prompt.submit   the person's message, before the model or the
//                   transcript sees it.
//   session.append  every row as it is stored and sent: replies, tool
//                   results, reminders. It cannot reach a tool result's
//                   structured record (`toolUseResult` in the transcript),
//                   which kept a raw value in the first experiment.
//   tool.call       so the result is masked here too, which is what the
//                   transcript records as that record; and placeholders in
//                   the arguments get their real values back. The tool_use
//                   row keeps the arguments as the model wrote them.
//
// It fails closed. A hook that throws or runs out of time is skipped by
// default and its content passes unchanged; every hook here has a `.catch`
// that withholds the content instead.

import type { Register } from 'claude-code'

const CLI = '"${ATTACHE_CLI:-$HOME/.local/bin/attache-cli}"'
const PLACEHOLDER = /⟦[a-z0-9]{1,12}:[0-9a-f]{6,20}⟧/
const WITHHELD = 'Attaché privacy guard could not check this, so it was withheld.'

// Tools whose arguments get real values back. Web tools are left out on
// purpose: a placeholder put back there would send the value off this host.
const RESTORE = new Set(['Bash', 'Write', 'Edit', 'MultiEdit', 'NotebookEdit', 'Read', 'Grep', 'Glob', 'LS'])

async function guard($: any, args: string[], input: unknown): Promise<any> {
  const r = await $.process.run(['/bin/sh', '-c', `exec ${CLI} guard "$@"`, 'attache-guard', ...args], {
    stdin: JSON.stringify(input),
    timeoutMs: 8000,
  })
  if (r.exitCode !== 0) throw new Error(`attache-cli guard ${args[0]} exited ${r.exitCode}: ${r.stderr.slice(0, 300)}`)
  return JSON.parse(r.stdout)
}

async function mask($: any, texts: string[], where: string): Promise<{ texts: string[]; blocked: boolean }> {
  if (texts.length === 0) return { texts, blocked: false }
  const r = await guard($, ['mask', '--json', '--agent', 'claude', '--where', where], { texts })
  if (!Array.isArray(r.texts) || r.texts.length !== texts.length) throw new Error('attache-cli guard mask: wrong answer')
  return r
}

function strings(x: unknown, out: string[] = []): string[] {
  if (typeof x === 'string') out.push(x)
  else if (Array.isArray(x)) x.forEach(v => strings(v, out))
  else if (x && typeof x === 'object') Object.values(x).forEach(v => strings(v, out))
  return out
}

function refill(x: unknown, next: () => string): unknown {
  if (typeof x === 'string') return next()
  if (Array.isArray(x)) return x.map(v => refill(v, next))
  if (x && typeof x === 'object') return Object.fromEntries(Object.entries(x).map(([k, v]) => [k, refill(v, next)]))
  return x
}

function withStrings<T>(x: T, texts: string[]): T {
  let i = 0
  // `mask` checked the lengths match; '' never stands for a real text.
  return refill(x, () => texts[i++] ?? '') as T
}

const sameList = (a: string[], b: string[]) => a.length === b.length && a.every((s, i) => s === b[i])

function shQuote(s: string): string {
  return `'${s.split("'").join(`'\\''`)}'`
}

// The texts of a row a hook may rewrite: text blocks and tool results.
function rowTexts(content: any[]): string[] {
  const out: string[] = []
  for (const b of content) {
    if (b.type === 'text') out.push(b.text)
    else if (b.type === 'tool_result') {
      if (typeof b.content === 'string') out.push(b.content)
      else if (Array.isArray(b.content)) for (const c of b.content) if (c.type === 'text') out.push(c.text)
    }
  }
  return out
}

function rowWith(content: any[], texts: string[]): any[] {
  let i = 0
  return content.map(b => {
    if (b.type === 'text') return { ...b, text: texts[i++] }
    if (b.type === 'tool_result') {
      if (typeof b.content === 'string') return { ...b, content: texts[i++] }
      if (Array.isArray(b.content))
        return { ...b, content: b.content.map((c: any) => (c.type === 'text' ? { ...c, text: texts[i++] } : c)) }
    }
    return b
  })
}

function rowWithheld(content: any[], why: string): any[] {
  return rowWith(content, rowTexts(content).map(() => why))
}

export const register: Register = on => {
  on('prompt.submit', async ($, e, next) => {
    if (e.command) return next(e)
    const context = e.context ?? []
    const r = await mask($, [e.text, ...context], 'prompt')
    if (r.blocked) return { drop: 'Attaché privacy guard: this message matched a block rule, so it was not sent.' }
    const [first, ...rest] = r.texts
    const text = first ?? ''
    return next(e.context ? { ...e, text, context: rest } : { ...e, text })
  }).catch(($, e, next) =>
    next.called
      ? next(e)
      : { drop: 'Attaché privacy guard could not check this message, so it was not sent. Pause the guard in Attaché to send it unchecked.' },
  )

  on('session.append', async ($, e, next) => {
    const raw: any = e.message.content
    // The types say blocks; a bare string is handled anyway rather than
    // let through.
    const content: any[] = typeof raw === 'string' ? [{ type: 'text', text: raw }] : raw
    const texts = rowTexts(content)
    if (texts.length === 0) return next(e)
    const r = await mask($, texts, e.door === 'response' ? 'reply' : e.door)
    if (r.blocked) {
      const why = 'Attaché privacy guard withheld this: it matched a block rule.'
      return next({ ...e, message: { ...e.message, content: rowWithheld(content, why) } } as any)
    }
    if (sameList(texts, r.texts)) return next(e)
    return next({ ...e, message: { ...e.message, content: rowWith(content, r.texts) } } as any)
  }).catch(($, e, next) =>
    next.called ? next(e) : next({ ...e, message: { ...e.message, content: rowWithheld(e.message.content as any[], WITHHELD) } } as any),
  )

  on('tool.call', async ($, e, next) => {
    const { tool, tool_use_id, agentId, requestMeta, consent, ...args } = e as any
    let call: any = e
    if (RESTORE.has(tool) && PLACEHOLDER.test(JSON.stringify(args))) {
      if (tool === 'Bash' && typeof args.command === 'string') {
        // Put back in the session's own shell, so a `cd` stays and the real
        // value is never in the command's text.
        call = {
          ...e,
          command: `__attache_guard="$(${CLI} guard restore --agent claude --sh ${shQuote(args.command)})" && eval "$__attache_guard"`,
        }
      } else {
        const texts = strings(args)
        const r = await guard($, ['restore', '--json', '--agent', 'claude', '--where', `tool:${tool}`], { texts })
        call = { ...e, ...withStrings(args, r.texts) }
      }
    }
    const ran: any = await next(call)
    // A refusal can quote the arguments, which now hold real values.
    if (ran.deny !== undefined) {
      const d = await mask($, [String(ran.deny)], `tool:${tool}`)
      return { deny: d.blocked ? 'Attaché privacy guard withheld this result.' : d.texts[0] }
    }
    const texts = strings(ran.result)
    const context: string[] = ran.context ? [...ran.context] : []
    if (texts.length === 0 && context.length === 0) return ran
    const r = await mask($, [...texts, ...context], `tool:${tool}`)
    if (r.blocked) return { deny: 'Attaché privacy guard withheld this result: it matched a block rule.' }
    if (sameList([...texts, ...context], r.texts)) return ran
    const result = withStrings(ran.result, r.texts.slice(0, texts.length))
    const ctx = r.texts.slice(texts.length)
    return ctx.length ? { result, context: ctx } : { result }
  }).catch(() => ({ deny: WITHHELD }))
}
