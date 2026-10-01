<script>
  // Personas: pick library skills with a live always-on budget per harness
  // (T56). Saving rewrites only the skills list, as one undoable change.
  import { onMount, untrack } from 'svelte';
  import { api } from '../lib/api.js';
  import { change } from '../lib/actions.js';
  import { harnessLabel, tilde, tokens } from '../lib/format.js';

  let { overview, notify, onchange } = $props();

  let selected = $state(untrack(() => overview.personas[0]?.name ?? ''));
  let chosen = $state([]);
  let detail = $state(null);
  let inv = $state(null);
  let filter = $state('');
  let creating = $state(false);
  let newName = $state('');
  let newDescription = $state('');

  const persona = $derived(overview.personas.find((p) => p.name === selected));

  onMount(async () => {
    try {
      inv = await api.inventory();
    } catch {
      inv = null;
    }
  });

  // Reset the editor whenever the persona (or its saved skills) changes.
  $effect(() => {
    chosen = persona ? [...persona.skills] : [];
    detail = null;
    if (persona && !persona.error) {
      const name = persona.name;
      api
        .personaDetail(name)
        .then((d) => {
          if (selected === name) detail = d;
        })
        .catch(() => {});
    }
  });

  const library = $derived(overview.library.toSorted((a, b) => a.name.localeCompare(b.name)));
  const byName = $derived(new Map(library.map((s) => [s.name, s])));
  const shown = $derived(
    library.filter((s) => !filter || `${s.name} ${s.description}`.toLowerCase().includes(filter.toLowerCase())),
  );
  const added = $derived(chosen.reduce((n, c) => n + (byName.get(c)?.always_on_tokens ?? 0), 0));
  const dirty = $derived(persona && (chosen.length !== persona.skills.length || chosen.some((c, i) => c !== persona.skills[i])));

  /** Global skills per harness: the baseline every launch pays. */
  const globals = $derived.by(() => {
    const out = { claude: new Map(), pi: new Map() };
    for (const l of inv?.inventory.locations ?? []) {
      if (l.scope.kind !== 'everywhere') continue;
      if (l.source.kind === 'plugin' && !l.source.enabled) continue;
      for (const h of l.harnesses) out[h]?.set(l.skill.name, l);
    }
    return out;
  });

  function baseline(h) {
    let n = 0;
    for (const l of globals[h].values()) n += l.skill.always_on_tokens;
    return n;
  }

  /** What a chosen skill does in each harness when a global copy exists. */
  function clash(name) {
    const out = [];
    if (globals.claude.has(name)) out.push('Claude Code loads both copies');
    if (globals.pi.has(name)) out.push('Pi ignores this copy (its global one wins)');
    return out;
  }

  function harnessTotal(h) {
    // Pi ignores a persona copy when a global skill has the same name.
    const extra = chosen.reduce((n, c) => (h === 'pi' && globals.pi.has(c) ? n : n + (byName.get(c)?.always_on_tokens ?? 0)), 0);
    return baseline(h) + extra;
  }

  function toggle(name) {
    chosen = chosen.includes(name) ? chosen.filter((c) => c !== name) : [...chosen, name];
  }

  async function save() {
    await change((c) => api.personaSet(selected, $state.snapshot(chosen), c), { notify, onchange });
  }

  async function create() {
    const name = newName.trim();
    const r = await change((c) => api.personaCreate(name, newDescription.trim(), c), { notify, onchange });
    if (r?.kind === 'done') {
      creating = false;
      newName = '';
      newDescription = '';
      selected = name;
    }
  }
</script>

<header class="page row">
  <h1>Personas</h1>
  <span class="spacer"></span>
  <button class="primary" onclick={() => (creating = !creating)}>New persona</button>
</header>
<p class="muted lead">
  A persona adds library skills on top of what a harness already loads. You choose one when you launch; otherwise you get the
  harness's usual global and project skills.
</p>

{#if creating}
  <form
    class="card create row"
    onsubmit={(e) => {
      e.preventDefault();
      create();
    }}
  >
    <input placeholder="name, e.g. reviewer" bind:value={newName} aria-label="Persona name" required />
    <input class="grow" placeholder="What it is for" bind:value={newDescription} aria-label="Description" />
    <button class="primary" type="submit" disabled={!newName.trim()}>Create</button>
  </form>
{/if}

<div class="layout">
  <nav class="list">
    {#each overview.personas as p (p.name)}
      <button class:on={p.name === selected} onclick={() => (selected = p.name)}>
        <strong>{p.name}</strong>
        <span class="muted small">{p.error ? 'cannot be read' : `${p.skills.length} skills · +${tokens(p.always_on_tokens)}`}</span>
      </button>
    {/each}
    {#if !overview.personas.length}<p class="muted">No personas yet.</p>{/if}
  </nav>

  {#if persona}
    <section class="editor">
      {#if persona.error}
        <div class="card pad bad">{persona.error}</div>
      {:else}
        <div class="card budget">
          <div>
            <h2>{persona.name}</h2>
            <p class="muted">{persona.description}</p>
          </div>
          <div class="totals">
            <div class="big" data-testid="persona-total">+{tokens(added)}</div>
            <div class="muted small">tokens always on, from this persona</div>
          </div>
          {#if inv}
            <div class="per">
              {#each ['claude', 'pi'] as h}
                <div>
                  <span class="badge {h}">{harnessLabel[h]}</span>
                  <span class="mono">{tokens(baseline(h))} + persona = <strong data-testid="total-{h}">{tokens(harnessTotal(h))}</strong></span>
                </div>
              {/each}
              <div class="muted small">Global skills plus this persona, before any project skills.</div>
            </div>
          {/if}
        </div>

        <div class="row tools">
          <input type="search" placeholder="Filter the library" bind:value={filter} aria-label="Filter the library" />
          <span class="spacer"></span>
          {#if dirty}<button onclick={() => (chosen = [...persona.skills])}>Revert</button>{/if}
          <button class="primary" disabled={!dirty} onclick={save}>Save</button>
        </div>

        <ul class="skills card">
          {#each shown as s (s.name)}
            {@const on = chosen.includes(s.name)}
            <li class:on>
              <label>
                <input type="checkbox" checked={on} onchange={() => toggle(s.name)} />
                <span class="mono name">{s.name}</span>
                <span class="desc muted">{s.description}</span>
                <span class="cost mono">{s.always_on_tokens}</span>
              </label>
              {#if on && clash(s.name).length}
                <div class="clash">Also global: {clash(s.name).join('; ')}.</div>
              {/if}
            </li>
          {/each}
          {#if !library.length}<li class="muted pad">The library is empty. Copy skills in from the Skills screen.</li>{/if}
        </ul>

        {#if detail}
          <div class="card extras">
            <h3>Also in this persona</h3>
            <dl>
              <dt>Instructions</dt>
              <dd>{detail.instructions ? tilde(detail.instructions) : 'none'}</dd>
              <dt>MCP servers</dt>
              <dd>{Object.keys(detail.mcp_servers).join(', ') || 'none'}</dd>
              <dt>Claude settings</dt>
              <dd>{Object.keys(detail.claude_settings).join(', ') || 'none'}</dd>
              <dt>Pi arguments</dt>
              <dd class="mono">{detail.pi_args.join(' ') || 'none'}</dd>
            </dl>
            {#each detail.warnings as w}<p class="warn small">{w}</p>{/each}
            <p class="muted small">These are edited in <span class="mono">{tilde(detail.file)}</span>.</p>
          </div>
        {/if}
      {/if}
    </section>
  {/if}
</div>

<style>
  .page {
    margin-bottom: 6px;
  }
  .lead {
    margin: 0 0 16px;
    max-width: 720px;
  }
  .create {
    padding: 12px;
    gap: 8px;
    margin-bottom: 16px;
  }
  .grow {
    flex: 1;
  }
  .layout {
    display: grid;
    grid-template-columns: 220px 1fr;
    gap: 20px;
    align-items: start;
  }
  .list {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .list button {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    text-align: left;
    border-color: transparent;
    background: transparent;
  }
  .list button.on {
    background: var(--surface);
    border-color: var(--line);
    box-shadow: var(--shadow);
  }
  .small {
    font-size: 12px;
  }
  .budget {
    display: grid;
    grid-template-columns: 1fr auto;
    gap: 10px 20px;
    padding: 16px 18px;
  }
  .budget p {
    margin: 4px 0 0;
  }
  .totals {
    text-align: right;
  }
  .big {
    font-size: 26px;
    font-weight: 750;
    color: var(--accent);
  }
  .per {
    grid-column: 1 / -1;
    display: flex;
    flex-wrap: wrap;
    gap: 6px 22px;
    align-items: center;
    border-top: 1px solid var(--line);
    padding-top: 10px;
  }
  .tools {
    margin: 14px 0 8px;
    gap: 8px;
  }
  .skills {
    list-style: none;
    margin: 0;
    padding: 4px 0;
  }
  .skills li {
    border-bottom: 1px solid var(--line);
  }
  .skills li:last-child {
    border-bottom: 0;
  }
  .skills label {
    display: grid;
    grid-template-columns: auto minmax(120px, 0.6fr) 1fr auto;
    gap: 10px;
    align-items: center;
    padding: 8px 14px;
    cursor: pointer;
  }
  .skills li.on {
    background: var(--accent-soft);
  }
  .name {
    font-weight: 600;
  }
  .desc {
    font-size: 13px;
  }
  .cost {
    color: var(--ink-3);
  }
  .clash {
    padding: 0 14px 8px 40px;
    font-size: 12.5px;
    color: var(--amber);
  }
  .extras {
    margin-top: 16px;
    padding: 14px 18px;
  }
  dl {
    display: grid;
    grid-template-columns: 130px 1fr;
    gap: 4px 12px;
    margin: 10px 0;
  }
  dt {
    color: var(--ink-3);
  }
  dd {
    margin: 0;
  }
  .warn {
    color: var(--amber);
  }
  .pad {
    padding: 14px;
  }
  .bad {
    color: var(--red);
  }
</style>
