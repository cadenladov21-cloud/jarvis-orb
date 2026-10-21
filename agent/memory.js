#!/usr/bin/env node
// jarvis-memory: what Jarvis remembers about the owner, kept in memory/profile.md inside the
// agent's workspace and loaded into every conversation (see index.js).
//
//   memory.js add "text" [--section Preferences|Routines|Projects|People|Notes]
//   memory.js forget "words"       removes every entry containing the words (case-insensitive)
//   memory.js show
//
// Pre-approved for Jarvis (no card): it only edits this one file.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';

const SECTIONS = ['Preferences', 'Routines', 'Projects', 'People', 'Notes'];
const workdir = process.env.JARVIS_WORKDIR || join(homedir(), 'Library/Application Support/JarvisOrb/workspace');
export const PROFILE = join(workdir, 'memory', 'profile.md');

function load() {
  if (!existsSync(PROFILE)) return SECTIONS.map((s) => `## ${s}\n`).join('\n');
  return readFileSync(PROFILE, 'utf8');
}

function save(text) {
  mkdirSync(dirname(PROFILE), { recursive: true });
  writeFileSync(PROFILE, text.replace(/\n{3,}/g, '\n\n').trimEnd() + '\n');
}

function add(entry, section) {
  const name = SECTIONS.find((s) => s.toLowerCase() === String(section || 'Notes').toLowerCase()) || 'Notes';
  const line = `- ${entry.replace(/\s+/g, ' ').trim()} (${new Date().toLocaleDateString('en-CA')})`;
  const lines = load().split('\n');
  let at = lines.findIndex((l) => l.trim() === `## ${name}`);
  if (at < 0) {
    lines.push('', `## ${name}`);
    at = lines.length - 1;
  }
  let end = at + 1;
  while (end < lines.length && !lines[end].startsWith('## ')) end++;
  while (end > at + 1 && lines[end - 1].trim() === '') end--;
  lines.splice(end, 0, line);
  save(lines.join('\n'));
  return `Remembered under ${name}: ${entry}`;
}

function forget(words) {
  const needle = words.toLowerCase();
  const lines = load().split('\n');
  const kept = lines.filter((l) => !(l.startsWith('- ') && l.toLowerCase().includes(needle)));
  save(kept.join('\n'));
  const removed = lines.length - kept.length;
  return removed ? `Forgot ${removed} entr${removed === 1 ? 'y' : 'ies'}.` : 'Nothing matched.';
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [command, text, ...rest] = process.argv.slice(2);
  const section = rest[rest.indexOf('--section') + 1];
  if (command === 'add' && text) console.log(add(text, rest.includes('--section') ? section : undefined));
  else if (command === 'forget' && text) console.log(forget(text));
  else if (command === 'show') console.log(load().trim() || '(nothing remembered yet)');
  else {
    console.error('usage: memory.js add "text" [--section Preferences|Routines|Projects|People|Notes] | forget "words" | show');
    process.exit(1);
  }
}
