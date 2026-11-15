import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

export class Documents {
  private context: common.UIAbilityContext;
  constructor(context: common.UIAbilityContext) { this.context = context; }
  async importText(): Promise<string | undefined> {
    const viewPicker = new picker.DocumentViewPicker(this.context);
    const selected = await viewPicker.select({ maxSelectNumber: 1, fileSuffixFilters: ['文本文件|.txt,.md,.json,.csv,.ts,.js,.xml,.yaml,.yml'] });
    if (selected.length === 0) { return undefined; }
    const file = fs.openSync(selected[0], fs.OpenMode.READ_ONLY);
    try {
      const stat = fs.statSync(file.fd);
      if (!stat.isFile() || stat.size > 65536) { throw new Error('仅支持不超过 64 KiB 的 UTF-8 文本文件'); }
      const buffer = new ArrayBuffer(stat.size);
      let offset = 0;
      while (offset < stat.size) {
        const part = new ArrayBuffer(stat.size - offset);
        const count = fs.readSync(file.fd, part);
        if (count <= 0) { throw new Error('文件读取未完成'); }
        new Uint8Array(buffer).set(new Uint8Array(part, 0, count), offset);
        offset += count;
      }
      return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(new Uint8Array(buffer));
    } finally { fs.closeSync(file); }
  }
  async exportText(name: string, content: string): Promise<boolean> {
    const viewPicker = new picker.DocumentViewPicker(this.context);
    const selected = await viewPicker.save({ newFileNames: [name] });
    if (selected.length === 0) { return false; }
    const file = fs.openSync(selected[0], fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      const bytes = new util.TextEncoder().encodeInto(content);
      let offset = 0;
      while (offset < bytes.length) {
        const count = fs.writeSync(file.fd, bytes.slice(offset).buffer);
        if (count <= 0) { throw new Error('文件导出未完成'); }
        offset += count;
      }
      fs.fsyncSync(file.fd);
    } finally { fs.closeSync(file); }
    return true;
  }
}
