# Architecture

```
JarvisOrb.app (Swift/AppKit, LSUIElement: no Dock icon)
 ├─ DesktopWindow     borderless window at desktop-icon level + 1, on every Space, not in ⌘-Tab;
 │                    takes the mouse only inside the orb's circle
 ├─ OrbWebView        WKWebView (transparent) running orb-web/index.html; state and cursor go in
 │                    through window.orb.setState(...) / window.orb.setCursor(x, y)
 ├─ CursorTracker     global mouse position -> normalized offset for the ribbons
 ├─ TranscriptBar     input field that takes typing or Wispr Flow's pasted dictation
 ├─ ChatPanel         scrollback, streaming replies, Approve/Deny cards
 ├─ BriefingWindow    the daily briefing card (orb-web/briefing.html)
 ├─ SpeechOutput      ElevenLabs -> Kokoro -> Mac voice, text revealed as it is spoken
 ├─ GlobalHotKey      ⌃⌥Space
 └─ AgentBridge       runs agent/index.js with Node, JSON lines over stdin/stdout

agent/ (Node, no npm dependencies)
 ├─ index.js          runs `claude -p` (stream-json) per chat, keeps one warm process,
 │                    resumes the chat's session, streams events back
 ├─ approval-hook.js  Claude Code hook (PermissionRequest, PreToolUse); asks the helper over a
 │                    Unix socket and waits for the user's Approve/Deny
 ├─ memory.js         profile + recent requests in ~/Library/Application Support/JarvisOrb
 ├─ mac.js            quick actions (open, volume, timers, Spotlight, Do Not Disturb)
 └─ kokoro_server.py  local Kokoro text-to-speech server, started on demand

app/CalendarTool      `jarvis-calendar`: EventKit events and reminders (read, add with a card)
app/MessagesTool      `jarvis-messages`: recent one-on-one iMessages, read-only (Full Disk Access)
```

## Orb states

`idle`, `hover`, `listening`, `thinking`, `awaitingApproval`, `speaking`, `error`, plus an
`overdue` mood that warms the colours while a reminder is overdue.

## Protocol (JSON lines)

App -> helper:

- `{"type":"task","id","text","model","chat"}` a request
- `{"type":"prepare","model","chat"}` warm a Claude process before the user finishes speaking
- `{"type":"briefing","id",...}` build the daily briefing
- `{"type":"approval","approvalId","allow"}` the answer to a card
- `{"type":"cancel","id"}` stop the current request

Helper -> app:

- `ready`, `state`, `text` (reply delta), `tool` (tool started), `approvalRequest`
  (`approvalId`, `title`, `detail`), `briefing`, `timerFired`, `done`, `error`

## Safety model

- Claude Code runs with `--strict-mcp-config` (no connectors except Claude in Chrome when a
  request sounds like a browser task) and the approval hook registered through `--settings`.
- Anything Claude Code would ask permission for, and any browser action that can change a page,
  goes to the hook. The hook asks the app, which shows a card; no answer means denied.
- The helper strips `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` so Claude Code uses the
  claude.ai login.
- The activity log records tool names, approvals and outcomes, never request or reply text.

## Rendering

Raw WebGL2, no libraries. The frame loop follows the display's vsync: 60 fps while active,
lower when idle or on battery, paused when a window covers the orb.
