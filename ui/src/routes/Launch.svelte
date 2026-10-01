<script>
  // Launch: choose a folder, a harness and (optionally) a persona, see what
  // will load, and start it (T57). Right-click a folder to launch directly.
  import { onMount, untrack } from 'svelte';
  import { api, chooseFolder } from '../lib/api.js';
  import { tilde, last, targetLabel } from '../lib/format.js';
  import FolderView from '../components/FolderView.svelte';
  import Menu from '../components/Menu.svelte';

  let { overview, notify, folder: initial = '' } = $props();

  const targets = ['claude', 'pi', 'claude-desktop'];
  // Start from the most recent launch; a folder in the URL wins.
  const first = untrack(() => overview.recent[0]);
  let folder = $state(untrack(() => initial) || first?.dir || '');
  let target = $state(first?.target || 'claude');
  let persona = $state(first?.persona || '');

  $effect(() => {
    if (initial) folder = initial;
  });
  let projects = $state([]);
  let menu = $state(null);
  let busy = $state(false);

  onMount(async () => {
    try {
      const inv = await api.inventory();
      projects = inv.inventory.projects.filter((p) => p.available && !p.other);
    } catch {
      projects = [];
    }
  });

  const folders = $derived.by(() => {
    const seen = new Set();
    const out = [];
    for (const r of overview.recent) if (!seen.has(r.dir)) (seen.add(r.dir), out.push(r.dir));
    for (const p of projects) if (!seen.has(p.path)) (seen.add(p.path), out.push(p.path));
    return out;
  });

  export async function go(dir = folder, t = target, p = persona) {
    if (!dir) return notify('Choose a folder first', 'bad');
    busy = true;
    try {
      const r = await api.launch(dir, t, p || null);
      const text = [r.started ? `Started ${targetLabel[t]}${p ? ` with ${p}` : ''} in ${last(dir)}` : '', ...r.notes]
        .filter(Boolean)
        .join('\n');
      notify(text || 'Launched', 'good');
    } catch (e) {
      notify(String(e), 'bad');
    } finally {
      busy = false;
    }
  }

  /** Launch ▸ recent combinations first, then harness ▸ persona. */
  function launchMenu(e, dir) {
    e.preventDefault();
    e.stopPropagation();
    const items = [{ heading: last(dir) }];
    const recent = overview.recent.filter((r) => r.dir === dir);
    for (const r of recent) {
      items.push({ label: `${targetLabel[r.target]}${r.persona ? ` · ${r.persona}` : ''} (recent)`, run: () => go(dir, r.target, r.persona) });
    }
    if (recent.length) items.push({ sep: true });
    for (const t of targets) {
      items.push({ heading: targetLabel[t] });
      items.push({ label: 'No persona', run: () => go(dir, t, '') });
      for (const p of overview.personas) if (!p.error) items.push({ label: p.name, run: () => go(dir, t, p.name) });
    }
    items.push({ sep: true });
    items.push({ label: 'Preview here', run: () => (folder = dir) });
    menu = { x: e.clientX, y: e.clientY, items };
  }

  async function browse() {
    const f = await chooseFolder('Launch in…');
    if (f) folder = f;
  }
</script>

<header class="page"><h1>Launch</h1></header>

<div class="layout">
  <aside class="folders">
    <div class="row">
      <h3>Folders</h3>
      <span class="spacer"></span>
      <button class="ghost" onclick={browse}>Browse…</button>
    </div>
    <ul>
      {#each folders as dir (dir)}
        <li>
          <button class:on={dir === folder} onclick={() => (folder = dir)} oncontextmenu={(e) => launchMenu(e, dir)} title={dir}>
            <strong>{last(dir)}</strong>
            <span class="muted small">{tilde(dir)}</span>
          </button>
        </li>
      {/each}
    </ul>
    <p class="muted small">Right-click a folder to launch straight away.</p>
  </aside>

  <section>
    <div class="card choose">
      <div class="field">
        <span class="label">Folder</span>
        <span class="mono" title={folder}>{folder ? tilde(folder) : 'none chosen'}</span>
      </div>
      <div class="field">
        <span class="label">Open in</span>
        <div class="seg" role="radiogroup" aria-label="Open in">
          {#each targets as t}
            <button role="radio" aria-checked={target === t} class:on={target === t} onclick={() => (target = t)}>{targetLabel[t]}</button>
          {/each}
        </div>
      </div>
      <div class="field">
        <span class="label">Persona</span>
        <select bind:value={persona} aria-label="Persona">
          <option value="">None (the usual global and project skills)</option>
          {#each overview.personas as p}<option value={p.name} disabled={!!p.error}>{p.name} — {p.description}</option>{/each}
        </select>
      </div>
      {#if target === 'claude-desktop'}
        <p class="muted small">
          Claude desktop reads skills from the project folder, so aip links the persona's skills into it (and hides them from
          Git) before opening the app. Remove them later from the preview below.
        </p>
      {/if}
      <div class="row">
        <span class="spacer"></span>
        <button class="primary launch" disabled={!folder || busy} onclick={() => go()}>Launch {targetLabel[target]}</button>
      </div>
    </div>

    {#if folder}
      <h3 class="ph">What will load</h3>
      <FolderView {folder} {persona} {overview} {notify} />
    {/if}
  </section>
</div>
<Menu bind:menu />

<style>
  .page {
    margin-bottom: 14px;
  }
  .layout {
    display: grid;
    grid-template-columns: 240px 1fr;
    gap: 22px;
    align-items: start;
  }
  ul {
    list-style: none;
    margin: 8px 0;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  .folders li button {
    width: 100%;
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    text-align: left;
    background: transparent;
    border-color: transparent;
    overflow: hidden;
  }
  .folders li button .small {
    max-width: 100%;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .folders li button.on {
    background: var(--surface);
    border-color: var(--line);
    box-shadow: var(--shadow);
  }
  .small {
    font-size: 12px;
  }
  .choose {
    padding: 16px 18px;
    display: flex;
    flex-direction: column;
    gap: 12px;
  }
  .field {
    display: grid;
    grid-template-columns: 90px 1fr;
    align-items: center;
    gap: 12px;
  }
  .label {
    color: var(--ink-3);
    font-weight: 600;
  }
  .seg {
    display: inline-flex;
    background: var(--surface-2);
    padding: 3px;
    border-radius: 9px;
    gap: 3px;
    justify-self: start;
  }
  .seg button {
    border: 0;
    background: transparent;
    padding: 5px 12px;
  }
  .seg button.on {
    background: var(--surface);
    color: var(--accent);
    box-shadow: var(--shadow);
  }
  .launch {
    padding: 8px 18px;
  }
  .ph {
    margin: 22px 0 10px;
  }
</style>
