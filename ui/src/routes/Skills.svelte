<script>
  // The skill manager (spec SC6, SC12, SC13): where every skill applies, a
  // searchable inventory, and any folder's stack. Right-click a skill for its
  // actions.
  import { onMount } from 'svelte';
  import { api, chooseFolder } from '../lib/api.js';
  import { skillMenu } from '../lib/actions.js';
  import { tilde, last, sourceLabel, harnessLabel, tokens } from '../lib/format.js';
  import Menu from '../components/Menu.svelte';
  import FolderView from '../components/FolderView.svelte';

  let { overview, notify, onchange } = $props();

  let tab = $state('map');
  let data = $state(null);
  let error = $state('');
  let menu = $state(null);

  // Inventory filters.
  let query = $state('');
  let harness = $state('');
  let source = $state('');
  let scope = $state('');
  let dupesOnly = $state(false);
  let sort = $state('name');

  // Folder tab.
  let folder = $state('');
  let persona = $state('');

  async function load() {
    try {
      data = await api.inventory();
      error = '';
    } catch (e) {
      error = String(e);
    }
  }

  onMount(load);

  function changed() {
    load();
    onchange?.();
  }

  const locations = $derived(data?.inventory.locations ?? []);
  const projects = $derived(data?.inventory.projects ?? []);

  /** Location index → its duplicate group. */
  const dupOf = $derived.by(() => {
    const m = new Map();
    for (const g of data?.duplicates ?? []) for (const i of g.locations) m.set(i, g);
    return m;
  });

  function scopeKey(l) {
    return l.scope.kind === 'folder' ? 'project' : l.scope.kind;
  }

  const filtered = $derived.by(() => {
    const q = query.trim().toLowerCase();
    let rows = locations.map((l, i) => ({ l, i })).filter(({ l, i }) => {
      if (q && !`${l.skill.name} ${l.skill.description} ${l.skill.dir}`.toLowerCase().includes(q)) return false;
      if (harness && !l.harnesses.includes(harness)) return false;
      if (source && l.source.kind !== source) return false;
      if (scope && scopeKey(l) !== scope) return false;
      if (dupesOnly && !dupOf.has(i)) return false;
      return true;
    });
    if (sort === 'cost') rows = rows.toSorted((a, b) => b.l.skill.always_on_tokens - a.l.skill.always_on_tokens);
    else rows = rows.toSorted((a, b) => a.l.skill.name.localeCompare(b.l.skill.name));
    return rows;
  });

  function open(e, i) {
    e.preventDefault();
    e.stopPropagation();
    const g = dupOf.get(i);
    const others = g ? g.locations.filter((j) => j !== i).map((j) => locations[j]) : [];
    menu = {
      x: e.clientX,
      y: e.clientY,
      items: skillMenu(locations[i], { personas: overview.personas, others, notify, onchange: changed }),
    };
  }

  // Scope map: everywhere, then each project, per harness lane.
  const lanes = ['claude', 'pi'];
  const everywhere = $derived(
    Object.fromEntries(lanes.map((h) => [h, locations.map((l, i) => ({ l, i })).filter(({ l }) => l.scope.kind === 'everywhere' && l.harnesses.includes(h))])),
  );
  const projectRows = $derived(
    projects
      .filter((p) => !p.other)
      .map((p) => ({
        p,
        lanes: Object.fromEntries(
          lanes.map((h) => [
            h,
            locations.map((l, i) => ({ l, i })).filter(({ l }) => l.scope.kind === 'folder' && l.scope.path === p.path && l.harnesses.includes(h)),
          ]),
        ),
      })),
  );
  const otherProjects = $derived(projects.filter((p) => p.other));
  const libraryLocs = $derived(locations.map((l, i) => ({ l, i })).filter(({ l }) => l.scope.kind === 'library'));
  const accountCount = $derived(locations.filter((l) => l.source.kind === 'account').length);

  function laneTokens(list) {
    return list.reduce((n, { l }) => n + l.skill.always_on_tokens, 0);
  }

  function showFolder(path) {
    folder = path;
    tab = 'folder';
  }

  async function pickFolder() {
    const f = await chooseFolder('Show the skills that load in…');
    if (f) folder = f;
  }
</script>

<header class="page">
  <h1>Skills</h1>
  <div class="tabs" role="tablist">
    <button role="tab" class:on={tab === 'map'} aria-selected={tab === 'map'} onclick={() => (tab = 'map')}>Where they apply</button>
    <button role="tab" class:on={tab === 'all'} aria-selected={tab === 'all'} onclick={() => (tab = 'all')}>All skills</button>
    <button role="tab" class:on={tab === 'folder'} aria-selected={tab === 'folder'} onclick={() => (tab = 'folder')}>A folder</button>
  </div>
</header>

{#if error}
  <div class="card pad bad">{error}</div>
{:else if !data}
  <p class="muted">Reading your skills…</p>
{:else if tab === 'map'}
  <p class="muted lead">
    Each harness reads its global skills everywhere, plus a project's own skills in that project. Library skills apply only
    when you launch with a persona. Right-click a skill for its actions.
  </p>
  {#if accountCount}
    <p class="note" data-testid="account-note">
      {accountCount} skill{accountCount > 1 ? 's come' : ' comes'} from your claude.ai account. They load in Claude Code, claude.ai
      and the desktop chat; manage them in Claude's settings under Capabilities ▸ Skills.
    </p>
  {/if}
  <div class="map">
    <div class="h"></div>
    {#each lanes as h}<div class="h lane-h"><span class="badge {h}">{harnessLabel[h]}</span></div>{/each}
    <div class="h side-h">Library and personas</div>

    <div class="label"><strong>Everywhere</strong><span class="muted">global</span></div>
    {#each lanes as h}
      <div class="lane" data-lane={h} data-testid="lane-{h}">
        {#each everywhere[h] as { l, i } (i)}
          <button class="skill" class:dup={dupOf.has(i)} oncontextmenu={(e) => open(e, i)} onclick={(e) => open(e, i)} title={l.skill.description}
            >{l.skill.name}<small>{sourceLabel(l.source)}</small></button
          >
        {/each}
        <div class="sum muted">{tokens(laneTokens(everywhere[h]))} tokens always on</div>
      </div>
    {/each}
    <div class="side" style="grid-row: span {projectRows.length + 1}">
      {#each overview.personas as p}
        <div class="persona">
          <strong>{p.name}</strong> <span class="muted">+{tokens(p.always_on_tokens)}</span>
          <div class="muted small">{p.skills.join(', ') || 'no skills yet'}</div>
        </div>
      {/each}
      <div class="libs">
        {#each libraryLocs as { l, i } (i)}
          <button class="skill lib" class:dup={dupOf.has(i)} oncontextmenu={(e) => open(e, i)} onclick={(e) => open(e, i)} title={l.skill.description}
            >{l.skill.name}</button
          >
        {/each}
      </div>
    </div>

    {#each projectRows as { p, lanes: pl } (p.path)}
      <div class="label" class:gone={!p.available}>
        <button class="link" onclick={() => showFolder(p.path)} title={p.path} disabled={!p.available}>{last(p.path)}</button>
        <span class="muted small">{tilde(p.path)}{p.available ? '' : ' · not available'}</span>
      </div>
      {#each lanes as h}
        <div class="lane" class:gone={!p.available}>
          {#each pl[h] as { l, i } (i)}
            <button class="skill" class:dup={dupOf.has(i)} oncontextmenu={(e) => open(e, i)} onclick={(e) => open(e, i)} title={l.skill.description}
              >{l.skill.name}</button
            >
          {/each}
        </div>
      {/each}
    {/each}
  </div>
  {#if otherProjects.length}
    <details class="other">
      <summary>Other folders ({otherProjects.length}) — temporary and test folders</summary>
      <ul>
        {#each otherProjects as p}<li class="mono">{tilde(p.path)}</li>{/each}
      </ul>
    </details>
  {/if}
{:else if tab === 'all'}
  <div class="filters row">
    <input type="search" placeholder="Search skills" bind:value={query} aria-label="Search skills" />
    <select bind:value={harness} aria-label="Harness">
      <option value="">Any harness</option>
      <option value="claude">Claude Code</option>
      <option value="pi">Pi</option>
    </select>
    <select bind:value={source} aria-label="Source">
      <option value="">Any source</option>
      <option value="user">Global</option>
      <option value="account">claude.ai account</option>
      <option value="project">Project</option>
      <option value="library">Library</option>
      <option value="plugin">Plugin</option>
      <option value="package">Pi package</option>
    </select>
    <select bind:value={scope} aria-label="Scope">
      <option value="">Anywhere</option>
      <option value="everywhere">Everywhere</option>
      <option value="project">Projects</option>
      <option value="library">Library</option>
    </select>
    <label class="row check"><input type="checkbox" bind:checked={dupesOnly} /> Duplicates only</label>
    <select bind:value={sort} aria-label="Sort">
      <option value="name">By name</option>
      <option value="cost">By cost</option>
    </select>
  </div>
  <table class="card inv">
    <thead><tr><th>Skill</th><th>Source</th><th>Applies</th><th>Harness</th><th class="num">Tokens</th><th></th></tr></thead>
    <tbody>
      {#each filtered as { l, i } (i)}
        <tr oncontextmenu={(e) => open(e, i)} class:dup={dupOf.has(i)} data-testid="inv-row">
          <td>
            <div class="mono name">{l.skill.name}{#if dupOf.has(i)} <span class="badge warn">{dupOf.get(i).identical ? 'duplicate' : 'differs'}</span>{/if}</div>
            <div class="muted small">{l.skill.description}</div>
          </td>
          <td>{sourceLabel(l.source)}{#if l.read_only} <span class="badge ro">read-only</span>{/if}</td>
          <td class="small">{l.scope.kind === 'folder' ? tilde(l.scope.path) : l.scope.kind === 'library' ? 'with a persona' : 'everywhere'}</td>
          <td>{#each l.harnesses as h}<span class="badge {h}">{harnessLabel[h]}</span> {/each}</td>
          <td class="num">{l.skill.always_on_tokens}</td>
          <td><button class="ghost tiny" aria-label="Actions" onclick={(e) => open(e, i)}>⋯</button></td>
        </tr>
      {/each}
    </tbody>
  </table>
  {#if !filtered.length}<p class="muted">No skills match.</p>{/if}
{:else}
  <div class="row filters">
    <select bind:value={folder} aria-label="Folder">
      <option value="">Choose a folder…</option>
      {#each projects.filter((p) => p.available) as p}<option value={p.path}>{tilde(p.path)}</option>{/each}
      {#if folder && !projects.some((p) => p.path === folder)}<option value={folder}>{tilde(folder)}</option>{/if}
    </select>
    <button onclick={pickFolder}>Browse…</button>
    <select bind:value={persona} aria-label="Persona">
      <option value="">No persona</option>
      {#each overview.personas as p}<option value={p.name}>{p.name}</option>{/each}
    </select>
  </div>
  {#if folder}
    <FolderView {folder} {persona} {overview} {notify} onchange={changed} />
  {:else}
    <p class="muted">Choose a folder to see exactly what each harness loads there.</p>
  {/if}
{/if}
<Menu bind:menu />

<style>
  .page {
    display: flex;
    align-items: center;
    gap: 20px;
    margin-bottom: 14px;
  }
  .tabs {
    display: flex;
    gap: 4px;
    background: var(--surface-2);
    padding: 3px;
    border-radius: 9px;
  }
  .tabs button {
    border: 0;
    background: transparent;
    padding: 5px 12px;
  }
  .tabs button.on {
    background: var(--surface);
    box-shadow: var(--shadow);
    color: var(--accent);
  }
  .lead {
    margin: 0 0 12px;
    max-width: 760px;
  }
  .note {
    margin: 0 0 12px;
    padding: 8px 12px;
    border-radius: 8px;
    background: var(--surface-2);
    font-size: 13px;
    max-width: 760px;
  }
  .map {
    display: grid;
    grid-template-columns: minmax(150px, 0.8fr) 1fr 1fr minmax(200px, 0.9fr);
    gap: 8px;
    align-items: start;
  }
  .h {
    font-size: 12px;
    font-weight: 650;
    color: var(--ink-3);
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }
  .label {
    display: flex;
    flex-direction: column;
    padding: 8px 4px;
    min-width: 0;
  }
  .label .small {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .lane {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    padding: 8px;
    min-height: 44px;
    border-radius: var(--radius);
    background: var(--surface);
    border: 1px solid var(--line);
  }
  .sum {
    width: 100%;
    font-size: 12px;
  }
  .side {
    padding: 10px;
    border-radius: var(--radius);
    background: var(--accent-soft);
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .persona .small {
    font-size: 12px;
  }
  .libs {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    border-top: 1px solid var(--line);
    padding-top: 8px;
  }
  .skill {
    display: inline-flex;
    flex-direction: column;
    align-items: flex-start;
    padding: 3px 9px;
    font-size: 13px;
    border-radius: 7px;
    line-height: 1.25;
  }
  .skill small {
    font-size: 10.5px;
    color: var(--ink-3);
  }
  .skill.dup {
    border-color: var(--amber);
    background: var(--amber-soft);
  }
  .gone {
    opacity: 0.5;
  }
  .link {
    border: 0;
    background: none;
    padding: 0;
    font-weight: 650;
    text-align: left;
    color: var(--ink);
    cursor: pointer;
  }
  .link:hover:not(:disabled) {
    color: var(--accent);
  }
  .other {
    margin-top: 16px;
    color: var(--ink-2);
  }
  .filters {
    gap: 8px;
    margin-bottom: 12px;
    flex-wrap: wrap;
  }
  .filters input[type='search'] {
    min-width: 220px;
  }
  .check {
    gap: 6px;
  }
  .inv {
    width: 100%;
    border-collapse: collapse;
    padding: 0;
  }
  .inv th,
  .inv td {
    text-align: left;
    padding: 8px 10px;
    border-bottom: 1px solid var(--line);
    vertical-align: top;
  }
  .inv th {
    font-size: 12px;
    color: var(--ink-3);
    font-weight: 650;
  }
  .inv tr.dup td:first-child {
    box-shadow: inset 3px 0 0 var(--amber);
  }
  .num {
    text-align: right;
  }
  .name {
    font-weight: 600;
  }
  .small {
    font-size: 12px;
  }
  .tiny {
    padding: 0 8px;
  }
  .pad {
    padding: 14px;
  }
  .bad {
    color: var(--red);
  }
</style>
