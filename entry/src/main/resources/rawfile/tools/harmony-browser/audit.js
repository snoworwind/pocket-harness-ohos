// Append-only audit trail for browser decisions and outcomes.
//
// Modelled on the observability Codex derives from its Decision enum: every
// allow/prompt/forbid and every finished request leaves one JSONL line, so an
// operator can reconstruct what the agent tried and what the policy did.
//
// Privacy rules, enforced by a strict field allowlist:
//   * never page content, never entered text, never credentials or tokens;
//   * for URLs only scheme + hostname are stored (paths/queries may carry
//     secrets, so they are dropped);
//   * text entry records only a byte length.
//
// Auditing is best-effort: a failure to write must never fail or delay a
// request, and the whole trail can be disabled with DSH_BROWSER_AUDIT=0.

import { appendFileSync, mkdirSync, renameSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';

const ALLOWED_FIELDS = [
  'operation', 'decision', 'reason', 'outcome', 'code',
  'ref', 'direction', 'action', 'offset', 'limit', 'textLength',
  'scheme', 'host',
];

const MAX_FIELD = 200;

// A long-lived device would otherwise grow this file without bound. One
// rotation keeps at most 2 x MAX_AUDIT_BYTES on disk; the previous file is
// replaced atomically so a crash never leaves a half-written log.
export const MAX_AUDIT_BYTES = 512 * 1024;

function rotateIfNeeded(file) {
  try {
    if (statSync(file).size < MAX_AUDIT_BYTES) return;
    renameSync(file, file + '.1');
  } catch { /* no file yet, or a race with another writer: just append */ }
}

export function auditFile() {
  const home = process.env.DSH_HOME;
  if (!home || typeof home !== 'string') return null;
  return join(home, 'browser-audit.jsonl');
}

function sanitize(entry) {
  const line = {};
  for (const key of ALLOWED_FIELDS) {
    const value = entry[key];
    if (value === undefined || value === null) continue;
    if (typeof value === 'string') line[key] = value.slice(0, MAX_FIELD);
    else if (typeof value === 'number' && Number.isFinite(value)) line[key] = value;
    else if (typeof value === 'boolean') line[key] = value;
  }
  return line;
}

export function recordAudit(entry) {
  if (process.env.DSH_BROWSER_AUDIT === '0') return;
  const file = auditFile();
  if (!file || !entry || typeof entry !== 'object') return;
  const line = { ts: new Date().toISOString(), ...sanitize(entry) };
  try {
    mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
    rotateIfNeeded(file);
    appendFileSync(file, JSON.stringify(line) + '\n', { mode: 0o600 });
  } catch { /* auditing must never break a request */ }
}

// Keep only scheme and hostname: a full URL can carry credentials, tokens in
// the query string, or identifying paths.
export function urlAuditFields(value) {
  try {
    const url = new URL(value);
    return { scheme: url.protocol.replace(/:$/, ''), host: url.hostname };
  } catch { return {}; }
}

// Byte length of the decoded text, never the text itself.
export function encodedTextLength(base64) {
  if (typeof base64 !== 'string') return undefined;
  try { return Buffer.from(base64, 'base64').length; } catch { return undefined; }
}
