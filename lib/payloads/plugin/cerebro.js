// cerebro session-binding plugin for opencode.
//
// Replaces cerebro's old Claude Code `UserPromptSubmit` hook. It does two jobs,
// both keyed off the CEREBRO_SESSION_DIR env var that cerebro exports into every
// interactive opencode process it launches:
//
//   1. Record the opencode-assigned session id into the cerebro session's
//      metadata.json (`opencode_session_id`), so `cerebro --resume <id>` can
//      reopen the same opencode conversation.
//   2. Mirror each user prompt into the session transcript.jsonl as a
//      {kind:"user"} line, so another cerebro session observing this one can
//      narrate the orchestrator track alongside its paired children.
//
// Best-effort and defensive: any failure is swallowed so the plugin can never
// disrupt the orchestrator. For non-cerebro opencode sessions (no
// CEREBRO_SESSION_DIR) it is inert.
import fs from "node:fs"
import path from "node:path"

export const CerebroSessionBinding = async () => {
  const dir = process.env.CEREBRO_SESSION_DIR || ""
  if (!dir) return {}

  const metaPath = path.join(dir, "metadata.json")
  const transcriptPath = path.join(dir, "transcript.jsonl")
  const seenParts = new Set()
  let recordedSid = ""

  const nowIso = () => new Date().toISOString().replace(/\.\d+Z$/, "Z")

  const readMeta = () => {
    try {
      return JSON.parse(fs.readFileSync(metaPath, "utf8"))
    } catch {
      return {}
    }
  }

  const writeMeta = (m) => {
    try {
      const tmp = `${metaPath}.tmp.${process.pid}`
      fs.writeFileSync(tmp, JSON.stringify(m, null, 2) + "\n")
      fs.renameSync(tmp, metaPath)
    } catch {}
  }

  const recordSid = (sid) => {
    if (!sid || recordedSid === sid) return
    recordedSid = sid
    const m = readMeta()
    if (m.opencode_session_id !== sid) m.opencode_session_id = sid
    m.last_touched = nowIso()
    writeMeta(m)
  }

  const touch = () => {
    const m = readMeta()
    m.last_touched = nowIso()
    writeMeta(m)
  }

  const appendUser = (text) => {
    if (!text) return
    try {
      fs.appendFileSync(
        transcriptPath,
        JSON.stringify({ kind: "user", ts: nowIso(), text }) + "\n",
      )
    } catch {}
  }

  // Pull a session id out of whatever event shape opencode hands us. opencode's
  // bus events nest the id differently per event type, so probe the known
  // locations and take the first that resolves.
  const sidOf = (props) => {
    if (!props || typeof props !== "object") return ""
    return (
      props.sessionID ||
      (props.info && (props.info.sessionID || props.info.id)) ||
      (props.part && props.part.sessionID) ||
      (props.message && props.message.sessionID) ||
      ""
    )
  }

  const roleOf = (obj) => (obj && (obj.role || (obj.info && obj.info.role))) || ""

  return {
    event: async ({ event }) => {
      if (!event || typeof event !== "object") return
      const props = event.properties || {}

      const sid = sidOf(props)
      if (sid) recordSid(sid)

      // Mirror the user's submitted prompt into the transcript. A user message
      // surfaces either part-wise (message.part.updated) or as a whole message
      // (message.updated); handle both, de-duplicating by part id.
      if (event.type === "message.part.updated") {
        const part = props.part || {}
        const role = part.role || roleOf(props.message) || roleOf(props.info)
        if (part.type === "text" && role === "user" && part.id && !seenParts.has(part.id)) {
          seenParts.add(part.id)
          appendUser(part.text || "")
        }
      } else if (event.type === "message.updated") {
        const info = props.info || props.message || {}
        if (roleOf(info) === "user" && Array.isArray(info.parts)) {
          for (const p of info.parts) {
            if (p && p.type === "text" && p.id && !seenParts.has(p.id)) {
              seenParts.add(p.id)
              appendUser(p.text || "")
            }
          }
        }
      } else if (event.type === "session.idle") {
        touch()
      }
    },
  }
}
