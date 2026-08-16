#!/usr/bin/env node
'use strict';

// aip npm bin shim.
//
//   aip install | aip update  Run the platform installer bundled with this
//                             package (copies aip.sh/aip.ps1 into the user
//                             install root and marks the shell profile).
//   aip <anything else>       One-shot: dot-source the packaged aip script and
//                             call the aip shell function, no install needed.

const { spawnSync } = require('node:child_process');
const path = require('node:path');

const root = path.join(__dirname, '..');
const args = process.argv.slice(2);

if (args.length === 1 && (args[0] === '--version' || args[0] === '-v')) {
  args[0] = 'version';
}

function fail(message) {
  console.error(`aip: ${message}`);
  return 1;
}

function run(command, argv) {
  const result = spawnSync(command, argv, { stdio: 'inherit' });
  if (result.error) {
    if (result.error.code === 'ENOENT') return fail(`${command} was not found on PATH`);
    return fail(result.error.message);
  }
  if (result.signal) return result.signal === 'SIGINT' ? 130 : 1;
  return result.status === null ? 1 : result.status;
}

function runInstaller() {
  if (process.platform === 'win32') {
    return run('pwsh', ['-NoProfile', '-File', path.join(root, 'install.ps1')]);
  }
  return run('bash', [path.join(root, 'install.sh')]);
}

function runOneShot() {
  if (process.platform === 'win32') {
    const script = `. '${path.join(root, 'aip.ps1').replace(/'/g, "''")}'; aip @args`;
    return run('pwsh', ['-NoProfile', '-Command', script, ...args]);
  }
  return run('bash', ['-c', '. "$0"; aip "$@"', path.join(root, 'aip.sh'), ...args]);
}

let exitCode;
if (args.length > 0 && (args[0] === 'install' || args[0] === 'update')) {
  exitCode = runInstaller();
} else {
  exitCode = runOneShot();
}
process.exit(exitCode);
