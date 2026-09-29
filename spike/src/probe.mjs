// Ask each harness which skills it actually loaded, without a conversation.
//
//   claude - stream-json `system/init` event (killed as soon as it arrives; a
//            tiny request may already be in flight, so this can cost a few
//            tokens on your account)
//   codex  - `codex app-server` JSON-RPC `skills/list` (no model call)
//   pi     - `pi --mode rpc` `get_commands` (no model call)

import { spawn } from 'node:child_process';

// Nested runs inside a Claude Code session would otherwise attach to it.
function childEnv() {
  const env = { ...process.env };
  for (const key of Object.keys(env)) {
    if (key === 'CLAUDECODE' || (key.startsWith('CLAUDE_CODE_') && key !== 'CLAUDE_CODE_OAUTH_TOKEN')) delete env[key];
  }
  return env;
}

function jsonLines(child, onMessage) {
  let buf = '';
  child.stdout.on('data', chunk => {
    buf += chunk;
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i).trim();
      buf = buf.slice(i + 1);
      if (!line) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }
      onMessage(msg);
    }
  });
}

function run(command, args, cwd, { input, onMessage, timeoutMs = 60000 }) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, args, { cwd, env: childEnv(), stdio: ['pipe', 'pipe', 'pipe'], shell: process.platform === 'win32' });
    let stderr = '';
    let settled = false;
    const finish = (err, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.kill('SIGKILL');
      if (err) reject(err);
      else resolvePromise(value);
    };
    const timer = setTimeout(() => finish(new Error(`${command} did not answer within ${timeoutMs / 1000}s\n${stderr.slice(-800)}`)), timeoutMs);
    child.on('error', err => finish(new Error(`cannot run ${command}: ${err.message}`)));
    child.on('exit', code => finish(new Error(`${command} exited (${code}) before answering\n${stderr.slice(-800)}`)));
    child.stderr.on('data', c => { stderr += c; });
    jsonLines(child, msg => onMessage(msg, child, value => finish(null, value), err => finish(err)));
    for (const m of input || []) child.stdin.write(`${JSON.stringify(m)}\n`);
  });
}

export async function probeClaude(args, cwd) {
  return run('claude', ['-p', '.', '--output-format', 'stream-json', '--verbose', ...args], cwd, {
    onMessage: (msg, _child, done) => {
      if (msg.type === 'system' && msg.subtype === 'init') {
        done({ skills: msg.skills.map(name => ({ name, enabled: true })), plugins: msg.plugins?.map(p => p.name) || [] });
      }
    },
  });
}

export async function probeCodex(args, cwd) {
  // app-server rejects --profile but accepts -c overrides.
  return run('codex', [...args, 'app-server'], cwd, {
    input: [{ id: 1, method: 'initialize', params: { clientInfo: { name: 'aipx', version: '0' } } }],
    onMessage: (msg, child, done, fail) => {
      if (msg.id === 1) {
        child.stdin.write(`${JSON.stringify({ method: 'initialized' })}\n`);
        child.stdin.write(`${JSON.stringify({ id: 2, method: 'skills/list', params: { cwds: [cwd], forceReload: true } })}\n`);
      } else if (msg.id === 2) {
        if (msg.error) return fail(new Error(`codex skills/list: ${JSON.stringify(msg.error)}`));
        const skills = msg.result.data.flatMap(e => e.skills)
          .filter(s => s.scope !== 'system')
          .map(s => ({ name: s.name, enabled: s.enabled, path: s.path }));
        done({ skills });
      }
    },
  });
}

export async function probePi(args, cwd) {
  return run('pi', ['--mode', 'rpc', '--offline', ...args], cwd, {
    input: [{ id: '1', type: 'get_commands' }],
    onMessage: (msg, _child, done, fail) => {
      if (msg.id !== '1') return;
      if (!msg.success) return fail(new Error(`pi get_commands: ${msg.error || 'failed'}`));
      const skills = msg.data.commands
        .filter(c => c.source === 'skill')
        .map(c => ({ name: c.name.replace(/^skill:/, ''), enabled: true, path: c.sourceInfo?.path }));
      done({ skills });
    },
  });
}

export const PROBES = { claude: probeClaude, codex: probeCodex, pi: probePi };

// expect: [{ name, present: boolean }]
export function compare(found, expect) {
  const on = new Set(found.skills.filter(s => s.enabled).map(s => s.name));
  return expect.map(e => ({ ...e, ok: on.has(e.name) === e.present }));
}
