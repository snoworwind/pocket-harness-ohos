// Policy layer modelled on OpenAI Codex.
//
// codex-rs/core/src/safety.rs defines a three-state check:
//     enum SafetyCheck { AutoApprove, AskUser, Reject { reason } }
// codex-rs/core/src/exec_policy.rs derives a Decision from a command and the
// active approval policy:
//     enum Decision { Allow, Prompt, Forbidden }
//
// Two invariants are borrowed directly:
//   1. A dangerous operation is never silently allowed. Under the strictest
//      policy it is Forbidden; under looser policies it is still Prompted.
//      "dangerous + AskForApproval::Never => Forbidden" (exec_policy.rs).
//   2. A rejection carries a concrete reason, so the caller learns *why*
//      rather than a generic "denied" (e.g. PATCH_REJECTED_READ_ONLY_REASON).
//
// This module is a pure classifier. It never touches the network, the page or
// the native bridge; the caller decides what to do with the decision.

export const BrowserDecision = Object.freeze({
  Allow: 'allow',
  Prompt: 'prompt',
  Forbid: 'forbid',
});

// How much a page operation can affect the outside world. `read` cannot change
// page state; `mutate` changes local form state; `external` can submit a form,
// navigate, or otherwise leave the current page (mirrors Codex's split between
// harmless and dangerous commands).
export const OPERATION_IMPACT = Object.freeze({
  observe: 'read',
  scroll: 'read',
  fill: 'mutate',
  type: 'mutate',
  select: 'mutate',
  // Enter on a form control may submit it; treat keys as externally visible.
  press: 'external',
  click: 'external',
  navigate: 'external',
  open: 'external',
});

const DANGEROUS_SCHEMES = new Set(['javascript:', 'data:', 'file:', 'blob:', 'filesystem:', 'about:']);

// Return a human-readable reason when the request is dangerous, else null.
// This is the equivalent of Codex's dangerous_command_match: it runs before the
// approval policy is consulted, so a dangerous request can never be Allow.
export function detectDanger(operation, request) {
  if (!request || typeof request !== 'object') return 'malformed request';
  if (operation === 'open') {
    let url;
    try { url = new URL(request.url); } catch { return 'invalid URL'; }
    if (!['http:', 'https:'].includes(url.protocol)) return `scheme ${url.protocol} is not allowed (only http/https)`;
    if (DANGEROUS_SCHEMES.has(url.protocol)) return `scheme ${url.protocol} is not allowed`;
    if (url.username || url.password) return 'URLs carrying credentials are not allowed';
    return null;
  }
  if (operation === 'fill' || operation === 'type' || operation === 'select') {
    // Text arrives pre-encoded by the caller; a missing blob means the caller
    // skipped validation, which must fail closed.
    if (typeof request.text !== 'string' || !request.text) return 'missing encoded text';
    return null;
  }
  if (operation === 'press') {
    if (typeof request.key !== 'string' || !request.key) return 'missing key';
    return null;
  }
  if (operation === 'click') {
    if (typeof request.ref !== 'string' || !/^e\d{1,3}$/.test(request.ref)) return 'invalid element reference';
    return null;
  }
  if (operation === 'navigate') {
    if (!['back', 'forward', 'refresh'].includes(request.action)) return 'invalid navigation action';
    return null;
  }
  if (operation === 'scroll') {
    if (!['up', 'down'].includes(request.direction)) return 'invalid scroll direction';
    return null;
  }
  if (operation === 'observe') return null;
  return `unsupported operation ${operation}`;
}

/**
 * Classify a validated request into Allow / Prompt / Forbid.
 *
 * @param {string} operation
 * @param {object} request  already-normalised request (URL canonicalised, text
 *                          encoded, refs validated)
 * @param {{ preset?: string }} options  the caller's live permission preset
 * @returns {{ decision: string, reason: string }}
 */
export function classifyOperation(operation, request, { preset = '' } = {}) {
  const impact = OPERATION_IMPACT[operation];
  if (!impact) return { decision: BrowserDecision.Forbid, reason: `unsupported operation ${operation}` };

  const danger = detectDanger(operation, request);
  if (danger) {
    // Invariant 1: danger is never silently allowed. Only a preset that the
    // user explicitly marked as full access may even ask; everything else is
    // rejected outright with a concrete reason.
    if (preset === 'danger-full-access') {
      return { decision: BrowserDecision.Prompt, reason: `dangerous request requires confirmation: ${danger}` };
    }
    return { decision: BrowserDecision.Forbid, reason: `dangerous request rejected: ${danger}` };
  }

  if (impact === 'read') {
    // Reading cannot change page or outside state. In the isolated instance it
    // is safe to allow without a prompt (Codex allows non-dangerous commands
    // inside a restricted sandbox without asking).
    return { decision: BrowserDecision.Allow, reason: 'read-only operation in isolated instance' };
  }

  // mutate/external operations stay Prompt under every preset except full
  // access, where the user has explicitly opted out of confirmations.
  if (preset === 'auto' || preset === 'danger-full-access') {
    return { decision: BrowserDecision.Allow, reason: `${impact} operation allowed by ${preset} preset` };
  }
  return { decision: BrowserDecision.Prompt, reason: `${impact} operation requires confirmation` };
}
