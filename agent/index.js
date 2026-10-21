#!/usr/bin/env node
// Jarvis Orb agent helper.
//
// Runs the owner's installed Claude Code headless (`claude -p`, on their own Claude login) and
// speaks JSON lines with the Swift app over stdio. One task runs at a time; tasks that share a
// chatId continue the same Claude Code session, so Jarvis keeps the conversation's context.
//
// App -> helper:  {"type":"prepare","chatId","model"}  {"type":"task","id","chatId","text","model"}
//                 {"type":"briefing","id"} -> {"type":"briefing","id","events","reminders","summary","sources"}
//                 {"type":"cancel","id"}
//                 {"type":"approval","approvalId","allow"}
// Helper -> app:  {"type":"ready"}  {"type":"state","id","state"}  {"type":"text","id","delta"}
//                 {"type":"tool","id","name"}  {"type":"done","id","cancelled"?}
//                 {"type":"error","id","message"}
//                 {"type":"approvalRequest","id","approvalId","title","detail"}  {"type":"timerFired","label"}
//
// Every tool call and approval is logged to ~/Library/Logs/JarvisOrb/activity-<date>.log (never
// request text). Separately, what Jarvis remembers and the owner's recent requests live in
// workspace/memory/ and are loaded into each session (see systemPrompt()).
//
// Safety: reading, searching and looking at web pages run freely. Anything Claude Code wants
// permission for, and any browser action that can change a page, goes through approval-hook.js,
// which waits for the owner's Approve/Deny card. No answer means deny. Nothing here logs the
// task text or the reply.

import { execFile, spawn } from 'node:child_process';
import { appendFile, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import net from 'node:net';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

const CLAUDE = process.env.JARVIS_CLAUDE_PATH || join(homedir(), '.local/bin/claude');
const SUPPORT = join(homedir(), 'Library/Application Support/JarvisOrb');
const WORKDIR = process.env.JARVIS_WORKDIR || join(SUPPORT, 'workspace');
const SOCKET = join(SUPPORT, `approve-${process.pid}.sock`);
const HERE = dirname(fileURLToPath(import.meta.url));
const HOOK = join(HERE, 'approval-hook.js');
// Bundled next to this folder in the app (Contents/Resources/bin); absent when run from the repo.
const CALENDAR_TOOL = join(HERE, '..', 'bin', 'jarvis-calendar');
const hasCalendarTool = existsSync(CALENDAR_TOOL);
const MESSAGES_TOOL = join(HERE, '..', 'bin', 'jarvis-messages');
const hasMessagesTool = existsSync(MESSAGES_TOOL);
const MEMORY_TOOL = join(HERE, 'memory.js');
const MAC_TOOL = join(HERE, 'mac.js');
const MEMORY_DIR = join(WORKDIR, 'memory');
const PROFILE = join(MEMORY_DIR, 'profile.md');
const RECENT = join(MEMORY_DIR, 'recent.md');
const RECENT_KEEP = 200;
const RECENT_IN_PROMPT = 12;
const DEFAULT_MODEL = 'claude-sonnet-5-5';
// Built-in tools; the browser tools come from --chrome. Other MCP servers and connectors are
// left out: they add seconds of startup to every request.
const TOOLS = 'Read,Glob,Grep,WebSearch,WebFetch,Bash';
// The browser tools are 12k of the ~20k prompt tokens every request sends, which makes the first
// request after a quiet spell (cold prompt cache) noticeably slower. So they are loaded only for
// requests that sound like they need the browser, and stay loaded for the rest of that chat.
const BROWSER_WORDS = /\b(e-?mails?|gmail|inbox|mail|draft|reply|replies|chrome|browser|websites?|web ?pages?|tabs?|links?|urls?|log ?in|sign ?in|youtube|amazon|google (docs?|sheets?|drive)|docs\.google)\b|https?:\/\/|\b\w+\.(com|org|net|io|edu|gov|co|ai|app)\b/i;
const browserChats = new Set();
const LOG_DIR = join(homedir(), 'Library/Logs/JarvisOrb');
const CANCEL_GRACE_MS = 3000;
const HOOK_TIMEOUT_S = 300;
// A request that runs this long is stopped (a stuck page or loop shouldn't run all afternoon).
const MAX_TASK_MS = 10 * 60 * 1000;

// The owner's first name (the app passes the Mac account's first name); used in Jarvis's prompt.
const OWNER = (process.env.JARVIS_OWNER || '').trim() || 'the user';

const SYSTEM_PROMPT = [
  `You are Jarvis, a desktop assistant for ${OWNER}, reached through a glowing orb on their Mac. You can act on their computer, and they watch you work.`,
  'Requests usually come from dictation, so they can be informal or contain transcription slips; read them charitably.',
  'Your reply is shown in a small chat panel under the orb and may be read aloud: answer directly and briefly, a few sentences or a short list, in plain text with at most light markdown (bold, bullets). No headings, tables or code blocks unless asked.',
  hasCalendarTool
    ? `Calendar: ${OWNER} uses the macOS Calendar app. Use the fast calendar tool through Bash: \`${CALENDAR_TOOL} list --from today --days 1\` (also --from tomorrow or YYYY-MM-DD, --days N), \`${CALENDAR_TOOL} reminders --days 1\` (their Reminders, overdue first), \`${CALENDAR_TOOL} calendars\`, and \`${CALENDAR_TOOL} add --title "..." --start "YYYY-MM-DD HH:MM" --minutes 60 [--calendar NAME] [--location ...]\`, which also shows the new event in Calendar. Reading runs immediately; adding asks them first. Use AppleScript only for what the tool cannot do (editing or deleting events). Ask which calendar only if it matters and is unclear.`
    : `Calendar: ${OWNER} uses the macOS Calendar app. Use AppleScript through Bash (osascript) to read and create events. After adding or changing an event, bring Calendar to the front and show the event so they can see it. Ask which calendar only if it matters and is unclear.`,
  `Email and websites: ${OWNER} uses Gmail in Chrome, already signed in. Use the browser tools in a visible Chrome tab. Write drafts there; sending is a separate step. The browser tools are only loaded when a request mentions email, Chrome, a website or a link; if you need the browser and do not have it, say so in one sentence and ask them to mention Chrome.`,
  `Every action that sends, deletes, changes, buys or posts something is shown to ${OWNER} as an Approve/Deny card before it runs. Give each such tool call a clear, specific description (what, to whom or where, when), because that text is what they see on the card. If they deny an action, do not retry it or work around it; say what was not done.`,
  'Resolve relative dates ("this Tuesday", "tomorrow") against the current date and say the exact date you used.',
  hasMessagesTool ? `Texts: \`${MESSAGES_TOOL} --hours 36\` shows their recent one-on-one iMessage/SMS conversations (no group chats). Use it when they ask what people texted or asked them. Never quote messages to anyone else.` : '',
  `Quick actions (run without asking): \`${MAC_TOOL} open <app|folder|file|url>\`, \`${MAC_TOOL} volume get|set N|up|down|mute|unmute\`, \`${MAC_TOOL} timer set <90s|20m|1h30m> [label]\` / \`timer list\` / \`timer cancel [id|all]\` (when a timer ends the orb chimes and says its label), \`${MAC_TOOL} search <words> [--names]\` (Spotlight), \`${MAC_TOOL} dnd on|off\`. Prefer these over AppleScript. Screen brightness is not supported.`,
  `Memory: you keep what you know about ${OWNER} with \`${MEMORY_TOOL} add "fact" --section Preferences|Routines|Projects|People|Notes\`, \`${MEMORY_TOOL} forget "words"\` and \`${MEMORY_TOOL} show\`. Save it when they state a preference, routine, ongoing project or person worth knowing, or ask you to remember something; forget when they ask. Do not save passwords, codes or one-off details. Mention briefly when you save something.`,
].join(' ');

// What Jarvis remembers (profile) and what the owner asked recently, appended to the system prompt
// of each new session so Jarvis doesn't start from zero.
function systemPrompt() {
  const read = (file) => { try { return readFileSync(file, 'utf8'); } catch { return ''; } };
  const profile = read(PROFILE).split('\n').filter((l) => l.startsWith('- ') || l.startsWith('## ')).join('\n').slice(0, 6000);
  const recent = read(RECENT).trim().split('\n').filter(Boolean).slice(-RECENT_IN_PROMPT).join('\n');
  let prompt = SYSTEM_PROMPT;
  if (profile.includes('- ')) prompt += `\n\nWhat you remember about ${OWNER}:\n${profile}`;
  if (recent) prompt += `\n\nTheir most recent requests (oldest first), for context:\n${recent}`;
  return prompt;
}

// Recent requests, one line each, kept locally in the workspace (the owner asked Jarvis to
// remember past commands). Trimmed to the last RECENT_KEEP.
function rememberRequest(text) {
  try {
    mkdirSync(MEMORY_DIR, { recursive: true });
    const stamp = new Date().toLocaleString('en-CA', { hour12: false }).slice(0, 17);
    const lines = (existsSync(RECENT) ? readFileSync(RECENT, 'utf8') : '').split('\n').filter(Boolean);
    lines.push(`${stamp} ${text.replace(/\s+/g, ' ').trim().slice(0, 300)}`);
    writeFileSync(RECENT, lines.slice(-RECENT_KEEP).join('\n') + '\n');
  } catch {}
}

mkdirSync(WORKDIR, { recursive: true });
mkdirSync(LOG_DIR, { recursive: true });

// Activity log, one JSON line per event, one file per day: every tool Jarvis uses and every
// approval with its answer. Card-style summaries only; never the request text or the reply.
function audit(entry) {
  const now = new Date();
  const day = now.toLocaleDateString('en-CA'); // YYYY-MM-DD, local time
  const line = JSON.stringify({ time: now.toISOString(), ...entry }) + '\n';
  appendFile(join(LOG_DIR, `activity-${day}.log`), line, () => {});
}

function send(message) {
  process.stdout.write(JSON.stringify(message) + '\n');
}

// Children get the owner's login, never an API key that happens to be in the environment.
// Variables from an enclosing Claude Code session (when the helper is run by hand from one)
// are dropped too: some switch the child to bare mode, which ignores the Keychain login.
function childEnv() {
  const env = { ...process.env };
  for (const key of Object.keys(env)) {
    if (key === 'CLAUDECODE' || key.startsWith('CLAUDE_CODE_') || key.startsWith('CLAUDE_AGENT_SDK_')) delete env[key];
  }
  delete env.ANTHROPIC_API_KEY;
  delete env.ANTHROPIC_AUTH_TOKEN;
  delete env.ANTHROPIC_BASE_URL;
  const extra = [join(homedir(), '.local/bin'), '/opt/homebrew/bin', '/usr/local/bin'];
  env.PATH = [...extra, env.PATH || '/usr/bin:/bin'].join(':');
  // mac.js reaches the helper here for timers.
  env.JARVIS_SOCKET = SOCKET;
  return env;
}

function quote(arg) {
  return `'${arg.replace(/'/g, `'\\''`)}'`;
}

function hookSettings() {
  const command = `${quote(process.execPath)} ${quote(HOOK)} ${quote(SOCKET)}`;
  const handler = [{ matcher: '*', hooks: [{ type: 'command', command, timeout: HOOK_TIMEOUT_S }] }];
  // Claude Code's own auto memory is off: its writes would each need a card. Jarvis uses
  // memory.js instead.
  return JSON.stringify({ autoMemoryEnabled: false, hooks: { PermissionRequest: handler, PreToolUse: handler } });
}

// ------------------------------------------------------------------ approvals

const pendingApprovals = new Map(); // approvalId -> { conn, taskId }
let approvalCounter = 0;

function describe(tool, input) {
  const clip = (s, n = 400) => {
    const text = String(s ?? '');
    return text.length > n ? text.slice(0, n) + '…' : text;
  };
  const browser = tool.startsWith('mcp__claude-in-chrome__') ? tool.slice('mcp__claude-in-chrome__'.length) : null;
  if (tool === 'Bash') {
    const command = String(input.command || '');
    const title = /\bosascript\b/.test(command) ? 'Control an app on your Mac' : 'Run a command';
    return { title: input.description ? clip(input.description, 140) : title, detail: clip(command) };
  }
  if (browser === 'computer') {
    const what = input.action_summary || `${input.action}${input.text ? `: “${input.text}”` : ''}`;
    return { title: `Browser: ${clip(what, 140)}`, detail: clip(JSON.stringify({ action: input.action, coordinate: input.coordinate, text: input.text, ref: input.ref })) };
  }
  if (browser === 'form_input') return { title: `Browser: ${clip(input.action_summary || 'fill in a field', 140)}`, detail: clip(`Value: ${JSON.stringify(input.value)}`) };
  if (browser === 'javascript_tool') return { title: 'Browser: run JavaScript in the page', detail: clip(input.text) };
  if (browser === 'browser_batch') {
    const steps = (input.actions || []).map((a) => a?.input?.action_summary || `${a?.name} ${a?.input?.action || ''}`.trim());
    return { title: `Browser: ${steps.length} steps`, detail: clip(steps.map((s, i) => `${i + 1}. ${s}`).join('\n')) };
  }
  if (tool === 'Write' || tool === 'Edit') return { title: `${tool} a file`, detail: clip(input.file_path) };
  return { title: `Use ${browser ? `browser ${browser}` : tool}`, detail: clip(JSON.stringify(input)) };
}

function handleApprovalConnection(conn) {
  let buffer = '';
  conn.on('data', (chunk) => {
    buffer += chunk;
    const newline = buffer.indexOf('\n');
    if (newline < 0) return;
    let request;
    try { request = JSON.parse(buffer.slice(0, newline)); } catch { conn.end(); return; }
    buffer = '';
    if (request.kind === 'timer') {
      conn.end(JSON.stringify({ message: handleTimer(request) }) + '\n');
      return;
    }
    if (!current) {
      conn.end(JSON.stringify({ allow: false, reason: 'No request is running.' }) + '\n');
      return;
    }
    const approvalId = `a${++approvalCounter}`;
    const { title, detail } = describe(String(request.tool || ''), request.input || {});
    pendingApprovals.set(approvalId, { conn, taskId: current.id, tool: request.tool, title });
    audit({ task: current.id, event: 'approval-requested', tool: request.tool, summary: title });
    send({ type: 'state', id: current.id, state: 'awaitingApproval' });
    send({ type: 'approvalRequest', id: current.id, approvalId, title, detail });
  });
  conn.on('error', () => {});
}

function answerApproval(approvalId, allow, reason) {
  const pending = pendingApprovals.get(approvalId);
  if (!pending) return;
  pendingApprovals.delete(approvalId);
  audit({ task: pending.taskId, event: 'approval', tool: pending.tool, summary: pending.title, decision: allow ? 'approved' : 'denied', reason });
  pending.conn.end(JSON.stringify({ allow, reason }) + '\n');
  if (current && current.id === pending.taskId) send({ type: 'state', id: current.id, state: 'thinking' });
}

function denyApprovalsFor(taskId, reason) {
  for (const [approvalId, pending] of pendingApprovals) {
    if (pending.taskId === taskId) answerApproval(approvalId, false, reason);
  }
}

// --------------------------------------------------------------------- timers

const timers = new Map(); // id -> { label, fireAt, handle }
let timerCounter = 0;

function formatDuration(totalSeconds) {
  const s = Math.max(0, Math.round(totalSeconds));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  return [h && `${h}h`, m && `${m}m`, sec && !h && `${sec}s`].filter(Boolean).join(' ') || '0s';
}

function handleTimer({ action, seconds, label, id }) {
  if (action === 'set') {
    const timerId = String(++timerCounter);
    const name = (label || '').trim() || `${formatDuration(seconds)} timer`;
    const handle = setTimeout(() => {
      timers.delete(timerId);
      audit({ event: 'timer-fired', timer: timerId });
      send({ type: 'timerFired', label: name });
    }, seconds * 1000);
    timers.set(timerId, { label: name, fireAt: Date.now() + seconds * 1000, handle });
    audit({ event: 'timer-set', timer: timerId, seconds });
    return `Timer ${timerId} set: ${name}, ${formatDuration(seconds)}.`;
  }
  if (action === 'list') {
    if (!timers.size) return 'No timers running.';
    return [...timers].map(([tid, t]) => `${tid}: ${t.label}, ${formatDuration((t.fireAt - Date.now()) / 1000)} left`).join('\n');
  }
  if (action === 'cancel') {
    const ids = !id || id === 'all' ? [...timers.keys()] : [String(id)];
    let cancelled = 0;
    for (const tid of ids) {
      const t = timers.get(tid);
      if (t) { clearTimeout(t.handle); timers.delete(tid); cancelled++; }
    }
    return cancelled ? `Cancelled ${cancelled} timer${cancelled === 1 ? '' : 's'}.` : 'No such timer.';
  }
  return 'Unknown timer action.';
}

rmSync(SOCKET, { force: true });
const approvalServer = net.createServer(handleApprovalConnection);
approvalServer.listen(SOCKET);

// ------------------------------------------------------------------- briefing

// The morning dashboard. Calendar, reminders and texts are read locally; one Claude call with only
// Gmail's read tools adds email and writes the summary. Event and reminder times on the card come
// from the raw data, not from the model.
const GMAIL_READ_TOOLS = ['search_threads', 'get_thread', 'get_message', 'list_labels'].map((t) => `mcp__claude_ai_Gmail__${t}`);
const BRIEFING_TIMEOUT_MS = 120 * 1000;
const BRIEFING_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['headline', 'spoken', 'priorities', 'messages', 'email'],
  properties: {
    headline: { type: 'string', description: 'One short line summing up the day, e.g. "Two events, one overdue reminder."' },
    spoken: { type: 'string', description: 'Two to four sentences Jarvis reads aloud: the shape of the day and what needs attention first.' },
    priorities: {
      type: 'array', maxItems: 5,
      items: {
        type: 'object', additionalProperties: false, required: ['title', 'why'],
        properties: { title: { type: 'string' }, why: { type: 'string' }, due: { type: 'string' }, overdue: { type: 'boolean' } },
      },
    },
    messages: {
      type: 'array', maxItems: 6,
      items: {
        type: 'object', additionalProperties: false, required: ['from', 'summary', 'needsReply'],
        properties: { from: { type: 'string' }, summary: { type: 'string', description: 'What they asked or need, in one sentence.' }, needsReply: { type: 'boolean' } },
      },
    },
    email: {
      type: 'array', maxItems: 5,
      items: {
        type: 'object', additionalProperties: false, required: ['from', 'subject', 'summary'],
        properties: { from: { type: 'string' }, subject: { type: 'string' }, summary: { type: 'string' }, important: { type: 'boolean' } },
      },
    },
  },
};

function runTool(file, argv) {
  return new Promise((resolve) => {
    execFile(file, argv, { timeout: 30 * 1000, maxBuffer: 4 * 1024 * 1024, env: childEnv() }, (err, stdout, stderr) => {
      if (err) resolve({ error: (stderr || err.message).trim().split('\n')[0] });
      else {
        try { resolve({ data: JSON.parse(stdout) }); } catch { resolve({ error: 'unreadable output' }); }
      }
    });
  });
}

async function runBriefing({ id }) {
  const started = Date.now();
  audit({ event: 'briefing-start', task: id });
  const [events, reminders, texts] = await Promise.all([
    hasCalendarTool ? runTool(CALENDAR_TOOL, ['list', '--from', 'today', '--days', '1', '--json']) : { error: 'calendar tool missing' },
    hasCalendarTool ? runTool(CALENDAR_TOOL, ['reminders', '--days', '1', '--json']) : { error: 'calendar tool missing' },
    hasMessagesTool ? runTool(MESSAGES_TOOL, ['--hours', '36', '--json']) : { error: 'messages tool missing' },
  ]);

  const now = new Date();
  const prompt = [
    `It is ${now.toLocaleString('en-US', { weekday: 'long', month: 'long', day: 'numeric', hour: 'numeric', minute: '2-digit' })}. Build ${OWNER}'s daily briefing.`,
    'Check Gmail with the Gmail tools: unread or important messages from roughly the last day (for example search_threads with "is:unread newer_than:1d" and "is:important newer_than:2d"). Skip newsletters, promotions and automated notifications unless they need action.',
    `From the texts, find what people asked or need from ${OWNER}, and whether they have already replied. Ignore small talk.`,
    'Priorities: the few things that matter most today across calendar, reminders, texts and email, overdue first.',
    'Keep everything short. Do not invent anything not in the data. If a source is unavailable, leave it out; never list setup or permissions as a priority (the card notes missing sources itself).',
    `Calendar today: ${JSON.stringify(events.data ?? { unavailable: events.error })}`,
    `Reminders (incomplete, due by end of today or overdue): ${JSON.stringify(reminders.data ?? { unavailable: reminders.error })}`,
    `Texts, one-on-one conversations from the last 36 hours: ${JSON.stringify(texts.data ?? { unavailable: texts.error })}`,
  ].join('\n\n');

  const args = [
    '-p', '--output-format', 'json', '--model', DEFAULT_MODEL,
    '--tools', '', '--allowedTools', ...GMAIL_READ_TOOLS, '--permission-mode', 'dontAsk',
    '--json-schema', JSON.stringify(BRIEFING_SCHEMA),
    '--settings', JSON.stringify({ autoMemoryEnabled: false }),
  ];
  const summary = await new Promise((resolve) => {
    const child = spawn(CLAUDE, args, { cwd: WORKDIR, env: childEnv(), stdio: ['pipe', 'pipe', 'ignore'] });
    let out = '';
    const timer = setTimeout(() => child.kill('SIGTERM'), BRIEFING_TIMEOUT_MS);
    child.stdout.on('data', (chunk) => { out += chunk; });
    child.on('error', () => resolve(null));
    child.on('close', () => {
      clearTimeout(timer);
      try { resolve(JSON.parse(out).structured_output ?? null); } catch { resolve(null); }
    });
    child.stdin.end(prompt);
  });

  const sources = {
    calendar: events.error ?? 'ok',
    reminders: reminders.error ?? 'ok',
    messages: texts.error ?? 'ok',
    gmail: summary ? 'ok' : 'unavailable',
  };
  audit({ event: 'briefing-end', task: id, seconds: Math.round((Date.now() - started) / 1000), sources });
  send({
    type: 'briefing',
    id,
    events: events.data ?? [],
    reminders: reminders.data ?? [],
    summary: summary ?? { headline: 'Here is your day.', spoken: '', priorities: [], messages: [], email: [] },
    sources,
  });
}

// ---------------------------------------------------------------------- tasks

const sessions = new Map(); // chatId -> Claude Code session id
// Claude Code stays running for the current chat (stream-json input), so a follow-up skips the
// ~1-2 s startup, and it is started as soon as the orb opens its input, while the owner is still
// speaking. Stopping a request or switching chat/model ends it; the next request resumes the
// chat's saved session.
let warm = null; // { chatId, model, child, exited, task, idleTimer, stderr }
let current = null;
const IDLE_SESSION_MS = 10 * 60 * 1000;

function spawnSession(chatId, model, browser) {
  const args = [
    '-p',
    '--input-format', 'stream-json',
    '--output-format', 'stream-json',
    '--verbose',
    '--include-partial-messages',
    '--model', model,
    '--tools', TOOLS,
    '--allowedTools', 'WebSearch', 'WebFetch',
    ...(hasCalendarTool ? [`Bash(${CALENDAR_TOOL} list*)`, `Bash(${CALENDAR_TOOL} reminders*)`, `Bash(${CALENDAR_TOOL} calendars*)`] : []),
    ...(hasMessagesTool ? [`Bash(${MESSAGES_TOOL}*)`] : []),
    `Bash(${MEMORY_TOOL} *)`,
    `Bash(${MAC_TOOL} *)`,
    ...(browser ? ['--chrome'] : []),
    '--strict-mcp-config',
    '--settings', hookSettings(),
    '--append-system-prompt', systemPrompt(),
  ];
  const session = sessions.get(chatId);
  if (session) args.push('--resume', session);

  const child = spawn(CLAUDE, args, { cwd: WORKDIR, env: childEnv(), stdio: ['pipe', 'pipe', 'pipe'] });
  const proc = { chatId, model, browser, child, exited: false, task: null, idleTimer: null, stderr: '', resumed: !!session };

  readline.createInterface({ input: child.stdout }).on('line', (line) => {
    let m;
    try { m = JSON.parse(line); } catch { return; }
    // Only a session that has finished a request can be resumed; a warm session that never got a
    // message has no conversation for --resume to find.
    if (m.type === 'result' && m.session_id) sessions.set(chatId, m.session_id);
    if (proc.task) handleLine(proc.task, m);
  });
  child.stderr.on('data', (chunk) => { proc.stderr = (proc.stderr + chunk).slice(-2000); });
  child.stdin.on('error', () => {});
  child.on('error', (err) => {
    proc.exited = true;
    if (proc.task) {
      finish(proc.task, { type: 'error', id: proc.task.id, message: err.code === 'ENOENT'
        ? `Claude Code not found at ${CLAUDE}.`
        : `Could not start Claude Code: ${err.message}` });
    }
  });
  child.on('close', (code) => {
    proc.exited = true;
    clearTimeout(proc.idleTimer);
    if (warm === proc) warm = null;
    const task = proc.task;
    if (!task) return;
    if (task.cancelled) finish(task, { type: 'done', id: task.id, cancelled: true });
    else finish(task, { type: 'error', id: task.id, message: `Claude Code exited unexpectedly (code ${code}).` });
  });
  return proc;
}

function closeSession(proc) {
  if (!proc || proc.exited) return;
  clearTimeout(proc.idleTimer);
  if (warm === proc) warm = null;
  proc.child.stdin.end();
  setTimeout(() => { if (!proc.exited) proc.child.kill('SIGTERM'); }, CANCEL_GRACE_MS).unref();
}

function armIdle(proc) {
  clearTimeout(proc.idleTimer);
  proc.idleTimer = setTimeout(() => { if (!proc.task) closeSession(proc); }, IDLE_SESSION_MS);
  proc.idleTimer.unref();
}

/// A session for this chat and model, reusing the warm one when it matches.
function sessionFor(chatId, model, browser) {
  if (warm && !warm.exited && warm.chatId === chatId && warm.model === model && (warm.browser || !browser)) return warm;
  if (warm && !warm.task) closeSession(warm);
  warm = spawnSession(chatId, model, browser);
  armIdle(warm);
  return warm;
}

function prepare({ chatId, model }) {
  if (current || !chatId) return; // never disturb a running request
  sessionFor(chatId, model || DEFAULT_MODEL, browserChats.has(chatId));
}

function startTask({ id, chatId, text, model }) {
  if (current) cancelTask(current.id);
  if (typeof text !== 'string' || !text.trim()) {
    send({ type: 'error', id, message: 'Empty request.' });
    return;
  }
  model = model || DEFAULT_MODEL;
  chatId = chatId || id;
  if (BROWSER_WORDS.test(text)) browserChats.add(chatId);
  const proc = sessionFor(chatId, model, browserChats.has(chatId));
  clearTimeout(proc.idleTimer);
  const task = { id, chatId, proc, child: proc.child, cancelled: false, finished: false, wroteText: false, inText: false };
  proc.task = task;
  current = task;
  audit({ task: id, event: 'task-start', model, resumed: proc.resumed, browser: proc.browser, chars: text.length });
  rememberRequest(text);
  send({ type: 'state', id, state: 'thinking' });
  task.timer = setTimeout(() => {
    task.cancelled = true;
    denyApprovalsFor(id, 'The request ran too long and was stopped.');
    finish(task, { type: 'error', id, message: 'Stopped: the request ran longer than 10 minutes.' });
    stopSession(proc);
  }, MAX_TASK_MS);

  // The prompt goes in on stdin so it never shows up in a process listing.
  proc.child.stdin.write(JSON.stringify({ type: 'user', message: { role: 'user', content: text } }) + '\n');
}

/// Ends a session mid-request: SIGINT ends the turn, SIGTERM if it hasn't exited after a grace period.
function stopSession(proc) {
  if (warm === proc) warm = null;
  if (proc.exited) return;
  proc.child.kill('SIGINT');
  setTimeout(() => { if (!proc.exited) proc.child.kill('SIGTERM'); }, CANCEL_GRACE_MS).unref();
}

function handleLine(task, m) {
  if (task.finished) return;
  // Subagent traffic carries a parent tool id; only the main conversation is shown.
  if (m.parent_tool_use_id) return;

  if (m.type === 'stream_event') {
    const ev = m.event || {};
    if (ev.type === 'content_block_start') {
      const block = ev.content_block || {};
      if (block.type === 'text') {
        // Separate text from successive turns of the agent loop.
        if (task.wroteText) send({ type: 'text', id: task.id, delta: '\n\n' });
        task.inText = true;
      } else if (block.type === 'tool_use' || block.type === 'server_tool_use') {
        send({ type: 'tool', id: task.id, name: block.name });
      }
    } else if (ev.type === 'content_block_delta' && ev.delta?.type === 'text_delta' && task.inText) {
      if (!task.wroteText) send({ type: 'state', id: task.id, state: 'speaking' });
      task.wroteText = true;
      send({ type: 'text', id: task.id, delta: ev.delta.text });
    } else if (ev.type === 'content_block_stop') {
      task.inText = false;
    }
  } else if (m.type === 'assistant' && !m.error) {
    for (const block of m.message?.content || []) {
      if (block.type === 'tool_use' || block.type === 'server_tool_use') {
        audit({ task: task.id, event: 'tool', tool: block.name, summary: describe(block.name, block.input || {}).title });
      }
    }
  } else if (m.type === 'assistant' && m.error) {
    // e.g. authentication_failed: the message text says what to do ("Please run /login").
    const said = (m.message?.content || []).filter((b) => b.type === 'text').map((b) => b.text).join(' ');
    task.assistantError = describeError(m.error, said);
  } else if (m.type === 'result') {
    if (m.is_error || m.subtype !== 'success') {
      finish(task, { type: 'error', id: task.id, message: task.assistantError || resultError(m) });
    } else {
      finish(task, { type: 'done', id: task.id });
    }
  }
}

function describeError(kind, said) {
  if (kind === 'authentication_failed') {
    return 'Claude Code is not signed in. In Terminal run: env -u ANTHROPIC_API_KEY claude auth login';
  }
  return said || `Claude reported an error (${kind}).`;
}

function resultError(m) {
  if (Array.isArray(m.errors) && m.errors.length) return m.errors.join(' ');
  if (typeof m.result === 'string' && m.result) return m.result;
  return `Claude finished with ${m.subtype}.`;
}

function finish(task, message) {
  if (task.finished) return;
  task.finished = true;
  clearTimeout(task.timer);
  if (current === task) current = null;
  audit({ task: task.id, event: 'task-end', outcome: message.type === 'error' ? 'error' : (message.cancelled ? 'stopped' : 'done') });
  denyApprovalsFor(task.id, 'The request ended before the owner answered.');
  send(message);
  const proc = task.proc;
  if (proc.task === task) proc.task = null;
  // A clean finish keeps the session warm for the next turn; anything else ends it.
  if (message.type === 'done' && !message.cancelled && !proc.exited) armIdle(proc);
  else stopSession(proc);
}

function cancelTask(id) {
  const task = current;
  if (!task || task.id !== id) return;
  task.cancelled = true;
  denyApprovalsFor(id, 'The owner stopped the request.');
  finish(task, { type: 'done', id, cancelled: true });
}

function shutdown() {
  if (warm && !warm.exited) warm.child.kill('SIGTERM');
  if (current && !current.proc.exited) current.proc.child.kill('SIGTERM');
  approvalServer.close();
  rmSync(SOCKET, { force: true });
  process.exit(0);
}

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  let m;
  try { m = JSON.parse(line); } catch { return; }
  if (m.type === 'task') startTask(m);
  else if (m.type === 'prepare') prepare(m);
  else if (m.type === 'briefing') runBriefing(m);
  else if (m.type === 'cancel') cancelTask(m.id);
  else if (m.type === 'approval') answerApproval(m.approvalId, !!m.allow, m.allow ? undefined : 'The owner denied this action.');
}).on('close', shutdown); // The app went away: stop any run and exit.
process.on('SIGTERM', shutdown);

send({ type: 'ready' });
