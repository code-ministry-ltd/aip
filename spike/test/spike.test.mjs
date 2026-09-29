import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { applyOps } from '../src/apply.mjs';
import { terminalCommand } from '../src/launch.mjs';
import { loadLibrary, loadPersona, parseFrontmatter } from '../src/library.mjs';
import { planLaunch, planProject, tomlValue } from '../src/render.mjs';

const example = join(dirname(fileURLToPath(import.meta.url)), '..', 'example');
const quiet = { log: () => {} };

function fixture() {
  const base = mkdtempSync(join(tmpdir(), 'aipx-test-'));
  const root = join(base, 'root');
  cpSync(example, root, { recursive: true });
  const cwd = join(base, 'proj');
  mkdirSync(cwd);
  execFileSync('git', ['init', '-q', cwd]);
  const library = loadLibrary(root);
  const libraryDir = join(root, 'library', 'skills');
  const g = (name, dir = join(base, 'global', name)) => ({ name, dir, alwaysOnTokens: 5 });
  const globals = { claude: [g('alpha'), g('beta')], codex: [g('delta')], pi: [g('delta'), g('omega')] };
  return { base, root, cwd, library, libraryDir, globals, genDir: join(base, 'gen') };
}

test('frontmatter: plain, quoted and folded values', () => {
  const fm = parseFrontmatter('---\nname: x\ndescription: >\n  one\n  two\nother: "q"\n---\nbody');
  assert.deepEqual(fm, { name: 'x', description: 'one two', other: 'q' });
});

test('persona validation names the problem', () => {
  const f = fixture();
  writeFileSync(join(f.root, 'personas', 'bad.toml'), 'skills = ["nope"]\n');
  assert.throws(() => loadPersona(f.root, 'bad', f.library), /skill 'nope' is not in the library/);
  writeFileSync(join(f.root, 'personas', 'typo.toml'), 'skils = []\n');
  assert.throws(() => loadPersona(f.root, 'typo', f.library), /unknown key 'skils'/);
});

test('TOML values for codex -c', () => {
  assert.equal(tomlValue([{ name: 'a b', enabled: false }]), '[{name = "a b", enabled = false}]');
  assert.equal(tomlValue({ 'weird key': 'x\n"y"' }), '{"weird key" = "x\\n\\"y\\""}');
});

test('claude launch: inline plugin, settings overrides, instructions', () => {
  const f = fixture();
  const writer = loadPersona(f.root, 'writer', f.library);
  writer.excludeSkills = ['beta'];
  const plan = planLaunch({ persona: writer, harness: 'claude', cwd: f.cwd, genDir: f.genDir, libraryDir: f.libraryDir, globals: f.globals });
  assert.equal(plan.args[0], '--plugin-dir');
  const settings = JSON.parse(plan.ops.find(o => o.path?.endsWith('settings.json')).content);
  assert.deepEqual(settings.skillOverrides, { beta: 'off' });
  assert.ok(plan.args.includes('--append-system-prompt-file'));

  const coder = loadPersona(f.root, 'coder', f.library);
  const lean = planLaunch({ persona: coder, harness: 'claude', cwd: f.cwd, genDir: f.genDir, libraryDir: f.libraryDir, globals: f.globals });
  const leanSettings = JSON.parse(lean.ops.find(o => o.path?.endsWith('settings.json')).content);
  assert.deepEqual(leanSettings.skillOverrides, { alpha: 'off', beta: 'off' });
  assert.equal(leanSettings.disableBundledSkills, true);
  assert.ok(lean.args.includes('--mcp-config'));
});

test('codex launch: project links plus -c overrides', () => {
  const f = fixture();
  const coder = loadPersona(f.root, 'coder', f.library);
  const plan = planLaunch({ persona: coder, harness: 'codex', cwd: f.cwd, genDir: f.genDir, libraryDir: f.libraryDir, globals: f.globals });
  assert.ok(plan.args.includes('skills.config=[{name = "delta", enabled = false}]'));
  assert.ok(plan.args.includes('mcp_servers.fetch={command = "uvx", args = ["mcp-server-fetch"]}'));
  assert.ok(plan.ops.some(o => o.op === 'link' && o.path === join(f.cwd, '.agents', 'skills', 'commit-messages')));
});

test('pi launch: re-adds kept globals after --no-skills', () => {
  const f = fixture();
  const writer = loadPersona(f.root, 'writer', f.library);
  assert.deepEqual(
    planLaunch({ persona: writer, harness: 'pi', cwd: f.cwd, genDir: f.genDir, libraryDir: f.libraryDir, globals: f.globals }).args.filter(a => a === '--no-skills'),
    [],
  );
  writer.excludeSkills = ['omega'];
  const args = planLaunch({ persona: writer, harness: 'pi', cwd: f.cwd, genDir: f.genDir, libraryDir: f.libraryDir, globals: f.globals }).args;
  assert.equal(args[0], '--no-skills');
  assert.ok(args.includes(f.globals.pi[0].dir));
  assert.ok(!args.includes(f.globals.pi[1].dir));
});

test('apply: links, refuses to clobber, prunes only its own links', () => {
  const f = fixture();
  const writer = loadPersona(f.root, 'writer', f.library);
  const dir = join(f.cwd, '.agents', 'skills');
  mkdirSync(join(dir, 'prose'), { recursive: true }); // a real folder the user owns
  const plan = planProject({ persona: writer, cwd: f.cwd, libraryDir: f.libraryDir, globals: f.globals, harnesses: ['codex'] });
  assert.throws(() => applyOps(plan.ops, quiet), /not an aipx link/);

  const f2 = fixture();
  mkdirSync(join(f2.cwd, '.agents', 'skills', 'mine'), { recursive: true });
  const w2 = loadPersona(f2.root, 'writer', f2.library);
  applyOps(planProject({ persona: w2, cwd: f2.cwd, libraryDir: f2.libraryDir, globals: f2.globals, harnesses: ['codex'] }).ops, quiet);
  assert.ok(lstatSync(join(f2.cwd, '.agents', 'skills', 'prose')).isSymbolicLink());
  applyOps(planProject({ persona: null, cwd: f2.cwd, libraryDir: f2.libraryDir, globals: f2.globals, harnesses: ['codex'] }).ops, quiet);
  assert.ok(!existsSync(join(f2.cwd, '.agents', 'skills', 'prose')));
  assert.ok(existsSync(join(f2.cwd, '.agents', 'skills', 'mine')), 'user folder survives');
});

test('apply: settings.local.json keeps user keys and user overrides', () => {
  const f = fixture();
  const coder = loadPersona(f.root, 'coder', f.library);
  const file = join(f.cwd, '.claude', 'settings.local.json');
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, JSON.stringify({ model: 'opus', skillOverrides: { beta: 'name-only' } }));
  const plan = planProject({ persona: coder, cwd: f.cwd, libraryDir: f.libraryDir, globals: f.globals, harnesses: ['claude'] });
  const state = applyOps(plan.ops, quiet);
  assert.deepEqual(state.ownedOverrides, ['alpha']);
  assert.deepEqual(JSON.parse(readFileSync(file, 'utf8')), { model: 'opus', skillOverrides: { beta: 'name-only', alpha: 'off' } });

  const clear = planProject({ persona: null, cwd: f.cwd, libraryDir: f.libraryDir, globals: f.globals, harnesses: ['claude'], ownedOverrides: state.ownedOverrides });
  applyOps(clear.ops, quiet);
  assert.deepEqual(JSON.parse(readFileSync(file, 'utf8')), { model: 'opus', skillOverrides: { beta: 'name-only' } });
});

test('apply: git exclude block is idempotent and keeps user lines', () => {
  const f = fixture();
  const exclude = join(f.cwd, '.git', 'info', 'exclude');
  writeFileSync(exclude, '*.log\n');
  const writer = loadPersona(f.root, 'writer', f.library);
  const plan = planProject({ persona: writer, cwd: f.cwd, libraryDir: f.libraryDir, globals: f.globals, harnesses: ['codex'] });
  applyOps(plan.ops, quiet);
  const once = readFileSync(exclude, 'utf8');
  applyOps(plan.ops, quiet);
  assert.equal(readFileSync(exclude, 'utf8'), once);
  assert.match(once, /^\*\.log\n# >>> aipx[^\n]*\n\/\.agents\/skills\/citations\n\/\.agents\/skills\/prose\n# <<< aipx\n$/);
  applyOps(planProject({ persona: null, cwd: f.cwd, libraryDir: f.libraryDir, globals: f.globals, harnesses: ['codex'] }).ops, quiet);
  assert.equal(readFileSync(exclude, 'utf8'), '*.log\n');
});

test('terminal launch picks a platform strategy', () => {
  assert.equal(terminalCommand('pi', [], '/p', 'darwin').kind, 'command-file');
  assert.deepEqual(terminalCommand('pi', ['-a'], '/p', 'win32'), { kind: 'spawn', command: 'wt', args: ['-d', '/p', 'pi', '-a'] });
  const linux = terminalCommand('claude', ['--settings', 'a b'], '/p', 'linux', t => t === 'kitty');
  assert.deepEqual(linux, { kind: 'spawn', command: 'kitty', args: ['sh', '-c', "cd /p && exec claude --settings 'a b'"] });
});
