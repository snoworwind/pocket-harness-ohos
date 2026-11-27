// Explicitly constructed transport only: importing this module registers no tools.
import net from 'node:net';
import { randomBytes } from 'node:crypto';
import { TextDecoder } from 'node:util';

const exact = (o, keys) => o && typeof o === 'object' && !Array.isArray(o) && Object.keys(o).length === keys.length && keys.every(k => Object.hasOwn(o, k));
const failure = (code, message) => Object.assign(new Error(message), { code });
const bytes = s => Buffer.byteLength(s, 'utf8');

/** Connect once to a privately delivered relay ready frame. No reconnect or retry. */
export function connectRelay({ host, port, credential, sessionId, signal } = {}) {
  if (host !== '127.0.0.1' || !Number.isInteger(port) || port < 1 || port > 65535 || typeof credential !== 'string' || !/^[a-f0-9]{64}$/.test(credential) || typeof sessionId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(sessionId)) {
    return Promise.reject(failure('invalid_options', 'Invalid loopback relay credentials'));
  }
  if (signal?.aborted) return Promise.reject(failure('aborted', 'Connection aborted'));
  return new Promise((resolve, reject) => {
    const socket = net.createConnection({ host: '127.0.0.1', port });
    let state = 'connecting', active = null, pending = Buffer.alloc(0), count = 0;
    const prefix = randomBytes(16).toString('hex');
    const timer = setTimeout(() => terminate('authentication_failed', 'Relay authentication timed out'), 3000);
    const onAbort = () => terminate('aborted', 'Connection aborted');
    signal?.addEventListener('abort', onAbort, { once: true });
    function terminate(code, message) {
      if (state === 'closed') return;
      const connecting = state === 'connecting';
      state = 'closed'; clearTimeout(timer); signal?.removeEventListener('abort', onAbort);
      socket.destroy();
      if (active) { const item = active; active = null; item.cleanup(); item.reject(failure('unknown', 'Relay disconnected; execution is unknown')); }
      if (connecting) reject(failure(code, message));
    }
    function send(obj) { socket.write(JSON.stringify(obj) + '\n'); }
    const client = {
      request(operation, options = {}) {
        if (state !== 'ready') return Promise.reject(failure('closed', 'Relay is closed'));
        if (active) return Promise.reject(failure('busy', 'A request is already outstanding'));
        if (count >= 10000) return Promise.reject(failure('exhausted', 'Relay request limit reached'));
        if (!options || typeof options !== 'object' || Array.isArray(options)) return Promise.reject(failure('invalid_request', 'Invalid options'));
        const { url, direction, ref, text, key, action, signal: requestSignal, getAutoPermission } = options;
        const allowed = operation === 'open' ? ['url', 'signal', 'getAutoPermission'] :
          operation === 'scroll' ? ['direction', 'signal', 'getAutoPermission'] :
          operation === 'click' || operation === 'hover' ? ['ref', 'signal', 'getAutoPermission'] :
          (operation === 'fill' || operation === 'type' || operation === 'select') ? ['ref', 'text', 'signal', 'getAutoPermission'] :
          operation === 'press' ? ['key', 'signal', 'getAutoPermission'] :
          operation === 'navigate' ? ['action', 'signal', 'getAutoPermission'] :
          operation === 'text' ? ['offset', 'limit', 'signal', 'getAutoPermission'] :
          operation === 'observe' ? ['signal', 'getAutoPermission'] : [];
        if (!allowed.length || Object.keys(options).some(key => !allowed.includes(key))) return Promise.reject(failure('invalid_request', 'Invalid operation or options'));
        if (getAutoPermission !== undefined && typeof getAutoPermission !== 'function') return Promise.reject(failure('invalid_request', 'Invalid automatic-approval resolver'));
        if (operation === 'open') {
          let valid = typeof url === 'string' && bytes(url) <= 4096 && !/[\u0000-\u0020\u007f]/.test(url);
          if (valid) { try { const u = new URL(url); valid = ['http:', 'https:'].includes(u.protocol) && !u.username && !u.password; } catch { valid = false; } }
          if (!valid) return Promise.reject(failure('invalid_request', 'Invalid URL'));
        } else if (operation === 'scroll' && (!Object.hasOwn(options, 'direction') || !['up', 'down'].includes(direction))) return Promise.reject(failure('invalid_request', 'Invalid direction'));
        else if ((operation === 'click' || operation === 'hover') && (!Object.hasOwn(options, 'ref') || typeof ref !== 'string' || !/^e\d{1,3}$/.test(ref) || Number(ref.slice(1)) >= 80)) return Promise.reject(failure('invalid_request', 'Invalid element reference'));
        else if ((operation === 'fill' || operation === 'type' || operation === 'select') &&
          (typeof ref !== 'string' || !/^e\d{1,3}$/.test(ref) || Number(ref.slice(1)) >= 80 ||
            typeof text !== 'string' || !/^[A-Za-z0-9+/]*={0,2}$/.test(text) || text.length > 1536)) return Promise.reject(failure('invalid_request', 'Invalid element reference or encoded text'));
        else if (operation === 'press' && (typeof key !== 'string' || !['Enter', 'Tab', 'Escape', 'Backspace', 'Delete', 'Home', 'End', 'PageUp', 'PageDown', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Space'].includes(key))) return Promise.reject(failure('invalid_request', 'Unsupported key'));
        else if (operation === 'navigate' && !['back', 'forward', 'refresh'].includes(action)) return Promise.reject(failure('invalid_request', 'Invalid navigation action'));
        else if (operation === 'text' && (!Number.isSafeInteger(options.offset) || options.offset < 0 || options.offset > 200000 || !Number.isSafeInteger(options.limit) || options.limit < 1 || options.limit > 8000)) return Promise.reject(failure('invalid_request', 'Invalid text window'));
        if (requestSignal?.aborted) return Promise.reject(failure('aborted', 'Request aborted before dispatch'));
        const id = `${prefix}_${++count}`;
        const frame = operation === 'open' ? { type: 'request', id, sessionId, operation, url } :
          operation === 'scroll' ? { type: 'request', id, sessionId, operation, direction } :
          operation === 'click' || operation === 'hover' ? { type: 'request', id, sessionId, operation, ref } :
          (operation === 'fill' || operation === 'type' || operation === 'select') ? { type: 'request', id, sessionId, operation, ref, text } :
          operation === 'press' ? { type: 'request', id, sessionId, operation, key } :
          operation === 'navigate' ? { type: 'request', id, sessionId, operation, action } :
          operation === 'text' ? { type: 'request', id, sessionId, operation, offset: options.offset, limit: options.limit } :
          { type: 'request', id, sessionId, operation };
        if (bytes(JSON.stringify(frame)) > 8192) return Promise.reject(failure('invalid_request', 'Request frame too large'));
        return new Promise((resolveRequest, rejectRequest) => {
          const abort = () => { if (active?.id === id) { try { send({ type: 'cancel', id }); } finally { terminate('unknown', 'Request aborted'); } } };
          const deadline = setTimeout(() => { if (active?.id === id) terminate('unknown', 'Request timed out'); }, 31000);
          active = { id, resolve: resolveRequest, reject: rejectRequest, cleanup() { clearTimeout(deadline); requestSignal?.removeEventListener('abort', abort); },
            checks: 0, awaitingPolicy: false, getAutoPermission };
          requestSignal?.addEventListener('abort', abort, { once: true });
          try { send(frame); } catch { terminate('unknown', 'Write failed'); }
        });
      },
      close() { terminate('closed', 'Relay closed'); }
    };
    socket.on('connect', () => { try { send({ type: 'hello', version: 1, credential }); } catch { terminate('authentication_failed', 'Relay authentication failed'); } });
    socket.on('error', () => terminate('connection_failed', 'Relay connection failed'));
    socket.on('close', () => terminate('connection_failed', 'Relay connection closed'));
    socket.on('data', chunk => {
      if (state === 'closed') return;
      pending = Buffer.concat([pending, chunk]);
      while (state !== 'closed') {
        const i = pending.indexOf(10);
        if (i < 0) { if (pending.length > 131072) terminate('protocol_error', 'Oversized relay frame'); return; }
        if (!i || i > 131072) { terminate('protocol_error', 'Invalid relay frame'); return; }
        const frame = pending.subarray(0, i); pending = pending.subarray(i + 1);
        let obj;
        try { if (frame.includes(13)) throw Error(); obj = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(frame)); }
        catch { terminate('protocol_error', 'Invalid relay frame'); return; }
        if (state === 'connecting') {
          if (!exact(obj, ['type', 'version']) || obj.type !== 'ready' || obj.version !== 1) { terminate('authentication_failed', 'Invalid relay authentication response'); return; }
          state = 'ready'; clearTimeout(timer); signal?.removeEventListener('abort', onAbort); resolve(client);
        } else {
          const awaitingReceipt = active && active.result !== undefined;
          // The relay may ask up to twice per request whether this call may skip
          // the native confirmation. Answer from the trusted resolver only.
          const policyCheck = active && !active.result && !active.awaitingPolicy && exact(obj, ['type', 'id']) && obj.type === 'policy-check' && obj.id === active.id;
          if (policyCheck) {
            if (active.checks >= 2) { terminate('protocol_error', 'Too many approval checks'); return; }
            active.checks++;
            active.awaitingPolicy = true;
            let automatic = false;
            try { automatic = active.getAutoPermission?.() === true; } catch { automatic = false; }
            if (state !== 'ready' || !active || !active.awaitingPolicy) return;
            active.awaitingPolicy = false;
            try { send({ type: 'policy', id: active.id, automatic }); }
            catch { terminate('unknown', 'Approval reply failed'); }
            continue;
          }
          if (active && active.awaitingPolicy && !awaitingReceipt) { terminate('protocol_error', 'Unexpected frame while awaiting approval check'); return; }
          const validReceived = awaitingReceipt && exact(obj, ['type', 'id']) && obj.type === 'received' && obj.id === active.id;
          const validResult = active && !awaitingReceipt && obj?.type === 'result' && obj.id === active.id && typeof obj.ok === 'boolean' && (obj.ok ? exact(obj, ['type', 'id', 'ok', 'value']) && typeof obj.value === 'string' && bytes(obj.value) <= 65536 : exact(obj, ['type', 'id', 'ok', 'error']) && typeof obj.error === 'string' && bytes(obj.error) <= 65536);
          const validBusy = active && !awaitingReceipt && exact(obj, ['type', 'code', 'id']) && obj.type === 'error' && obj.code === 'busy' && obj.id === active.id;
          if (!validResult && !validBusy && !validReceived) { terminate('protocol_error', 'Invalid relay response'); return; }
          if (validResult) {
            active.result = obj;
            try { send({ type: 'receipt', id: active.id }); }
            catch { terminate('unknown', 'Receipt write failed'); return; }
            continue;
          }
          const item = active; active = null; item.cleanup();
          if (validBusy) item.reject(failure('busy', 'Relay is busy')); else item.resolve(item.result);
        }
      }
    });
  });
}
