// Executes the ops planned by render.mjs.
//
// Safety rules:
//   - a link is only created where nothing exists, or replaces a link that
//     already points into the library (ownedTarget); real files and foreign
//     links are never touched;
//   - prune only removes links that point into the library;
//   - settings.local.json keeps every key and override aipx did not set.

import { execFileSync } from 'node:child_process';
import {
  existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, readlinkSync, rmSync, rmdirSync, symlinkSync, writeFileSync,
} from 'node:fs';
import { dirname, isAbsolute, relative, resolve, sep } from 'node:path';

function isInside(path, dir) {
  const rel = relative(dir, path);
  return rel === '' || (!rel.startsWith('..') && !isAbsolute(rel));
}

function linkTarget(path) {
  try {
    if (!lstatSync(path).isSymbolicLink()) return null;
  } catch {
    return null;
  }
  return resolve(dirname(path), readlinkSync(path));
}

function isOwnedLink(path, ownedTarget) {
  const target = linkTarget(path);
  return target !== null && isInside(target, ownedTarget);
}

function exists(path) {
  try {
    lstatSync(path);
    return true;
  } catch {
    return false;
  }
}

const BEGIN = '# >>> aipx (managed; do not edit)';
const END = '# <<< aipx';

function gitExclude(cwd, paths, dryRun, log) {
  let top;
  let excludeFile;
  try {
    top = execFileSync('git', ['-C', cwd, 'rev-parse', '--show-toplevel'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    excludeFile = resolve(cwd, execFileSync('git', ['-C', cwd, 'rev-parse', '--git-path', 'info/exclude'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim());
  } catch {
    return; // not a Git work tree: nothing to exclude from
  }
  const current = existsSync(excludeFile) ? readFileSync(excludeFile, 'utf8') : '';
  const start = current.indexOf(BEGIN);
  const end = current.indexOf(END);
  const before = start >= 0 && end > start ? current.slice(0, start) : current;
  const after = start >= 0 && end > start ? current.slice(end + END.length).replace(/^\r?\n/, '') : '';
  const kept = start >= 0 && end > start ? current.slice(start + BEGIN.length, end).split(/\r?\n/).filter(Boolean) : [];
  const toEntry = p => `/${relative(top, p).split(sep).join('/')}`;
  // Keep earlier entries that still exist (another harness or mode wrote them).
  const entries = new Set(kept.filter(e => exists(resolve(top, `.${e}`))));
  for (const p of paths) entries.add(toEntry(p));
  const body = [...entries].sort();
  const block = body.length ? `${BEGIN}\n${body.join('\n')}\n${END}\n` : '';
  const next = `${before.replace(/\n*$/, before ? '\n' : '')}${block}${after}`;
  if (next === current) return;
  log(`exclude ${body.length ? body.join(' ') : '(cleared)'} in ${excludeFile}`);
  if (!dryRun) {
    mkdirSync(dirname(excludeFile), { recursive: true });
    writeFileSync(excludeFile, next);
  }
}

function skillOverrides(op, dryRun, log) {
  let settings = {};
  if (existsSync(op.path)) {
    try {
      settings = JSON.parse(readFileSync(op.path, 'utf8'));
    } catch (err) {
      throw new Error(`${op.path} is not valid JSON (${err.message}); fix it before applying a persona`);
    }
  }
  const overrides = { ...settings.skillOverrides };
  for (const name of op.owned) delete overrides[name];
  const owned = [];
  for (const [name, value] of Object.entries(op.set)) {
    if (name in overrides) {
      if (overrides[name] !== value) log(`keep your own skillOverrides.${name}=${overrides[name]} in ${op.path}`);
      continue;
    }
    overrides[name] = value;
    owned.push(name);
  }
  const next = { ...settings };
  if (Object.keys(overrides).length) next.skillOverrides = overrides;
  else delete next.skillOverrides;
  const changed = JSON.stringify(next) !== JSON.stringify(settings);
  if (!changed) return owned;
  if (!Object.keys(next).length && existsSync(op.path)) {
    log(`remove ${op.path} (only held aipx overrides)`);
    if (!dryRun) rmSync(op.path);
  } else {
    log(`set skillOverrides {${owned.map(k => `${k}: ${op.set[k]}`).join(', ')}} in ${op.path}`);
    if (!dryRun) {
      mkdirSync(dirname(op.path), { recursive: true });
      writeFileSync(op.path, `${JSON.stringify(next, null, 2)}\n`);
    }
  }
  return owned;
}

// Returns state worth remembering (the skillOverrides names aipx owns).
export function applyOps(ops, { dryRun = false, log = console.log } = {}) {
  const state = {};
  for (const op of ops) {
    switch (op.op) {
      case 'write': {
        if (existsSync(op.path) && readFileSync(op.path, 'utf8') === op.content) break;
        log(`write ${op.path}`);
        if (!dryRun) {
          mkdirSync(dirname(op.path), { recursive: true });
          writeFileSync(op.path, op.content);
        }
        break;
      }
      case 'prune-links': {
        if (!existsSync(op.dir)) break;
        for (const entry of readdirSync(op.dir)) {
          const p = resolve(op.dir, entry);
          if (op.keep.includes(entry) || !isOwnedLink(p, op.ownedTarget)) continue;
          log(`unlink ${p}`);
          if (!dryRun) rmSync(p);
        }
        // Tidy the skills folder (and its parent) if pruning emptied them.
        if (!dryRun) {
          for (const d of [op.dir, dirname(op.dir)]) {
            if (readdirSync(d).length) break;
            rmdirSync(d);
          }
        }
        break;
      }
      case 'link': {
        if (linkTarget(op.path) === resolve(op.target)) break;
        if (exists(op.path) && !isOwnedLink(op.path, op.ownedTarget)) {
          throw new Error(`${op.path} already exists and is not an aipx link; move it aside or drop that skill from the persona`);
        }
        log(`link ${op.path} -> ${op.target}`);
        if (!dryRun) {
          if (exists(op.path)) rmSync(op.path);
          mkdirSync(dirname(op.path), { recursive: true });
          // Junctions need no Developer Mode on Windows and are fine for directories.
          symlinkSync(op.target, op.path, process.platform === 'win32' ? 'junction' : 'dir');
        }
        break;
      }
      case 'git-exclude':
        gitExclude(op.cwd, op.paths, dryRun, log);
        break;
      case 'skill-overrides':
        state.ownedOverrides = skillOverrides(op, dryRun, log);
        break;
      default:
        throw new Error(`unknown op ${op.op}`);
    }
  }
  return state;
}
