export interface FunctionCall { name: string; arguments: string }
export interface ToolCall { id: string; type: string; function: FunctionCall }
export interface Message {
  role: string;
  content: string;
  reasoning_content?: string;
  tool_calls?: ToolCall[];
  tool_call_id?: string;
  eventKey?: string;
}
export interface Session { id: string; title: string; updated: number; messages: Message[]; engineOwned?: boolean }
export interface Settings { endpoint: string; model: string; thinking: boolean; maxRounds: number }
export interface SchemaProperty { type: string; description: string }
export interface Parameters { type: string; properties: Record<string, SchemaProperty>; required: string[]; additionalProperties: boolean }
export interface ToolFunction { name: string; description: string; parameters: Parameters }
export interface ToolDefinition { type: string; function: ToolFunction }
export interface ToolArgs { path?: string; content?: string; query?: string }
export interface Workspace {
  list(path: string): Promise<string>;
  read(path: string): Promise<string>;
  write(path: string, content: string): Promise<string>;
}
export interface Approval { name: string; path: string; before: string; after: string }
export interface Delta { content?: string; reasoning_content?: string; tool_calls?: CallDelta[] }
export interface CallDelta { index: number; id?: string; type?: string; function?: PartialFunction }
export interface PartialFunction { name?: string; arguments?: string }
export interface Choice { delta: Delta; finish_reason?: string }
export interface StreamError { message: string }
export interface Chunk { choices?: Choice[]; error?: StreamError }
export interface Transport {
  complete(messages: Message[], tools: ToolDefinition[], onDelta: (message: Message) => void): Promise<Message>;
  cancel(): void;
}
export interface Hooks {
  changed(): void;
  status(text: string): void;
  approve(request: Approval): Promise<boolean>;
}
export function defaults(): Settings {
  return { endpoint: 'https://api.deepseek.com', model: 'deepseek-v4-pro', thinking: true, maxRounds: 12 };
}
export function newSession(): Session {
  return { id: Date.now().toString(36) + Math.random().toString(36).slice(2, 8), title: '新会话', updated: Date.now(), messages: [] };
}
