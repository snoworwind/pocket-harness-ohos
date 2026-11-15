import { Chunk, Message, ToolCall } from './Types';

// Input is decoded UTF-8 text, not independently decoded network packets.
export class SSEParser {
  private buffer: string = '';
  constructor(private receive: (data: string) => void) {}
  push(text: string): void {
    this.buffer += text;
    if (this.buffer.length > 2097152) { throw new Error('SSE 帧超过 2 MiB'); }
    let end = this.buffer.search(/\r?\n\r?\n/);
    while (end >= 0) {
      const frame = this.buffer.slice(0, end);
      const separator = this.buffer.slice(end).startsWith('\r\n') ? 4 : 2;
      this.buffer = this.buffer.slice(end + separator);
      const data = frame.split(/\r?\n/).filter((line: string) => line.startsWith('data:'))
        .map((line: string) => line.slice(5).replace(/^ /, '')).join('\n');
      if (data.length > 0) { this.receive(data); }
      end = this.buffer.search(/\r?\n\r?\n/);
    }
  }
  finish(): void {
    if (this.buffer.trim().length > 0) { this.push('\n\n'); }
  }
}

export class CompletionBuilder {
  message: Message = { role: 'assistant', content: '', reasoning_content: '' };
  done: boolean = false;
  finishReason: string = '';
  private calls: Map<number, ToolCall> = new Map<number, ToolCall>();
  accept(data: string): void {
    if (data === '[DONE]') { this.done = true; return; }
    const chunk = JSON.parse(data) as Chunk;
    if (chunk.error) { throw new Error('模型返回错误，请检查模型配置与额度'); }
    if (!chunk.choices || chunk.choices.length === 0) { return; }
    const choice = chunk.choices[0];
    if (choice.finish_reason) { this.finishReason = choice.finish_reason; }
    const delta = choice.delta;
    this.message.content += delta.content || '';
    this.message.reasoning_content = (this.message.reasoning_content || '') + (delta.reasoning_content || '');
    for (const part of delta.tool_calls || []) {
      if (!Number.isInteger(part.index) || part.index < 0 || part.index >= 32) { throw new Error('工具调用索引非法'); }
      let call = this.calls.get(part.index);
      if (!call) {
        call = { id: '', type: 'function', function: { name: '', arguments: '' } };
        this.calls.set(part.index, call);
      }
      if (part.id) { call.id += part.id; }
      if (part.function) {
        call.function.name += part.function.name || '';
        call.function.arguments += part.function.arguments || '';
        if (call.function.arguments.length > 131072) { throw new Error('工具参数过大'); }
      }
    }
    if (this.calls.size > 0) {
      const indices = Array.from(this.calls.keys()).sort((a: number, b: number) => a - b);
      const calls: ToolCall[] = [];
      for (const index of indices) { const call = this.calls.get(index); if (call) { calls.push(call); } }
      this.message.tool_calls = calls;
    }
  }
  result(): Message {
    if (!this.done) { throw new Error('连接提前关闭，回复未完成，请重试'); }
    if (this.finishReason === 'length') { throw new Error('模型输出达到上限，请缩小任务后重试'); }
    if (this.finishReason === 'content_filter') { throw new Error('模型未返回可用回复'); }
    const ids: string[] = [];
    for (const call of this.message.tool_calls || []) {
      if (!call.id || !call.function.name || ids.includes(call.id)) { throw new Error('模型返回不完整的工具调用'); }
      ids.push(call.id);
      JSON.parse(call.function.arguments);
    }
    if (!this.message.content && !this.message.tool_calls) { throw new Error('模型回复为空'); }
    return this.message;
  }
}
