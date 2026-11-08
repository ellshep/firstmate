#!/usr/bin/env node
// Away nudge for an existing supervision cycle. No scheduler or service is started here.
// Usage: fm-afk-nudge.mjs check [--command] | mark-sent | reply <message> | guard-start <id>
// FM_AWAY_NUDGE_AFTER_SECS defaults to 86400. FM_AWAY_NUDGE_NOW_EPOCH is a test clock.
// Eligible backlog bodies contain exact lines "Ready gate: passed" and
// "Away start: scout|firstmate-fork-pr|app-pr". The task must also be in
// tasks-axi's current ready list; either gate failing excludes it.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const home = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || path.join(home, 'state');
const data = process.env.FM_DATA_OVERRIDE || path.join(home, 'data');
const config = process.env.FM_CONFIG_OVERRIDE || path.join(home, 'config');
const record = path.join(state, '.afk-contract');
const ledger = path.join(state, '.afk-nudge.json');
const threshold = Number(process.env.FM_AWAY_NUDGE_AFTER_SECS || 86400);
const now = Number(process.env.FM_AWAY_NUDGE_NOW_EPOCH || Math.floor(Date.now() / 1000));
if (!Number.isSafeInteger(threshold) || threshold < 0 || !Number.isSafeInteger(now) || now < 0) {
  console.error('fm-afk-nudge: invalid threshold or clock');
  process.exit(2);
}

function field(source, name) {
  return source.match(new RegExp(`^${name}: (.*)$`, 'm'))?.[1] || '';
}
function runAxi(args) {
  const result = spawnSync('tasks-axi', [...args, '--file', path.join(data, 'backlog.md')], { encoding: 'utf8', timeout: 10000 });
  if (result.status !== 0) throw new Error(`tasks-axi ${args[0]} failed: ${result.stderr || result.error || result.stdout}`);
  return result.stdout;
}
function readLedger(entered) {
  try {
    const value = JSON.parse(fs.readFileSync(ledger, 'utf8'));
    if (value.entered === entered && Array.isArray(value.sent)) return value;
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  return { entered, sent: [], suggested: [], pending: null, lastSent: null };
}
function writeLedger(value) {
  fs.mkdirSync(state, { recursive: true });
  const tmp = `${ledger}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, `${JSON.stringify(value)}\n`, { mode: 0o600 });
  fs.renameSync(tmp, ledger);
}
function channelCommand() {
  if (process.env.FM_WEDGE_ALARM_CHANNEL) {
    return process.env.FM_WEDGE_ALARM_CHANNEL.startsWith('command:') ? process.env.FM_WEDGE_ALARM_CHANNEL.slice(8) : '';
  }
  const file = path.join(config, 'wedge-alarm');
  if (!fs.existsSync(file)) return '';
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/).map((line) => line.trim()).filter((line) => line && !line.startsWith('#'));
  if (lines.includes('off')) return '';
  return lines.find((line) => line.startsWith('command:'))?.slice(8) || '';
}
function candidates() {
  const ready = runAxi(['ready']);
  const ids = [];
  let inRows = false;
  for (const line of ready.split('\n')) {
    if (/^ready\[\d+\]/.test(line)) { inRows = true; continue; }
    if (inRows && !/^  /.test(line)) inRows = false;
    if (inRows) ids.push(line.trim().split(',')[0]);
  }
  const safe = [];
  for (const id of ids) {
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id)) continue;
    const detail = runAxi(['show', id, '--full']);
    const kind = field(detail, '  kind');
    const repo = field(detail, '  repo');
    const title = field(detail, '  title');
    const bodyLine = field(detail, '  body');
    let body = bodyLine;
    if (bodyLine.startsWith('"')) {
      try { body = JSON.parse(bodyLine); } catch { continue; }
    }
    if (!/^Ready gate: passed\s*$/im.test(body)) continue;
    const category = body.match(/^Away start: (scout|firstmate-fork-pr|app-pr)\s*$/im)?.[1]?.toLowerCase();
    if (!category) continue;
    if (category === 'scout' && kind !== 'scout') continue;
    if (category !== 'scout' && kind !== 'ship') continue;
    if (category === 'firstmate-fork-pr' && repo !== 'firstmate') continue;
    if (category === 'app-pr' && repo === 'firstmate') continue;
    const prose = body.replace(/^Ready gate: passed\s*$/gim, '').replace(/^Away start: (scout|firstmate-fork-pr|app-pr)\s*$/gim, '');
    if (/\b(money\w*|financial\w*|payment\w*|billing\w*|invoice\w*|pricing\w*|subscription\w*|charge\w*|migrat\w*|production\w*|prod\w*|provider settings?|credential\w*|secret\w*|deploy\w*|release\w*|publish\w*|outward.facing|external\w*|merg\w*)\b/i.test(`${title} ${prose}`)) continue;
    safe.push({ id, title, category });
  }
  return safe;
}
function activeRecord() {
  if (!fs.existsSync(record)) return null;
  const text = fs.readFileSync(record, 'utf8');
  if (field(text, 'mode') === 'quiet') return null;
  const entered = Number(field(text, 'entered_epoch'));
  return Number.isSafeInteger(entered) ? entered : null;
}
function messageFor(items, elapsed) {
  const days = Math.floor(elapsed / 86400);
  const duration = days > 0 ? `${days} day${days === 1 ? '' : 's'}` : `${Math.floor(elapsed / 3600)} hours`;
  return `You've been away for ${duration}. These ready items are cleared and can be slated next. Do you want them to go?\n${items.map((item, i) => `${i + 1}. ${item.id}: ${item.title}`).join('\n')}\nReply go or yes for all, or reply with item numbers. Nothing starts until you reply.`;
}
function main() {
  const op = process.argv[2];
  const entered = activeRecord();
  if (entered === null) return;
  const saved = readLedger(entered);
  if (op === 'guard-start') {
    const id = process.argv[3];
    if (saved.pending?.items?.some((item) => item.id === id) || saved.suggested?.includes(id)) {
      console.error(`fm-afk-nudge: ${id} was suggested while away; wait for the captain's reply`);
      process.exitCode = 1;
    }
    return;
  }
  if (op === 'reply') {
    const reply = process.argv.slice(3).join(' ').trim().toLowerCase();
    const last = saved.lastSent;
    if (!last || !Array.isArray(last.items)) return;
    let chosen = [];
    if (/^(go|yes)[.!]?$/i.test(reply)) chosen = last.items;
    else if (/^(?:go\s+)?\d+(?:\s*[, ]\s*\d+)*[.!]?$/.test(reply)) {
      const numbers = [...new Set((reply.match(/\d+/g) || []).map(Number))];
      if (numbers.every((n) => n >= 1 && n <= last.items.length)) chosen = numbers.map((n) => last.items[n - 1]);
    }
    if (chosen.length) console.log(chosen.map((item) => item.id).join('\n'));
    return;
  }
  if (op === 'mark-sent') {
    if (!saved.pending) throw new Error('no pending nudge');
    saved.sent.push(saved.pending.key);
    saved.suggested = [...new Set([...(saved.suggested || []), ...saved.pending.items.map((item) => item.id)])];
    saved.lastSent = saved.pending;
    saved.pending = null;
    writeLedger(saved);
    return;
  }
  if (op !== 'check') throw new Error('usage: check [--command] | mark-sent | reply <message>');
  if (now - entered < threshold) return;
  const lockPath = `${ledger}.lock`;
  let fd;
  try {
    fd = fs.openSync(lockPath, 'wx', 0o600);
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
    const mtime = fs.statSync(lockPath, { throwIfNoEntry: false })?.mtimeMs ?? Date.now();
    if (Date.now() - mtime < 60000) return;
    fs.rmSync(lockPath, { force: true });
    try { fd = fs.openSync(lockPath, 'wx', 0o600); } catch { return; }
  }
  try {
    const current = readLedger(entered);
    const items = candidates();
    if (!items.length) return;
    const key = crypto.createHash('sha256').update(items.map((item) => item.id).sort().join('\n')).digest('hex');
    if (current.sent.includes(key)) return;
    if (current.pending?.key !== key) {
      current.pending = { key, items, message: messageFor(items, now - entered) };
      writeLedger(current);
    }
    if (process.argv.includes('--command')) {
      const command = channelCommand();
      if (!command) return;
      const result = spawnSync('sh', ['-c', command, 'fm-away-nudge', current.pending.message], {
        input: `${current.pending.message}\n`, encoding: 'utf8', timeout: Number(process.env.FM_WEDGE_ALARM_TIMEOUT_SECS || 10000),
      });
      if (result.status !== 0) throw new Error(`command notification failed: ${result.error || result.stderr || result.status}`);
      current.sent.push(key);
      current.suggested = [...new Set([...(current.suggested || []), ...current.pending.items.map((item) => item.id)])];
      current.lastSent = current.pending;
      current.pending = null;
      writeLedger(current);
      console.log('sent');
      return;
    }
    console.log(current.pending.message);
  } finally {
    fs.closeSync(fd);
    fs.rmSync(lockPath, { force: true });
  }
}
try { main(); } catch (error) { console.error(`fm-afk-nudge: ${error.message}`); process.exitCode = 1; }
