// 官方 SDK 的换行 JSON-RPC 传输适配；不实现或替代 Agent Loop。
export interface EnginePipe { write(line: string): Promise<void>; close(): void }
export interface EngineEvent { sessionId: string; key: string; kind: string; role: string; text: string; raw: string }
export interface EngineApproval { sessionId: string; toolName: string; callId?: string; reason?: string; arguments: string }
export interface QuestionOption { label: string; description?: string }
export interface EngineQuestion { id: string; question: string; detail?: string; header?: string; options?: QuestionOption[]; multiSelect?: boolean; intent?: QuestionIntent }
export interface QuestionIntent { kind: string; approve?: string; reject?: string }
export interface QuestionRequest { requestId: string; sessionId: string; questions: EngineQuestion[] }
export interface QuestionAnswer { id: string; selected: string[]; custom?: string }
export interface QuestionReply { answers?: QuestionAnswer[]; cancelled?: boolean }
export interface EngineHooks {
  event(event: EngineEvent): void;
  approval(request: EngineApproval): Promise<boolean>;
  question(request: QuestionRequest): Promise<QuestionReply>;
  cancelled(requestId: string): void;
}
interface Pending { resolve(value: Object): void; reject(error: Error): void; timer: ReturnType<typeof setTimeout> | undefined }
interface ApprovalSlot { settle(outcome: string): void }
function asciiJson(value: Object): string {
  return JSON.stringify(value).replace(/[\u007f-\uffff]/g, (ch: string) => '\\u' + ch.charCodeAt(0).toString(16).padStart(4, '0'));
}
function blocks(content: any): string {
  if (!Array.isArray(content)) { return typeof content === 'string' ? content : ''; }
  return content.map((block: any) => {
    if (block.type === 'text') { return String(block.text || ''); }
    if (block.type === 'reasoning' && block.text) { return String(block.text); }
    if (block.type === 'tool-call' || block.type === 'tool_call') { return '↳ ' + block.name + '\n' + JSON.stringify(block.arguments || block.input || ''); }
    if (block.type === 'image') { return '[图片附件]'; }
    return '';
  }).filter(Boolean).join('\n');
}
export class OfficialRpc {
  private nextId: number = 1;
  private buffer: string = '';
  private pending: Map<number, Pending> = new Map();
  private approvals: Set<ApprovalSlot> = new Set();
  private calls: Map<string, string> = new Map();
  private cancelledQuestions: Set<string> = new Set();
  private hostQueue: Promise<void> = Promise.resolve();
  private closed: boolean = false;
  constructor(private pipe: EnginePipe, private hooks: EngineHooks) {}
  request(method: string, params: Object = {}, timeoutMs: number = 30000): Promise<Object> {
    if (this.closed) { return Promise.reject(new Error('官方引擎连接已关闭')); }
    const id = this.nextId++;
    return new Promise<Object>((resolve, reject) => {
      const timer = timeoutMs > 0 ? setTimeout(() => {
        this.pending.delete(id); reject(new Error('官方引擎请求超时：' + method + '。超时不代表回滚，请勿自动重试。'));
      }, timeoutMs) : undefined;
      this.pending.set(id, { resolve: resolve, reject: reject, timer: timer });
      this.pipe.write(asciiJson({ jsonrpc: '2.0', id: id, method: method, params: params }) + '\n').catch((error: Error) => {
        const pending = this.pending.get(id); if (!pending) { return; }
        if (pending.timer) { clearTimeout(pending.timer); }
        this.pending.delete(id); pending.reject(error);
      });
    });
  }
  // 官方引擎只有 shutdown；没有取消单轮的方法，停止只能结束进程后重新 resume。
  async shutdown(): Promise<void> {
    if (this.closed) { return; }
    try { await this.request('shutdown', {}, 3000); } catch (error) { /* 引擎可能已经结束，关闭流程继续。 */ }
    this.dispose('官方引擎已停止');
  }
  receive(text: string): void {
    if (this.closed) { return; }
    this.buffer += text;
    if (this.buffer.length > 16777216) { this.dispose('官方引擎协议帧超过限制'); return; }
    let end = this.buffer.indexOf('\n');
    while (end >= 0) {
      const line = this.buffer.slice(0, end).trim(); this.buffer = this.buffer.slice(end + 1);
      if (line) {
        // 与官方传输一致：无法解析的行不会中止连接，只丢弃该行。
        try { this.frame(JSON.parse(line)); } catch (error) { /* 忽略坏帧 */ }
      }
      end = this.buffer.indexOf('\n');
    }
  }
  private frame(frame: any): void {
    if (!frame || frame.jsonrpc !== '2.0') { return; }
    if (typeof frame.method === 'string') {
      if (frame.id !== undefined) {
        this.hostQueue = this.hostQueue.then(async () => { if (!this.closed) { await this.hostRequest(frame); } });
        this.hostQueue = this.hostQueue.catch((error: Error) => { this.dispose('无法处理引擎请求：' + error.message); });
      } else { this.notification(frame.method, frame.params || {}); }
      return;
    }
    const pending = this.pending.get(frame.id);
    if (!pending) { return; }
    this.pending.delete(frame.id);
    if (pending.timer) { clearTimeout(pending.timer); }
    if (frame.error) { pending.reject(new Error(String(frame.error.message || '官方引擎请求失败'))); }
    else if ('result' in frame) { pending.resolve(frame.result); }
    else { pending.reject(new Error('官方引擎缺少结果')); }
  }
  private async hostRequest(frame: any): Promise<void> {
    let result: Object;
    if (frame.method === 'approval/request') {
      const params = frame.params;
      const outcome = await this.decideApproval({ sessionId: params.sessionId, toolName: params.toolName,
        callId: params.callId, reason: params.reason, arguments: this.calls.get(params.callId) || '（引擎未提供调用参数）' });
      result = { outcome: outcome };
    } else if (frame.method === 'user-question/ask') {
      const params = frame.params as QuestionRequest;
      if (this.cancelledQuestions.has(params.requestId)) { result = { cancelled: true }; }
      else { result = await this.hooks.question(params); }
    } else {
      await this.pipe.write(asciiJson({ jsonrpc: '2.0', id: frame.id, error: { code: -32601, message: '不支持的宿主请求' } }) + '\n'); return;
    }
    // 关闭过程中也要把最后一个宿主回复写完，否则引擎会一直等这个 request。
    try { await this.pipe.write(asciiJson({ jsonrpc: '2.0', id: frame.id, result: result }) + '\n'); }
    catch (error) { /* 连接已经断开，没有可写的通道。 */ }
  }
  // 审批的三种结果都必须回传；连接断开时按 cancelled 结束，避免引擎一直等待。
  private decideApproval(request: EngineApproval): Promise<string> {
    return new Promise<string>((resolve) => {
      const slot: ApprovalSlot = { settle: (outcome: string) => { this.approvals.delete(slot); resolve(outcome); } };
      this.approvals.add(slot);
      this.hooks.approval(request).then((accepted: boolean) => slot.settle(accepted ? 'allowed-once' : 'rejected'))
        .catch(() => slot.settle('cancelled'));
    });
  }
  private notification(method: string, params: any): void {
    if (method === 'user-question.cancelled') {
      this.cancelledQuestions.add(params.requestId); this.hooks.cancelled(params.requestId); return;
    }
    if (method === 'session.status') {
      this.hooks.event({ sessionId: params.sessionId, key: '', kind: method, role: '', text: params.status, raw: JSON.stringify(params) }); return;
    }
    if (method === 'session.query.completed') {
      this.hooks.event({ sessionId: params.sessionId, key: 'query:' + String(params.messageId || ''), kind: method,
        role: '', text: '', raw: JSON.stringify(params) }); return;
    }
    if (method === 'subagent.started' || method === 'subagent.finished') {
      this.hooks.event({ sessionId: String(params.sessionId || ''), key: method + ':' + String(params.agentId || ''),
        kind: method, role: '', text: method === 'subagent.started' ? '子代理已启动' : '子代理已结束', raw: JSON.stringify(params) }); return;
    }
    if (method !== 'session.event' || !params.event) { return; }
    const event = params.event; const data = event.data || {};
    let text = ''; let role = '';
    if (event.type === 'user/message') { role = 'user'; text = blocks(data.content); }
    else if (event.type === 'assistant/message') { role = 'assistant'; text = blocks(data.message?.content); }
    else if (event.type === 'tool/call') {
      role = 'tool'; text = '↳ ' + data.name + '\n' + data.arguments;
      this.calls.set(data.callId, data.arguments);
    } else if (event.type === 'tool/result') { role = 'tool'; text = blocks(data.message?.content); }
    else if (event.type === 'turn/end') { role = ''; text = data.reason && data.reason.kind ? String(data.reason.kind) : ''; }
    this.hooks.event({ sessionId: params.sessionId, key: String(event.seq), kind: event.type, role: role, text: text, raw: JSON.stringify(event) });
  }
  dispose(reason: string = '官方引擎已停止'): void {
    if (this.closed) { return; }
    this.closed = true;
    for (const pending of this.pending.values()) { if (pending.timer) { clearTimeout(pending.timer); } pending.reject(new Error(reason)); }
    this.pending.clear(); this.calls.clear();
    for (const slot of Array.from(this.approvals)) { slot.settle('cancelled'); }
    const finish = (): void => { this.pipe.close(); this.hooks.cancelled('*'); };
    // 先让已排队的宿主回复写完，再关闭传输层。
    this.hostQueue.then(finish).catch(finish);
  }
}
