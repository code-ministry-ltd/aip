// Starting harnesses: inline, in a separate terminal window, or a GUI app
// through its deep link.

import { spawn, spawnSync } from 'node:child_process';
import { chmodSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export function shellQuote(arg) {
  if (/^[A-Za-z0-9_@%+=:,./-]+$/.test(arg)) return arg;
  return `'${arg.replace(/'/g, `'\\''`)}'`;
}

export function runInline(command, args, cwd) {
  const r = spawnSync(command, args, { cwd, stdio: 'inherit', shell: process.platform === 'win32' });
  if (r.error) throw new Error(`cannot run ${command}: ${r.error.message}`);
  return r.status ?? 1;
}

function onPath(cmd) {
  return spawnSync(process.platform === 'win32' ? 'where' : 'which', [cmd], { stdio: 'ignore' }).status === 0;
}

// Linux terminals, most standard first. Each maps a shell command to argv.
const LINUX_TERMINALS = [
  ['xdg-terminal-exec', c => ['sh', '-c', c]],
  ['x-terminal-emulator', c => ['-e', 'sh', '-c', c]],
  ['ghostty', c => ['-e', 'sh', '-c', c]],
  ['kitty', c => ['sh', '-c', c]],
  ['wezterm', c => ['start', '--', 'sh', '-c', c]],
  ['gnome-terminal', c => ['--', 'sh', '-c', c]],
  ['konsole', c => ['-e', 'sh', '-c', c]],
  ['alacritty', c => ['-e', 'sh', '-c', c]],
  ['xterm', c => ['-e', 'sh', '-c', c]],
];

export function terminalCommand(command, args, cwd, platform = process.platform, available = onPath) {
  const line = `cd ${shellQuote(cwd)} && exec ${[command, ...args].map(shellQuote).join(' ')}`;
  if (platform === 'darwin') {
    // A .command file opens in the user's default terminal app.
    return { kind: 'command-file', script: `#!/bin/sh\n${line}\n` };
  }
  if (platform === 'win32') {
    return { kind: 'spawn', command: 'wt', args: ['-d', cwd, command, ...args] };
  }
  const override = process.env.AIPX_TERMINAL; // e.g. "foot -e"
  if (override) {
    const [term, ...rest] = override.split(' ');
    return { kind: 'spawn', command: term, args: [...rest, 'sh', '-c', line] };
  }
  for (const [term, argv] of LINUX_TERMINALS) {
    if (available(term)) return { kind: 'spawn', command: term, args: argv(line) };
  }
  throw new Error('no terminal emulator found; set AIPX_TERMINAL, e.g. AIPX_TERMINAL="foot -e"');
}

export function runInTerminal(command, args, cwd) {
  const plan = terminalCommand(command, args, cwd);
  if (plan.kind === 'command-file') {
    const file = join(mkdtempSync(join(tmpdir(), 'aipx-')), 'launch.command');
    writeFileSync(file, plan.script);
    chmodSync(file, 0o755);
    spawn('open', [file], { detached: true, stdio: 'ignore' }).unref();
    return;
  }
  spawn(plan.command, plan.args, { cwd, detached: true, stdio: 'ignore' }).unref();
}

export function openUrl(url) {
  const [cmd, args] = process.platform === 'darwin' ? ['open', [url]]
    : process.platform === 'win32' ? ['cmd', ['/c', 'start', '""', url]]
      : ['xdg-open', [url]];
  spawn(cmd, args, { detached: true, stdio: 'ignore' }).unref();
}
