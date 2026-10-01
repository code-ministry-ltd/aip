// Fixture backend: the same JSON shapes the Tauri commands return, for
// `vite dev` in a browser and for component tests.

const H = '/Users/jim';
const lib = `${H}/agent-personas/library/skills`;

const skill = (name, dir, description, tokens = 8, hash = name) => ({
  name,
  dir,
  description,
  model_hidden: false,
  always_on_tokens: tokens,
  body_tokens: tokens * 6,
  hash,
});

const loc = (s, scope, source, harnesses, root) => ({
  skill: s,
  scope,
  source,
  harnesses,
  read_only: ['account', 'plugin', 'package'].includes(source.kind),
  root,
});

const everywhere = { kind: 'everywhere' };
const library = { kind: 'library' };
const shop = `${H}/code/shop`;

export const fixtures = {
  overview: {
    home: H,
    root: `${H}/agent-personas`,
    root_exists: true,
    version: '2.0.0-dev.0',
    harnesses: [
      { name: 'claude', found: true, version: '2.1.285 (Claude Code)' },
      { name: 'pi', found: true, version: '0.99.1' },
    ],
    personas: [
      {
        name: 'coder',
        description: 'Everyday coding',
        skills: ['commit-messages', 'review'],
        always_on_tokens: 34,
        warnings: [],
        error: null,
      },
      {
        name: 'writer',
        description: 'Long-form writing',
        skills: ['prose', 'citations'],
        always_on_tokens: 52,
        warnings: [],
        error: null,
      },
    ],
    library: [
      skill('citations', `${lib}/citations`, 'Check and format citations.', 23),
      skill('commit-messages', `${lib}/commit-messages`, 'Write conventional commit messages.', 25),
      skill('prose', `${lib}/prose`, 'Edit long-form prose for clarity and rhythm.', 29),
      skill('review', `${lib}/review`, 'Review code changes.', 9, 'review-a'),
    ],
    recent: [
      { dir: shop, target: 'claude', persona: 'coder' },
      { dir: `${H}/Documents/obsidian-md/research/career`, target: 'pi', persona: 'writer' },
    ],
    settings: { workspaces: [`${H}/code`], update_checks: true },
  },
};

const g = {
  reviewClaude: loc(
    skill('review', `${H}/.claude/skills/review`, 'Review code changes.', 9, 'review-a'),
    everywhere,
    { kind: 'user' },
    ['claude'],
    `${H}/.claude/skills`,
  ),
  docx: loc(
    skill('docx', `${H}/.claude/skills/synced/acct/docx`, 'Work with Word documents.', 31),
    everywhere,
    { kind: 'account' },
    ['claude'],
    `${H}/.claude/skills/synced/acct`,
  ),
  lint: loc(
    skill('lint', `${H}/.claude/plugins/cache/mkt/tools/1.0/skills/lint`, 'Lint the codebase.', 7),
    everywhere,
    { kind: 'plugin', id: 'tools@mkt', enabled: true },
    ['claude'],
    `${H}/.claude/plugins/cache/mkt/tools/1.0/skills`,
  ),
  reviewPi: loc(
    skill('review', `${H}/.agents/skills/review`, 'Review code changes.', 9, 'review-a'),
    everywhere,
    { kind: 'user' },
    ['pi'],
    `${H}/.agents/skills`,
  ),
  web: loc(
    skill('web', `${H}/.pi/agent/npm/node_modules/pi-web-access/skills/web`, 'Search the web.', 12),
    everywhere,
    { kind: 'package', id: 'npm:pi-web-access' },
    ['pi'],
    `${H}/.pi/agent/npm/node_modules/pi-web-access/skills`,
  ),
  testing: loc(
    skill('testing', `${shop}/.claude/skills/testing`, 'Shop testing conventions.', 11, 'testing-shop'),
    { kind: 'folder', path: shop },
    { kind: 'project' },
    ['claude'],
    `${shop}/.claude/skills`,
  ),
  deployShop: loc(
    skill('deploy', `${shop}/.claude/skills/deploy`, 'Deploy the shop.', 6, 'deploy-shop'),
    { kind: 'folder', path: shop },
    { kind: 'project' },
    ['claude'],
    `${shop}/.claude/skills`,
  ),
};

const libLocs = fixtures.overview.library.map((s) => loc(s, library, { kind: 'library' }, [], lib));

fixtures.inventory = {
  inventory: {
    locations: [g.reviewClaude, g.docx, g.lint, g.reviewPi, g.web, ...libLocs, g.testing, g.deployShop],
    projects: [
      { path: shop, origins: ['workspace', 'claude', 'pi'], available: true, other: false },
      { path: `${H}/Documents/obsidian-md/research/career`, origins: ['claude'], available: true, other: false },
      { path: '/Volumes/books/books', origins: ['claude'], available: false, other: false },
      { path: '/private/tmp/fixture', origins: ['claude'], available: true, other: true },
    ],
  },
  duplicates: [{ name: 'review', identical: true, locations: [0, 3, 8] }],
};

function stackFor(harness, persona) {
  const layers = [everywhere, { kind: 'folder', path: shop }];
  if (persona) layers.push({ kind: 'persona', name: persona });
  const p = persona ? layers.length - 1 : -1;
  const personaLoc = (name) => loc(libLocs.find((l) => l.skill.name === name).skill, library, { kind: 'library' }, [harness], lib);
  const rows = [];
  if (harness === 'claude') {
    rows.push({
      name: 'docx',
      copies: [{ layer: 0, location: g.docx, loads: true, loaded_as: 'docx' }],
      loads_twice: false, shadowed: false, identical: true, outcome: 'docx',
    });
    rows.push({
      name: 'lint',
      copies: [{ layer: 0, location: g.lint, loads: true, loaded_as: 'tools:lint' }],
      loads_twice: false, shadowed: false, identical: true, outcome: 'tools:lint',
    });
    if (persona === 'coder') {
      rows.push({
        name: 'commit-messages',
        copies: [{ layer: p, location: personaLoc('commit-messages'), loads: true, loaded_as: 'aip-coder:commit-messages' }],
        loads_twice: false, shadowed: false, identical: true, outcome: 'aip-coder:commit-messages',
      });
    }
    rows.push({
      name: 'review',
      copies: [
        { layer: 0, location: g.reviewClaude, loads: true, loaded_as: 'review' },
        ...(persona === 'coder' ? [{ layer: p, location: personaLoc('review'), loads: true, loaded_as: 'aip-coder:review' }] : []),
      ],
      loads_twice: persona === 'coder', shadowed: false, identical: true,
      outcome: persona === 'coder' ? 'BOTH load (review, aip-coder:review), identical' : 'review',
    });
    rows.push({
      name: 'testing',
      copies: [{ layer: 1, location: g.testing, loads: true, loaded_as: 'testing' }],
      loads_twice: false, shadowed: false, identical: true, outcome: 'testing',
    });
  } else {
    rows.push({
      name: 'review',
      copies: [
        { layer: 0, location: g.reviewPi, loads: true, loaded_as: 'review' },
        ...(persona === 'coder' ? [{ layer: p, location: personaLoc('review'), loads: false, loaded_as: 'review' }] : []),
      ],
      loads_twice: false, shadowed: persona === 'coder', identical: true,
      outcome: persona === 'coder' ? 'global copy loads; persona coder copy ignored' : 'review',
    });
    rows.push({
      name: 'web',
      copies: [{ layer: 0, location: g.web, loads: true, loaded_as: 'web' }],
      loads_twice: false, shadowed: false, identical: true, outcome: 'web',
    });
  }
  const total = rows.flatMap((r) => r.copies.filter((c) => c.loads)).reduce((n, c) => n + c.location.skill.always_on_tokens, 0);
  return { harness, folder: shop, layers, rows, always_on_tokens: total, project_layers_load: harness === 'claude' };
}

export function mock(cmd, args) {
  switch (cmd) {
    case 'ready':
      return Promise.resolve(null);
    case 'overview':
      return Promise.resolve(structuredClone(fixtures.overview));
    case 'inventory':
      return Promise.resolve(structuredClone(fixtures.inventory));
    case 'folder_view':
      return Promise.resolve({
        folder: args.folder,
        stacks: [stackFor('claude', args.persona), stackFor('pi', args.persona)],
        pi_trust: { state: 'ask' },
        applied: null,
      });
    case 'persona_edit':
      return Promise.resolve(
        args.confirm
          ? { kind: 'done', summary: `${args.add ? 'add' : 'remove'} ${args.skill}` }
          : {
              kind: 'preview',
              plan: {
                summary: `${args.add ? 'add' : 'remove'} ${args.skill} ${args.add ? 'to' : 'from'} persona ${args.persona}`,
                preview: [`update personas/${args.persona}.toml`],
                steps: [],
              },
            },
      );
    case 'persona_detail':
      return Promise.resolve({
        name: args.name,
        file: `${H}/agent-personas/personas/${args.name}.toml`,
        description: fixtures.overview.personas.find((p) => p.name === args.name)?.description ?? '',
        skills: [],
        instructions: null,
        mcp_servers: {},
        claude_settings: {},
        pi_args: [],
        warnings: [],
      });
    case 'persona_set':
      return Promise.resolve(
        args.confirm
          ? { kind: 'done', summary: `persona ${args.persona}: ${args.skills.join(', ')}` }
          : {
              kind: 'preview',
              plan: { summary: `persona ${args.persona}`, preview: [`update personas/${args.persona}.toml`], steps: [] },
            },
      );
    case 'persona_create':
    case 'skill_rm':
    case 'skill_cp':
      return Promise.resolve(
        args.confirm
          ? { kind: 'done', summary: cmd }
          : { kind: 'preview', plan: { summary: cmd.replace('_', ' '), preview: ['(preview)'], steps: [] } },
      );
    case 'skill_diff':
      return Promise.resolve('identical\n');
    case 'undo':
      return Promise.resolve(null);
    case 'history':
      return Promise.resolve([{ id: '1', summary: 'add review to persona coder', at: 1790000000, actions: [] }]);
    case 'launch':
      return Promise.resolve({ log: [], notes: [], started: `${args.target} …` });
    case 'pick_context':
      return Promise.resolve({
        dir: args.dir,
        personas: fixtures.overview.personas.map((p) => [p.name, p.description]),
        targets: ['claude', 'pi', 'claude-desktop'],
        last: ['claude', 'coder'],
      });
    case 'sync_now':
      return Promise.resolve({ outcome: 'up_to_date', committed: false });
    case 'integrations':
      return Promise.resolve([]);
    default:
      return Promise.resolve(null);
  }
}
