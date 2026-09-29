// Pure planning: persona + harness -> launch arguments and file operations.
// Nothing here touches the disk; apply.mjs executes the returned ops.
//
// Two modes, both verified against Claude Code 2.1.285, Codex 0.159.1 and
// Pi 0.85.0 (see ../README.md):
//
//   launch  - flags on one harness invocation (terminal apps). Nothing global
//             changes. Codex is the exception: it has no per-launch skill path
//             flag, so its skills are linked into <cwd>/.agents/skills.
//   project - files inside one project directory, which GUI apps (Claude
//             desktop Code tab, Codex app, Pi GUIs) and wrappers read however
//             they were started.

import { readFileSync } from 'node:fs';
import { join } from 'node:path';

export const HARNESSES = ['claude', 'codex', 'pi'];

export function pluginName(persona) {
  return `aip-${persona.name}`;
}

// ---- TOML values for `codex -c key=value` ------------------------------------

const BARE_KEY = /^[A-Za-z0-9_-]+$/;

export function tomlKey(key) {
  return BARE_KEY.test(key) ? key : JSON.stringify(key);
}

// JSON string escapes are a subset of TOML basic-string escapes, so
// JSON.stringify doubles as a TOML string serializer.
export function tomlValue(value) {
  if (typeof value === 'string') return JSON.stringify(value);
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  if (Array.isArray(value)) return `[${value.map(tomlValue).join(', ')}]`;
  if (value && typeof value === 'object') {
    return `{${Object.entries(value).map(([k, v]) => `${tomlKey(k)} = ${tomlValue(v)}`).join(', ')}}`;
  }
  throw new Error(`cannot express ${JSON.stringify(value)} as a TOML value`);
}

// ---- skill selection -----------------------------------------------------------

// Names of globally installed skills this persona hides for one harness.
export function hiddenGlobalSkills(persona, globals) {
  const personaNames = new Set(persona.skills.map(s => s.name));
  if (!persona.inheritGlobalSkills) {
    return [...new Set(globals.map(g => g.name))].filter(n => !personaNames.has(n));
  }
  return [...new Set(persona.excludeSkills)];
}

function linkOps(dir, skills, libraryDir) {
  return [
    { op: 'prune-links', dir, keep: skills.map(s => s.name), ownedTarget: libraryDir },
    ...skills.map(s => ({ op: 'link', path: join(dir, s.name), target: s.dir, ownedTarget: libraryDir })),
  ];
}

// ---- launch mode ---------------------------------------------------------------

export function planLaunch({ persona, harness, cwd, genDir, libraryDir, globals }) {
  switch (harness) {
    case 'claude': return planClaudeLaunch(persona, genDir, libraryDir, globals.claude);
    case 'codex': return planCodexLaunch(persona, cwd, libraryDir, globals.codex);
    case 'pi': return planPiLaunch(persona, globals.pi);
    default: throw new Error(`unknown harness '${harness}' (expected ${HARNESSES.join(', ')})`);
  }
}

function planClaudeLaunch(persona, genDir, libraryDir, globals) {
  const ops = [];
  const args = [];
  const notes = [];
  const base = join(genDir, 'claude');

  // Persona skills ride in a generated inline plugin (--plugin-dir). Claude
  // namespaces them as aip-<persona>:<skill>.
  if (persona.skills.length) {
    const pluginDir = join(base, 'plugin');
    ops.push({
      op: 'write',
      path: join(pluginDir, '.claude-plugin', 'plugin.json'),
      content: `${JSON.stringify({ name: pluginName(persona), description: `aip persona: ${persona.name}` }, null, 2)}\n`,
    });
    ops.push(...linkOps(join(pluginDir, 'skills'), persona.skills, libraryDir));
    args.push('--plugin-dir', pluginDir);
  }

  // Global skills are hidden with skillOverrides in a --settings file, which
  // Claude merges above user/project/local settings for this session only.
  const settings = structuredClone(persona.claude.settings);
  const hidden = hiddenGlobalSkills(persona, globals);
  if (hidden.length) {
    settings.skillOverrides = { ...Object.fromEntries(hidden.map(n => [n, 'off'])), ...settings.skillOverrides };
  }
  if (Object.keys(settings).length) {
    const settingsPath = join(base, 'settings.json');
    ops.push({ op: 'write', path: settingsPath, content: `${JSON.stringify(settings, null, 2)}\n` });
    args.push('--settings', settingsPath);
  }

  if (Object.keys(persona.mcpServers).length) {
    const mcpPath = join(base, 'mcp.json');
    ops.push({ op: 'write', path: mcpPath, content: `${JSON.stringify({ mcpServers: persona.mcpServers }, null, 2)}\n` });
    args.push('--mcp-config', mcpPath);
    notes.push('persona MCP servers are added to the ones you already have; add --strict-mcp-config to use only these');
  }

  if (persona.instructions) args.push('--append-system-prompt-file', persona.instructions);
  notes.push('plugin-provided skills cannot be hidden individually; disable the plugin via [claude.settings] enabledPlugins');
  return { command: 'claude', args, ops, notes };
}

function planCodexLaunch(persona, cwd, libraryDir, globals) {
  const ops = [];
  const args = [];
  const notes = [];

  // Codex has no skill-path flag and ignores project-layer skills.config, but
  // it discovers <cwd>/.agents/skills (trusted or not), so persona skills are
  // linked there and excluded from Git.
  if (persona.skills.length) {
    const dir = join(cwd, '.agents', 'skills');
    ops.push(...linkOps(dir, persona.skills, libraryDir));
    ops.push({ op: 'git-exclude', cwd, paths: persona.skills.map(s => join(dir, s.name)) });
    notes.push(`persona skills are linked into ${dir} (Git-excluded); Pi also sees them there in trusted projects`);
  } else {
    ops.push({ op: 'prune-links', dir: join(cwd, '.agents', 'skills'), keep: [], ownedTarget: libraryDir });
  }

  const config = structuredClone(persona.codex.config);
  const hidden = hiddenGlobalSkills(persona, globals);
  if (hidden.length) {
    config.skills = { ...config.skills };
    config.skills.config = [...hidden.map(name => ({ name, enabled: false })), ...(config.skills.config || [])];
  }
  if (Object.keys(persona.mcpServers).length) {
    config.mcp_servers = { ...persona.mcpServers, ...config.mcp_servers };
  }
  if (persona.instructions) {
    config.developer_instructions = readFileSync(persona.instructions, 'utf8');
  }
  for (const [key, value] of Object.entries(config)) {
    // One -c per top-level key keeps arrays of tables (skills.config) intact.
    if (value && typeof value === 'object' && !Array.isArray(value)) {
      for (const [sub, v] of Object.entries(value)) args.push('-c', `${tomlKey(key)}.${tomlKey(sub)}=${tomlValue(v)}`);
    } else {
      args.push('-c', `${tomlKey(key)}=${tomlValue(value)}`);
    }
  }
  return { command: 'codex', args, ops, notes };
}

function planPiLaunch(persona, globals) {
  const args = [];
  const notes = [];
  const hidden = new Set(hiddenGlobalSkills(persona, globals));
  // Pi has no per-skill hide flag: turn discovery off and re-add what stays.
  if (hidden.size) {
    args.push('--no-skills');
    for (const g of globals) if (!hidden.has(g.name)) args.push('--skill', g.dir);
  }
  for (const s of persona.skills) args.push('--skill', s.dir);
  if (persona.instructions) args.push('--append-system-prompt', persona.instructions);
  if (Object.keys(persona.mcpServers).length) notes.push('Pi has no built-in MCP support; mcp_servers are ignored for Pi');
  args.push(...persona.pi.args);
  return { command: 'pi', args, ops: [], notes };
}

// ---- project mode --------------------------------------------------------------

// persona === null clears everything aipx put in the project.
export function planProject({ persona, cwd, libraryDir, globals, harnesses = HARNESSES, ownedOverrides = [] }) {
  const ops = [];
  const notes = [];
  const skills = persona ? persona.skills : [];
  const excluded = [];

  if (harnesses.includes('claude')) {
    const dir = join(cwd, '.claude', 'skills');
    ops.push(...linkOps(dir, skills, libraryDir));
    excluded.push(...skills.map(s => join(dir, s.name)));
    const hidden = persona ? hiddenGlobalSkills(persona, globals.claude) : [];
    ops.push({
      op: 'skill-overrides',
      path: join(cwd, '.claude', 'settings.local.json'),
      set: Object.fromEntries(hidden.map(n => [n, 'off'])),
      owned: ownedOverrides,
    });
    if (persona) excluded.push(join(cwd, '.claude', 'settings.local.json'));
  }
  if (harnesses.includes('codex') || harnesses.includes('pi')) {
    const dir = join(cwd, '.agents', 'skills');
    ops.push(...linkOps(dir, skills, libraryDir));
    excluded.push(...skills.map(s => join(dir, s.name)));
    if (persona && (persona.excludeSkills.length || !persona.inheritGlobalSkills)) {
      notes.push('Codex and Pi cannot hide global skills from project config; use `aipx launch` for that');
    }
    if (persona && harnesses.includes('pi')) notes.push('Pi loads project skills only in trusted projects (pi -a, or trust once)');
  }
  ops.push({ op: 'git-exclude', cwd, paths: excluded });
  if (persona?.instructions) notes.push('persona instructions are launch-only; project mode leaves AGENTS.md/CLAUDE.md alone');
  return { ops, notes };
}

// ---- GUI deep links ------------------------------------------------------------

export const GUI_APPS = {
  'claude-desktop': { harnesses: ['claude'], url: dir => `claude://code/new?folder=${encodeURIComponent(dir)}` },
  'codex-app': { harnesses: ['codex'], url: dir => `codex://threads/new?path=${encodeURIComponent(dir)}` },
};
