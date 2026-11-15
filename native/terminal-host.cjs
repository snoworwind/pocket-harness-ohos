// 终端拥有独立 PTY 与独立 Bash；Agent 引擎仍通过官方 SDK 协议运行。
const pty = require('node-pty');
const readline = require('node:readline');
const shell = pty.spawn(process.env.SHELL, ['--noprofile', '--norc', '-i'], {
  name: 'xterm-256color', cols: 80, rows: 24, cwd: process.argv[2] || process.cwd(), env: process.env,
});
const send = frame => process.stdout.write(JSON.stringify(frame) + '\n');
shell.onData(data => send({ type: 'data', data }));
shell.onExit(event => { send({ type: 'exit', code: event.exitCode, signal: event.signal }); process.exit(event.exitCode); });
const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', line => {
  try {
    const frame = JSON.parse(line);
    if (frame.type === 'input' && typeof frame.data === 'string') shell.write(frame.data);
    else if (frame.type === 'resize' && Number.isInteger(frame.cols) && Number.isInteger(frame.rows)) shell.resize(frame.cols, frame.rows);
  } catch (error) { send({ type: 'error', data: error.message }); }
});
input.on('close', () => shell.kill());
process.on('SIGTERM', () => shell.kill());
