#!/usr/bin/env node
// Claude Code hook that puts an Approve/Deny card in front of the owner.
//
// Registered for two events (see index.js):
//   PermissionRequest  anything Claude Code itself wants permission for (shell commands that
//                      change things, AppleScript, file writes, ...). No answer means deny.
//   PreToolUse         browser actions that can change a page (clicks, typing, form fills,
//                      JavaScript), which the browser extension may not ask about on its own.
//
// Harmless browser actions (looking, scrolling, reading) pass without a card. Everything else
// is sent over a Unix socket to the agent helper, which forwards it to the app and waits for
// the owner's answer. If the app can't be reached, the action is denied.
//
// Usage: approval-hook.js <socket-path>

import net from 'node:net';

const socketPath = process.argv[2];

const READ_ONLY_BROWSER_TOOLS = new Set([
  'tabs_context_mcp', 'tabs_create_mcp', 'navigate', 'read_page', 'get_page_text', 'find',
  'read_console_messages', 'read_network_requests', 'list_connected_browsers', 'select_browser',
  'switch_browser', 'shortcuts_list', 'resize_window',
]);
const READ_ONLY_BROWSER_ACTIONS = new Set([
  'screenshot', 'scroll', 'scroll_to', 'zoom', 'wait', 'hover', 'cursor_position', 'mouse_move',
]);

function output(event, allow, reason) {
  const hookSpecificOutput = event === 'PermissionRequest'
    ? { hookEventName: event, decision: allow ? { behavior: 'allow' } : { behavior: 'deny', message: reason } }
    : { hookEventName: event, permissionDecision: allow ? 'allow' : 'deny', permissionDecisionReason: reason };
  process.stdout.write(JSON.stringify({ hookSpecificOutput }));
  process.exit(0);
}

function browserTool(name) {
  const prefix = 'mcp__claude-in-chrome__';
  return name.startsWith(prefix) ? name.slice(prefix.length) : null;
}

function isHarmless(tool, input) {
  const browser = browserTool(tool);
  if (!browser) return false;
  if (READ_ONLY_BROWSER_TOOLS.has(browser)) return true;
  if (browser === 'computer') return READ_ONLY_BROWSER_ACTIONS.has(input?.action);
  if (browser === 'browser_batch') {
    return (input?.actions || []).every((a) => {
      const name = String(a?.name || '');
      return READ_ONLY_BROWSER_TOOLS.has(name) || (name === 'computer' && READ_ONLY_BROWSER_ACTIONS.has(a?.input?.action));
    });
  }
  return false;
}

function ask(request) {
  return new Promise((resolve) => {
    const conn = net.createConnection(socketPath);
    let buffer = '';
    conn.on('connect', () => conn.write(JSON.stringify(request) + '\n'));
    conn.on('data', (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf('\n');
      if (newline < 0) return;
      try { resolve(JSON.parse(buffer.slice(0, newline))); } catch { resolve({ allow: false, reason: 'Bad answer from Jarvis.' }); }
      conn.end();
    });
    conn.on('error', () => resolve({ allow: false, reason: 'Jarvis could not show an approval card, so the action was not taken.' }));
    conn.on('close', () => resolve({ allow: false, reason: 'No answer from the owner.' }));
  });
}

let raw = '';
process.stdin.on('data', (chunk) => { raw += chunk; });
process.stdin.on('end', async () => {
  let payload;
  try { payload = JSON.parse(raw); } catch { process.exit(0); }
  const event = payload.hook_event_name;
  const tool = payload.tool_name || '';
  const input = payload.tool_input || {};

  // PreToolUse only gates browser actions; everything else goes through Claude Code's own
  // permission check and, when it needs one, the PermissionRequest event.
  if (event === 'PreToolUse' && (!browserTool(tool) || isHarmless(tool, input))) process.exit(0);
  if (event === 'PermissionRequest' && isHarmless(tool, input)) output(event, true);

  const answer = await ask({ tool, input });
  output(event, !!answer.allow, answer.reason || (answer.allow ? undefined : 'The owner denied this action.'));
});
