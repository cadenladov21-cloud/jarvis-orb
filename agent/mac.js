#!/usr/bin/env node
// jarvis-mac: quick system actions for Jarvis. Pre-approved (no card): everything here is
// harmless and easy to undo.
//
//   mac.js open <app name | folder | file | url>
//   mac.js volume get | set <0-100> | up | down | mute | unmute
//   mac.js timer set <duration: 90s, 20m, 1h30m, 1:30> [label] | list | cancel [id|all]
//   mac.js search <words> [--names]        Spotlight; --names matches file names only
//   mac.js dnd on | off                    runs the Shortcuts "Jarvis DND On" / "Jarvis DND Off"
//
// Timers live in the agent helper (it outlives this command); this talks to it over the socket
// in JARVIS_SOCKET.

import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import net from 'node:net';
import { homedir } from 'node:os';

const [command, ...args] = process.argv.slice(2);

function fail(message) {
  console.error(message);
  process.exit(1);
}

function run(file, argv) {
  return execFileSync(file, argv, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

function osascript(script) {
  return run('/usr/bin/osascript', ['-e', script]);
}

function helper(request) {
  const socket = process.env.JARVIS_SOCKET;
  if (!socket) fail('Timers need the Jarvis app running (JARVIS_SOCKET is not set).');
  return new Promise((resolve) => {
    const conn = net.createConnection(socket);
    let buffer = '';
    conn.on('connect', () => conn.write(JSON.stringify(request) + '\n'));
    conn.on('data', (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf('\n');
      if (newline < 0) return;
      conn.end();
      resolve(JSON.parse(buffer.slice(0, newline)));
    });
    conn.on('error', () => fail('Could not reach the Jarvis app for timers.'));
  });
}

/// "90s", "20m", "1h30m", "1:30" (m:ss) or a bare number of minutes → seconds.
function seconds(text) {
  const s = String(text || '').trim().toLowerCase();
  if (/^\d+(\.\d+)?$/.test(s)) return Math.round(parseFloat(s) * 60);
  const clock = s.match(/^(\d+):(\d{2})(?::(\d{2}))?$/);
  if (clock) return clock[3] ? (+clock[1]) * 3600 + (+clock[2]) * 60 + (+clock[3]) : (+clock[1]) * 60 + (+clock[2]);
  let total = 0, matched = false;
  for (const [, n, unit] of s.matchAll(/(\d+(?:\.\d+)?)\s*(h|hr|hrs|hours?|m|min|mins|minutes?|s|sec|secs|seconds?)/g)) {
    matched = true;
    total += parseFloat(n) * (unit.startsWith('h') ? 3600 : unit.startsWith('m') ? 60 : 1);
  }
  return matched ? Math.round(total) : NaN;
}

switch (command) {
  case 'open': {
    const target = args.join(' ').trim();
    if (!target) fail('open needs an app, folder, file or URL');
    const expanded = target.replace(/^~(?=\/|$)/, homedir());
    const isUrl = /^[a-z][a-z0-9+.-]*:\/\//i.test(target);
    if (isUrl || existsSync(expanded)) {
      run('/usr/bin/open', [isUrl ? target : expanded]);
    } else {
      try {
        run('/usr/bin/open', ['-a', target]);
      } catch {
        fail(`No app, folder or file called "${target}". Try: mac.js search ${target} --names`);
      }
    }
    console.log(`Opened ${target}`);
    break;
  }
  case 'volume': {
    const [action, value] = args;
    const current = () => parseInt(osascript('output volume of (get volume settings)'), 10);
    if (action === 'get' || !action) {
      const muted = osascript('output muted of (get volume settings)') === 'true';
      console.log(`Volume ${current()}%${muted ? ' (muted)' : ''}`);
    } else if (action === 'set') {
      const level = Math.max(0, Math.min(100, parseInt(value, 10)));
      if (Number.isNaN(level)) fail('volume set needs 0-100');
      osascript(`set volume output volume ${level} without output muted`);
      console.log(`Volume ${level}%`);
    } else if (action === 'up' || action === 'down') {
      const level = Math.max(0, Math.min(100, current() + (action === 'up' ? 1 : -1) * (parseInt(value, 10) || 10)));
      osascript(`set volume output volume ${level} without output muted`);
      console.log(`Volume ${level}%`);
    } else if (action === 'mute' || action === 'unmute') {
      osascript(`set volume ${action === 'mute' ? 'with' : 'without'} output muted`);
      console.log(action === 'mute' ? 'Muted' : 'Unmuted');
    } else {
      fail('volume get | set <0-100> | up [step] | down [step] | mute | unmute');
    }
    break;
  }
  case 'timer': {
    const [action, ...rest] = args;
    if (action === 'set') {
      const duration = seconds(rest[0]);
      if (!duration || duration < 1) fail('timer set needs a duration like 90s, 20m, 1h30m or 1:30');
      const answer = await helper({ kind: 'timer', action: 'set', seconds: duration, label: rest.slice(1).join(' ') });
      console.log(answer.message);
    } else if (action === 'list' || action === 'cancel') {
      const answer = await helper({ kind: 'timer', action, id: rest[0] });
      console.log(answer.message);
    } else {
      fail('timer set <duration> [label] | list | cancel [id|all]');
    }
    break;
  }
  case 'search': {
    const namesOnly = args.includes('--names');
    const words = args.filter((a) => a !== '--names').join(' ').trim();
    if (!words) fail('search needs words');
    const out = run('/usr/bin/mdfind', namesOnly ? ['-name', words] : [words]);
    const hits = out.split('\n').filter((p) => p && !p.includes('/Library/') && !p.includes('/.'));
    console.log(hits.length ? hits.slice(0, 15).join('\n') + (hits.length > 15 ? `\n…and ${hits.length - 15} more` : '') : 'No matches.');
    break;
  }
  case 'dnd': {
    const on = args[0] === 'on';
    if (args[0] !== 'on' && args[0] !== 'off') fail('dnd on | off');
    const name = on ? 'Jarvis DND On' : 'Jarvis DND Off';
    const shortcuts = run('/usr/bin/shortcuts', ['list']).split('\n');
    if (!shortcuts.includes(name)) {
      fail(`Do Not Disturb needs a Shortcut named "${name}" (Shortcuts app → new shortcut → "Set Focus" → Do Not Disturb ${on ? 'On' : 'Off'}). Ask the user to create it once.`);
    }
    run('/usr/bin/shortcuts', ['run', name]);
    console.log(`Do Not Disturb ${on ? 'on' : 'off'}`);
    break;
  }
  default:
    fail('usage: mac.js open <app|folder|file|url> | volume … | timer … | search <words> [--names] | dnd on|off');
}
