import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { Message, Settings, ToolDefinition, Transport } from '../core/Types';
import { SSEParser, CompletionBuilder } from '../core/Stream';

interface Thinking { type: string }
interface RequestBody { model: string; messages: Message[]; tools: ToolDefinition[]; stream: boolean; max_tokens: number; thinking: Thinking }

export class DeepSeek implements Transport {
  private request?: http.HttpRequest;
  private rejectActive?: (error: Error) => void;
  private settings: Settings;
  private key: string;
  constructor(settings: Settings, key: string) { this.settings = settings; this.key = key; }
  cancel(): void {
    if (this.rejectActive) { this.rejectActive(new Error('已停止')); }
  }
  complete(messages: Message[], tools: ToolDefinition[], onDelta: (message: Message) => void): Promise<Message> {
    const base = this.settings.endpoint.replace(/\/+$/, '');
    if (!/^https:\/\/[^\s@?#]+$/.test(base)) { return Promise.reject(new Error('模型地址必须是有效的 HTTPS 基础地址')); }
    const body: RequestBody = {
      model: this.settings.model, messages: messages, tools: tools, stream: true,
      max_tokens: 8192, thinking: { type: this.settings.thinking ? 'enabled' : 'disabled' }
    };
    return new Promise<Message>((resolve, reject) => {
      const req = http.createHttp();
      this.request = req;
      const decoder = util.TextDecoder.create('utf-8');
      const builder = new CompletionBuilder();
      let finished = false;
      let ended = false;
      let status = 0;
      let received = 0;
      const cleanup = (): void => {
        req.off('dataReceive'); req.off('dataEnd'); req.destroy();
        this.request = undefined; this.rejectActive = undefined;
      };
      const fail = (error: Error): void => {
        if (finished) { return; }
        finished = true; cleanup(); reject(error);
      };
      this.rejectActive = fail;
      const parser = new SSEParser((data: string) => { builder.accept(data); onDelta(builder.message); });
      const settle = (): void => {
        if (finished || !ended || status === 0) { return; }
        if (status < 200 || status >= 300) { fail(new Error('模型服务 HTTP ' + status.toString() + '，请检查地址、密钥、模型和额度')); return; }
        try {
          parser.push(decoder.decodeToString(new Uint8Array(0), { stream: false }));
          parser.finish();
          const result = builder.result(); finished = true; cleanup(); resolve(result);
        } catch (error) { fail(error as Error); }
      };
      req.on('dataReceive', (bytes: ArrayBuffer) => {
        if (finished) { return; }
        try {
          received += bytes.byteLength;
          if (received > 4194304) { throw new Error('模型回复超过 4 MiB'); }
          const text = decoder.decodeToString(new Uint8Array(bytes), { stream: true });
          // Error bodies are not shown or logged; they may echo credentials.
          if (status === 0 || (status >= 200 && status < 300)) { parser.push(text); }
        } catch (error) { fail(error as Error); }
      });
      req.on('dataEnd', () => { ended = true; settle(); });
      req.requestInStream(base + '/chat/completions', {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json', 'Accept': 'text/event-stream', 'Authorization': 'Bearer ' + this.key },
        extraData: JSON.stringify(body), usingCache: false, connectTimeout: 15000, readTimeout: 120000
      }).then((code: number) => { status = code; settle(); }).catch(() => { fail(new Error('网络请求失败，请检查网络或模型配置')); });
    });
  }
}
