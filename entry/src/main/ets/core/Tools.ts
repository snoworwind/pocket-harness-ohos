import { Approval, Parameters, SchemaProperty, ToolArgs, ToolDefinition, Workspace } from './Types';

export function safePath(path: string, allowRoot: boolean = false): string {
  if (allowRoot && (path === '.' || path === '')) { return ''; }
  if (!path || path.length > 240 || path.startsWith('/') || path.includes('\\') || /[:\x00-\x1f]/.test(path)) {
    throw new Error('只允许工作区内相对路径');
  }
  const parts = path.split('/');
  if (parts.some((part: string) => part === '..' || part === '.' || part === '')) { throw new Error('路径包含非法片段'); }
  return parts.join('/');
}
function definition(name: string, description: string, properties: Record<string, SchemaProperty>, required: string[]): ToolDefinition {
  const parameters: Parameters = { type: 'object', properties: properties, required: required, additionalProperties: false };
  return { type: 'function', function: { name: name, description: description, parameters: parameters } };
}
export function toolDefinitions(): ToolDefinition[] {
  return [
    definition('list_files', '列出当前会话沙箱目录。根目录用 .，返回最多 200 项。', { path: { type: 'string', description: '相对目录' } }, ['path']),
    definition('read_file', '读取当前会话沙箱 UTF-8 文件，最大 64 KiB。', { path: { type: 'string', description: '相对文件路径' } }, ['path']),
    definition('write_file', '创建或覆盖 UTF-8 文件，最大 64 KiB；执行前由用户审核原文和新文。', {
      path: { type: 'string', description: '相对文件路径' }, content: { type: 'string', description: '完整文件内容' }
    }, ['path', 'content'])
  ];
}
export class Tools {
  constructor(private workspace: Workspace) {}
  async run(name: string, raw: string, approve: (request: Approval) => Promise<boolean>, cancelled: () => boolean): Promise<string> {
    if (cancelled()) { throw new Error('已停止'); }
    const args = JSON.parse(raw) as ToolArgs;
    if (!args || typeof args.path !== 'string') { throw new Error('缺少字符串 path'); }
    const path = safePath(args.path, name === 'list_files');
    if (name === 'list_files') { return this.workspace.list(path); }
    if (name === 'read_file') { return this.workspace.read(path); }
    if (name !== 'write_file') { throw new Error('不支持的工具'); }
    if (typeof args.content !== 'string' || args.content.length > 65536) { throw new Error('content 无效或超过限制'); }
    // Read failures must not be mistaken for a missing file by the adapter.
    let before = await this.workspace.read(path);
    if (before === '__HARNESS_FILE_NOT_FOUND__') { before = '（新文件）'; }
    const accepted = await approve({ name: name, path: path, before: before, after: args.content });
    if (cancelled()) { throw new Error('已停止'); }
    if (!accepted) { return '用户拒绝写入。不要换路径或工具重试，先询问用户。'; }
    return this.workspace.write(path, args.content);
  }
}
