// Library, persona and global-skill discovery.
//
// A root holds the skill library and the persona manifests:
//
//   <root>/library/skills/<name>/SKILL.md
//   <root>/personas/<name>.toml
//
// The library deliberately lives outside every harness discovery root, so a
// plain `claude`, `codex` or `pi` launch sees none of it; personas add skills.

import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import { parse as parseToml } from 'smol-toml';

export const NAME_RE = /^[a-z0-9][a-z0-9_-]*$/;

export function defaultRoot() {
  return process.env.AIPX_ROOT ? resolve(process.env.AIPX_ROOT) : join(homedir(), 'agent-personas');
}

export function defaultCache() {
  const base = process.env.XDG_CACHE_HOME || join(homedir(), '.cache');
  return join(base, 'aipx');
}

// Minimal YAML frontmatter reader: `key: value` lines plus folded (`>`) and
// literal (`|`) blocks, which is all SKILL.md name/description need.
export function parseFrontmatter(text) {
  const match = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text);
  if (!match) return {};
  const out = {};
  const lines = match[1].split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const kv = /^([A-Za-z0-9_-]+):\s*(.*)$/.exec(lines[i]);
    if (!kv) continue;
    let [, key, value] = kv;
    if (value === '>' || value === '|' || value === '>-' || value === '|-') {
      const block = [];
      while (i + 1 < lines.length && /^\s+\S/.test(lines[i + 1])) block.push(lines[++i].trim());
      value = block.join(value.startsWith('>') ? ' ' : '\n');
    } else if (/^(["']).*\1$/.test(value)) {
      value = value.slice(1, -1);
    }
    out[key] = value;
  }
  return out;
}

// Rough token estimate (~4 characters per token). Good enough to compare
// personas; the GUI can swap in a real tokenizer later.
export function estimateTokens(text) {
  return Math.ceil((text || '').length / 4);
}

function readSkill(dir, fallbackName) {
  const file = join(dir, 'SKILL.md');
  const text = readFileSync(file, 'utf8');
  const fm = parseFrontmatter(text);
  const name = fm.name || fallbackName;
  const description = fm.description || '';
  return {
    name,
    dir,
    description,
    hidden: fm['disable-model-invocation'] === 'true',
    // What every session pays up front: name + description in the catalog.
    alwaysOnTokens: estimateTokens(`${name}: ${description}`),
    // What a session pays only when the skill is actually read.
    bodyTokens: estimateTokens(text),
  };
}

export function loadLibrary(root) {
  const dir = join(root, 'library', 'skills');
  const skills = new Map();
  if (!existsSync(dir)) return skills;
  for (const entry of readdirSync(dir).sort()) {
    const skillDir = join(dir, entry);
    if (!statSync(skillDir).isDirectory() || !existsSync(join(skillDir, 'SKILL.md'))) continue;
    if (!NAME_RE.test(entry)) throw new Error(`library skill directory '${entry}' is not a valid skill name`);
    const skill = readSkill(skillDir, entry);
    if (skill.name !== entry) {
      throw new Error(`library skill '${entry}' declares name '${skill.name}'; the directory and name must match`);
    }
    skills.set(entry, skill);
  }
  return skills;
}

const PERSONA_KEYS = new Set([
  'description', 'skills', 'exclude_skills', 'inherit_global_skills', 'instructions',
  'mcp_servers', 'claude', 'codex', 'pi',
]);

export function listPersonas(root) {
  const dir = join(root, 'personas');
  if (!existsSync(dir)) return [];
  return readdirSync(dir).filter(f => f.endsWith('.toml')).map(f => f.slice(0, -5)).sort();
}

export function loadPersona(root, name, library) {
  if (!NAME_RE.test(name)) throw new Error(`'${name}' is not a valid persona name`);
  const file = join(root, 'personas', `${name}.toml`);
  if (!existsSync(file)) throw new Error(`no persona '${name}' (expected ${file})`);
  let raw;
  try {
    raw = parseToml(readFileSync(file, 'utf8'));
  } catch (err) {
    throw new Error(`${file}: ${err.message}`);
  }
  for (const key of Object.keys(raw)) {
    if (!PERSONA_KEYS.has(key)) throw new Error(`${file}: unknown key '${key}'`);
  }
  const skills = (raw.skills || []).map(s => {
    const skill = library.get(s);
    if (!skill) throw new Error(`${file}: skill '${s}' is not in the library`);
    return skill;
  });
  let instructions = null;
  if (raw.instructions) {
    instructions = resolve(join(root, 'personas'), raw.instructions);
    if (!existsSync(instructions)) throw new Error(`${file}: instructions file ${instructions} does not exist`);
  }
  return {
    name,
    file,
    description: raw.description || '',
    skills,
    excludeSkills: raw.exclude_skills || [],
    inheritGlobalSkills: raw.inherit_global_skills !== false,
    instructions,
    mcpServers: raw.mcp_servers || {},
    claude: { settings: raw.claude?.settings || {} },
    codex: { config: raw.codex?.config || {} },
    pi: { args: raw.pi?.args || [] },
  };
}

function findSkillDirs(dir, depth, out) {
  if (depth < 0 || !existsSync(dir)) return out;
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries) {
    if (e.name.startsWith('.')) continue; // includes Codex's bundled .system skills
    const p = join(dir, e.name);
    let isDir;
    try {
      isDir = statSync(p).isDirectory();
    } catch {
      continue;
    }
    if (!isDir) continue;
    if (existsSync(join(p, 'SKILL.md'))) {
      try {
        out.push(readSkill(p, e.name));
      } catch {
        /* unreadable skill: the harness will report it */
      }
    } else {
      findSkillDirs(p, depth - 1, out);
    }
  }
  return out;
}

// Skills each harness discovers globally, so a persona can hide them.
// Plugin- and package-provided skills are not included: the harnesses toggle
// those per plugin/package, not per skill.
export function discoverGlobalSkills(home = homedir()) {
  const scan = (...dirs) => dirs.flatMap(d => findSkillDirs(d, 3, []));
  const codexHome = process.env.CODEX_HOME || join(home, '.codex');
  const piDir = process.env.PI_CODING_AGENT_DIR || join(home, '.pi', 'agent');
  return {
    claude: scan(join(process.env.CLAUDE_CONFIG_DIR || join(home, '.claude'), 'skills')),
    codex: scan(join(home, '.agents', 'skills'), join(codexHome, 'skills')),
    pi: scan(join(piDir, 'skills'), join(home, '.agents', 'skills')),
  };
}
