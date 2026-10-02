<script>
  // Launch: choose a folder, a harness and (optionally) a persona, see what
  // will load, and start it (T57). Favourites, first in the side panel, start
  // a saved launch in one click; right-click a folder to launch directly.
  import { onMount, untrack } from 'svelte';
  import { api, chooseFolder } from '../lib/api.js';
  import { ask } from '../lib/dialog.svelte.js';
  import { tilde, last, targetLabel, splitArgs, joinArgs } from '../lib/format.js';
  import FolderView from '../components/FolderView.svelte';
  import Menu from '../components/Menu.svelte';

  let { overview, notify, onchange, folder: initial = '' } = $props();

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
  let argText = $state('');
  let favs = $state([]);
  /** The save form: { name, replacing } while open. */
  let saving = $state(null);

  async function loadFavs() {
    try {
      favs = (await api.favourites()) ?? [];
    } catch {
      favs = [];
    }
  }

  onMount(loadFavs);

  onMount(async () => {
    try {
      const inv = await api.inventory();
      projects = inv.inventory.projects.filter((p) => p.available && !p.other);
    } catch {
      projects = [];
    }
  });

  /** The chosen folder (even one from Browse…), recent launches, then known projects. */
  const folders = $derived.by(() => {
    const seen = new Set();
    const out = [];
    if (folder) (seen.add(folder), out.push(folder));
    for (const r of overview.recent) if (!seen.has(r.dir)) (seen.add(r.dir), out.push(r.dir));
    for (const p of projects) if (!seen.has(p.path)) (seen.add(p.path), out.push(p.path));
    return out;
  });

  export async function go(dir = folder, t = target, p = persona, args = t === 'claude-desktop' ? [] : splitArgs(argText)) {
    if (!dir) return notify('Choose a folder first', 'bad');
    busy = true;
    try {
      const r = await api.launch(dir, t, p || null, args);
      const text = [r.started ? `Started ${targetLabel[t]}${p ? ` with ${p}` : ''} in ${last(dir)}` : '', ...r.notes]
        .filter(Boolean)
        .join('\n');
      notify(text || 'Launched', 'good');
      // The launch is now the most recent: refresh the folder list.
      onchange?.();
    } catch (e) {
      notify(String(e), 'bad');
    } finally {
      busy = false;
    }
  }

  const launchFav = (f) => go(f.dir, f.target, f.persona || '', f.args);

  function favLabel(f) {
    return `${targetLabel[f.target]}${f.persona ? ` · ${f.persona}` : ''} · ${last(f.dir)}${f.args.length ? ` · ${joinArgs(f.args)}` : ''}`;
  }

  /** Put a favourite into the form, to tweak and launch or save over it. */
  function loadFav(f, edit = false) {
    folder = f.dir;
    target = f.target;
    persona = f.persona || '';
    argText = joinArgs(f.args);
    saving = edit ? { name: f.name, replacing: f.name } : null;
  }

  function startSave() {
    const p = persona ? ` · ${persona}` : '';
    saving = { name: `${last(folder)} · ${targetLabel[target]}${p}`, replacing: null };
  }

  async function saveFav() {
    const name = saving.name.trim();
    const fav = {
      name,
      dir: folder,
      target,
      persona: persona || null,
      args: target === 'claude-desktop' ? [] : splitArgs(argText),
    };
    try {
      await api.favouriteSave(fav, saving.replacing);
      notify(saving.replacing ? `Saved changes to ${name}` : `Saved favourite ${name}`, 'good');
      saving = null;
      loadFavs();
    } catch (e) {
      notify(String(e), 'bad');
    }
  }

  async function removeFav(f) {
    if (!(await ask({ title: `Delete the favourite “${f.name}”?`, lines: [favLabel(f)], confirmLabel: 'Delete', danger: true, note: '' }))) return;
    try {
      await api.favouriteRemove(f.name);
      loadFavs();
    } catch (e) {
      notify(String(e), 'bad');
    }
  }

  function favMenu(e, f) {
    e.preventDefault();
    e.stopPropagation();
    menu = {
      x: e.clientX,
      y: e.clientY,
      items: [
        { heading: f.name },
        { label: 'Launch', run: () => launchFav(f) },
        { label: 'Open in the form', run: () => loadFav(f) },
        { label: 'Edit or rename…', run: () => loadFav(f, true) },
        { sep: true },
        { label: 'Delete', danger: true, run: () => removeFav(f) },
      ],
    };
  }

  /** Launch ▸ favourites and recent combinations first, then harness ▸ persona. */
  function launchMenu(e, dir) {
    e.preventDefault();
    e.stopPropagation();
    const items = [{ heading: last(dir) }];
    const here = favs.filter((f) => f.dir === dir);
    for (const f of here) items.push({ label: `★ ${f.name}`, run: () => launchFav(f) });
    if (here.length) items.push({ sep: true });
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
    <section aria-label="Favourites">
      <h3>Favourites</h3>
      {#if favs.length}
        <ul>
          {#each favs as f (f.name)}
            <li>
              <button class="fav" onclick={() => launchFav(f)} oncontextmenu={(e) => favMenu(e, f)} title="Launch {f.name} — right-click to edit or delete" disabled={busy}>
                <strong>★ {f.name}</strong>
                <span class="muted small">{favLabel(f)}</span>
              </button>
            </li>
          {/each}
        </ul>
        <p class="muted small">Click to launch; right-click to edit or delete.</p>
      {:else}
        <p class="muted small">None yet. Set up a launch, then “Save as favourite” to start it here in one click.</p>
      {/if}
    </section>
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
    <p class="muted small">Your recent launches and the projects Claude Code knows. Right-click one to launch straight away.</p>
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
      {#if target !== 'claude-desktop'}
        <div class="field">
          <span class="label">Arguments</span>
          <input class="mono" placeholder="optional, e.g. --model opus" bind:value={argText} aria-label="Arguments" />
        </div>
      {/if}
      {#if target === 'claude-desktop'}
        <p class="muted small">
          Claude desktop reads skills from the project folder, so aip links the persona's skills into it (and hides them from
          Git) before opening the app. Remove them later from the preview below.
        </p>
      {/if}
      {#if saving}
        <form
          class="row save"
          onsubmit={(e) => {
            e.preventDefault();
            saveFav();
          }}
        >
          <span class="label">Name</span>
          <input bind:value={saving.name} aria-label="Favourite name" required />
          <button type="button" onclick={() => (saving = null)}>Cancel</button>
          <button class="primary" type="submit" disabled={!saving.name.trim()}>{saving.replacing ? 'Save changes' : 'Save favourite'}</button>
        </form>
      {/if}
      <div class="row">
        <span class="spacer"></span>
        {#if !saving}<button class="ghost" disabled={!folder} onclick={startSave}>☆ Save as favourite</button>{/if}
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
  .folders section {
    margin-bottom: 18px;
  }
  .folders li button.fav:hover:not(:disabled) {
    background: var(--surface);
    border-color: var(--accent);
  }
  .save {
    gap: 8px;
    padding-top: 10px;
    border-top: 1px solid var(--line);
  }
  .save input {
    flex: 1;
  }
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
