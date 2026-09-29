#!/usr/bin/env node
// aipx: spike for persona overlays. See ../README.md.

import { createHash } from 'node:crypto';
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { applyOps } from '../src/apply.mjs';
import { runInTerminal, runInline, openUrl, shellQuote } from '../src/launch.mjs';
import { defaultCache, defaultRoot, discoverGlobalSkills, listPersonas, loadLibrary, loadPersona } from '../src/library.mjs';
import { compare, PROBES } from '../src/probe.mjs';
import { GUI_APPS, HARNESSES, hiddenGlobalSkills, planLaunch, planProject, pluginName } from '../src/render.mjs';

const HELP = `aipx - persona overlays for Claude Code, Codex and Pi (spike)

Usage:
  aipx init                                   create a root with example skills and personas
  aipx list                                   library skills and personas, with context cost
  aipx show PERSONA                           what a persona loads, per harness
  aipx launch PERSONA HARNESS [-- ARGS...]    run claude|codex|pi with the persona
  aipx project PERSONA|--clear                write the persona into a project (for GUI apps)
  aipx open PERSONA APP                       project mode, then open claude-desktop|codex-app
  aipx verify PERSONA HARNESS                 ask the harness what it loaded and check it

Options:
  --root DIR        persona root (default: $AIPX_ROOT or ~/agent-personas)
  --dir DIR         project / working directory (default: current directory)
  --harness LIST    project mode only: comma-separated harnesses (default: claude,codex,pi)
  --mode MODE       verify only: launch (default) or project
  --terminal        launch in a new terminal window instead of this one
  --dry-run         print the plan without changing anything
`;

function parseArgs(argv) {
  const opts = { positional: [], passthrough: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--') { opts.passthrough = argv.slice(i + 1); break; }
    if (a === '--dry-run' || a === '--terminal' || a === '--clear' || a === '--help' || a === '-h') opts[a.replace(/^-+/, '')] = true;
    else if (['--root', '--dir', '--harness', '--mode'].includes(a)) {
      if (i + 1 >= argv.length) throw new Error(`${a} needs a value`);
      opts[a.slice(2)] = argv[++i];
    } else if (a.startsWith('-')) throw new Error(`unknown option ${a}`);
    else opts.positional.push(a);
  }
  return opts;
}

function context(opts) {
  const root = resolve(opts.root || defaultRoot());
  const cache = defaultCache();
  const cwd = realpathSync(resolve(opts.dir || process.cwd()));
  return { root, cache, cwd, libraryDir: join(root, 'library', 'skills') };
}

function requireRoot(ctx) {
  if (!existsSync(join(ctx.root, 'library')) && !existsSync(join(ctx.root, 'personas'))) {
    throw new Error(`no persona root at ${ctx.root}; run 'aipx init' or pass --root`);
  }
}

function persona(ctx, name) {
  if (!name) throw new Error('missing PERSONA');
  return loadPersona(ctx.root, name, loadLibrary(ctx.root));
}

function harness(name) {
  if (!HARNESSES.includes(name)) throw new Error(`HARNESS must be one of ${HARNESSES.join(', ')}`);
  return name;
}

function launchPlan(ctx, p, h) {
  return planLaunch({
    persona: p, harness: h, cwd: ctx.cwd, genDir: join(ctx.cache, 'personas', p.name),
    libraryDir: ctx.libraryDir, globals: discoverGlobalSkills(),
  });
}

function projectStateFile(ctx) {
  const id = createHash('sha256').update(ctx.cwd).digest('hex').slice(0, 16);
  return join(ctx.cache, 'projects', `${id}.json`);
}

function readProjectState(ctx) {
  const f = projectStateFile(ctx);
  return existsSync(f) ? JSON.parse(readFileSync(f, 'utf8')) : { ownedOverrides: [] };
}

function projectPlan(ctx, p, harnesses) {
  return planProject({
    persona: p, cwd: ctx.cwd, libraryDir: ctx.libraryDir, globals: discoverGlobalSkills(),
    harnesses, ownedOverrides: readProjectState(ctx).ownedOverrides || [],
  });
}

function applyProject(ctx, p, harnesses, dryRun) {
  const plan = projectPlan(ctx, p, harnesses);
  const state = applyOps(plan.ops, { dryRun });
  if (!dryRun) {
    const f = projectStateFile(ctx);
    mkdirSync(dirname(f), { recursive: true });
    writeFileSync(f, `${JSON.stringify({ cwd: ctx.cwd, persona: p?.name ?? null, ownedOverrides: state.ownedOverrides || [] }, null, 2)}\n`);
  }
  for (const n of plan.notes) console.log(`note: ${n}`);
}

function printNotes(plan) {
  for (const n of plan.notes) console.log(`note: ${n}`);
}

const commands = {
  init(opts) {
    const ctx = context(opts);
    if (existsSync(ctx.root) && readdirSync(ctx.root).length) throw new Error(`${ctx.root} is not empty`);
    const example = join(dirname(fileURLToPath(import.meta.url)), '..', 'example');
    cpSync(example, ctx.root, { recursive: true });
    console.log(`created ${ctx.root}\n  library/skills/  your skill library (outside every harness's discovery roots)\n  personas/        one TOML file per persona`);
  },

  list(opts) {
    const ctx = context(opts);
    requireRoot(ctx);
    const library = loadLibrary(ctx.root);
    console.log(`Library (${ctx.libraryDir})`);
    console.log('  skill                     always-on  on-use');
    for (const s of library.values()) {
      console.log(`  ${s.name.padEnd(24)}  ${String(s.alwaysOnTokens).padStart(7)}t  ${String(s.bodyTokens).padStart(5)}t${s.hidden ? '  (model-hidden)' : ''}`);
    }
    const globals = discoverGlobalSkills();
    console.log('\nGlobally installed (every session pays for these unless a persona hides them)');
    for (const h of HARNESSES) {
      const total = globals[h].reduce((n, s) => n + s.alwaysOnTokens, 0);
      console.log(`  ${h.padEnd(7)} ${String(globals[h].length).padStart(3)} skills  ~${total}t`);
    }
    console.log('\nPersonas');
    for (const name of listPersonas(ctx.root)) {
      try {
        const p = loadPersona(ctx.root, name, library);
        const cost = p.skills.reduce((n, s) => n + s.alwaysOnTokens, 0);
        console.log(`  ${name.padEnd(16)} ${String(p.skills.length).padStart(2)} skills  +${cost}t  ${p.description}`);
      } catch (err) {
        console.log(`  ${name.padEnd(16)} error: ${err.message}`);
      }
    }
  },

  show(opts) {
    const ctx = context(opts);
    requireRoot(ctx);
    const p = persona(ctx, opts.positional[0]);
    const globals = discoverGlobalSkills();
    console.log(`${p.name}: ${p.description}`);
    console.log(`  adds:  ${p.skills.map(s => s.name).join(', ') || '(no skills)'}`);
    for (const h of HARNESSES) {
      const hidden = hiddenGlobalSkills(p, globals[h]);
      const kept = globals[h].filter(g => !hidden.includes(g.name));
      const cost = [...kept, ...p.skills].reduce((n, s) => n + s.alwaysOnTokens, 0);
      console.log(`  ${h.padEnd(7)} hides ${hidden.length}, keeps ${kept.length} global; skill catalog ~${cost}t`);
    }
    if (p.instructions) console.log(`  instructions: ${p.instructions}`);
    if (Object.keys(p.mcpServers).length) console.log(`  mcp: ${Object.keys(p.mcpServers).join(', ')}`);
  },

  launch(opts) {
    const ctx = context(opts);
    requireRoot(ctx);
    const p = persona(ctx, opts.positional[0]);
    const h = harness(opts.positional[1]);
    const plan = launchPlan(ctx, p, h);
    applyOps(plan.ops, { dryRun: opts['dry-run'] });
    printNotes(plan);
    const args = [...plan.args, ...opts.passthrough];
    const line = [plan.command, ...args].map(shellQuote).join(' ');
    if (opts['dry-run']) {
      console.log(`would run (in ${ctx.cwd}): ${line}`);
      return 0;
    }
    if (opts.terminal) {
      runInTerminal(plan.command, args, ctx.cwd);
      console.log(`opened a terminal: ${line}`);
      return 0;
    }
    return runInline(plan.command, args, ctx.cwd);
  },

  project(opts) {
    const ctx = context(opts);
    requireRoot(ctx);
    const harnesses = (opts.harness || HARNESSES.join(',')).split(',').map(harness);
    const p = opts.clear ? null : persona(ctx, opts.positional[0]);
    applyProject(ctx, p, harnesses, opts['dry-run']);
    console.log(p ? `${ctx.cwd} now uses persona ${p.name} for ${harnesses.join(', ')}` : `cleared aipx files from ${ctx.cwd}`);
  },

  open(opts) {
    const ctx = context(opts);
    requireRoot(ctx);
    const p = persona(ctx, opts.positional[0]);
    const app = GUI_APPS[opts.positional[1]];
    if (!app) throw new Error(`APP must be one of ${Object.keys(GUI_APPS).join(', ')}`);
    applyProject(ctx, p, app.harnesses, opts['dry-run']);
    const url = app.url(ctx.cwd);
    if (opts['dry-run']) console.log(`would open ${url}`);
    else {
      openUrl(url);
      console.log(`opened ${url}`);
    }
  },

  async verify(opts) {
    const ctx = context(opts);
    requireRoot(ctx);
    const p = persona(ctx, opts.positional[0]);
    const h = harness(opts.positional[1]);
    const mode = opts.mode || 'launch';
    const globals = discoverGlobalSkills()[h];
    let args = [];
    let prefix = '';
    if (mode === 'launch') {
      const plan = launchPlan(ctx, p, h);
      applyOps(plan.ops, { log: () => {} });
      args = plan.args;
      if (h === 'claude' && p.skills.length) prefix = `${pluginName(p)}:`;
    } else if (mode === 'project') {
      applyProject(ctx, p, [h], false);
      if (h === 'pi') args = ['-a']; // stands in for a project the user has trusted
    } else throw new Error('--mode must be launch or project');

    const hidden = hiddenGlobalSkills(p, globals);
    // Project config cannot hide global skills in Codex or Pi (see README).
    const canHide = mode === 'launch' || h === 'claude';
    const expect = [
      ...p.skills.map(s => ({ name: prefix + s.name, present: true })),
      ...hidden.map(name => ({ name, present: false, known: !canHide })),
    ];
    if (h === 'claude') console.log('note: the Claude probe starts a headless session and stops it at init; it may use a few tokens');
    const found = await PROBES[h](args, ctx.cwd);
    const results = compare(found, expect);
    console.log(`${h} (${mode}) loaded: ${found.skills.filter(s => s.enabled).map(s => s.name).join(', ') || '(none)'}`);
    for (const r of results) {
      const status = r.ok ? 'ok   ' : r.known ? 'limit' : 'FAIL ';
      console.log(`  ${status} ${r.name} ${r.present ? 'loaded' : 'hidden'}${!r.ok && r.known ? ' (not possible in project mode)' : ''}`);
    }
    return results.every(r => r.ok || r.known) ? 0 : 1;
  },
};

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const [cmd, ...rest] = opts.positional;
  if (!cmd || opts.help) {
    process.stdout.write(HELP);
    return 0;
  }
  if (!commands[cmd]) throw new Error(`unknown command '${cmd}'\n\n${HELP}`);
  opts.positional = rest;
  return (await commands[cmd](opts)) ?? 0;
}

main().then(code => { process.exitCode = code; }, err => {
  console.error(`aipx: ${err.message}`);
  process.exitCode = 1;
});
