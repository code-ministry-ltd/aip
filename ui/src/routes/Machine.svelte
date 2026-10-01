<script>
  // This machine: harness versions, workspace folders, sync, change history
  // and file-manager integrations (T57).
  import { onMount } from 'svelte';
  import { api, chooseFolder } from '../lib/api.js';
  import { ask } from '../lib/dialog.svelte.js';
  import { harnessLabel, tilde } from '../lib/format.js';

  let { overview, notify, onchange } = $props();

  let history = $state([]);
  let integrations = $state([]);
  let sync = $state(null);
  let syncing = $state(false);
  let choices = $state({});

  const settings = $derived(overview.settings);
  const updateChecks = $derived(settings.update_checks !== false);

  async function load() {
    try {
      history = await api.history();
    } catch {
      history = [];
    }
    try {
      integrations = (await api.integrations()) ?? [];
    } catch {
      integrations = [];
    }
  }

  onMount(load);

  async function saveWorkspaces(list, interval = settings.sync_interval_minutes ?? null) {
    try {
      await api.setWorkspaces(list, interval);
      onchange?.();
    } catch (e) {
      notify(String(e), 'bad');
    }
  }

  async function addWorkspace() {
    const f = await chooseFolder('Add a folder that holds your projects');
    if (f && !settings.workspaces.includes(f)) saveWorkspaces([...settings.workspaces, f]);
  }

  function setInterval_(v) {
    saveWorkspaces(settings.workspaces, v ? Number(v) : null);
  }

  async function toggleUpdates() {
    try {
      await api.setUpdateChecks(!updateChecks);
      onchange?.();
    } catch (e) {
      notify(String(e), 'bad');
    }
  }

  const syncText = {
    no_remote: 'This personas repository has no remote, so changes stay on this machine.',
    up_to_date: 'Up to date.',
    pushed: 'Sent this machine’s changes.',
    pulled: 'Fetched changes from your other machines.',
    merged: 'Merged changes from both sides.',
  };

  async function syncNow() {
    syncing = true;
    try {
      sync = await api.syncNow();
      choices = {};
      if (sync.outcome !== 'conflict' && sync.outcome !== 'newer_format') {
        notify(syncText[sync.outcome] ?? sync.outcome, 'good');
        onchange?.();
      }
    } catch (e) {
      notify(String(e), 'bad');
    } finally {
      syncing = false;
    }
  }

  async function resolve() {
    const picked = Object.entries(choices);
    const ok = await ask({
      title: 'Finish the sync',
      lines: picked.map(([f, side]) => `${f}: keep ${side === 'ours' ? 'this machine’s' : 'the other machine’s'} version`),
      confirmLabel: 'Keep these',
      note: '',
    });
    if (!ok) return;
    try {
      sync = await api.syncResolve(picked);
      notify(syncText[sync.outcome] ?? 'Sync finished', 'good');
      onchange?.();
    } catch (e) {
      notify(String(e), 'bad');
    }
  }

  async function undoLast() {
    const what = await api.undo(false);
    if (!what) return notify('Nothing to undo');
    if (!(await ask({ title: `Undo: ${what}?`, confirmLabel: 'Undo', note: '' }))) return;
    try {
      await api.undo(true);
      notify(`Undone: ${what}`, 'good');
      load();
      onchange?.();
    } catch (e) {
      notify(String(e), 'bad');
    }
  }

  async function toggleIntegration(i) {
    try {
      const msg = await api.setIntegration(i.name, !i.enabled);
      if (msg) notify(msg, 'good');
      load();
    } catch (e) {
      notify(String(e), 'bad');
    }
  }

  function when(at) {
    return new Date(at * 1000).toLocaleString();
  }
</script>

<header class="page"><h1>This machine</h1></header>

<div class="grid">
  <section class="card">
    <h2>Harnesses</h2>
    <ul class="plain">
      {#each overview.harnesses as h}
        <li class="row">
          <span class="badge {h.name}">{harnessLabel[h.name] ?? h.name}</span>
          {#if h.found}<span class="mono">{h.version}</span>{:else}<span class="muted">not installed</span>{/if}
        </li>
      {/each}
    </ul>
    <p class="muted small">aip {overview.version} · personas in <span class="mono">{tilde(overview.root)}</span></p>
    <label class="row check">
      <input type="checkbox" checked={updateChecks} onchange={toggleUpdates} />
      Check for aip updates when the app starts
    </label>
  </section>

  <section class="card">
    <h2>Workspace folders</h2>
    <p class="muted small">Folders that hold your projects. aip lists the projects inside them, alongside the ones Claude Code and Pi have seen.</p>
    <ul class="plain">
      {#each settings.workspaces as w}
        <li class="row">
          <span class="mono">{tilde(w)}</span>
          <span class="spacer"></span>
          <button class="ghost" onclick={() => saveWorkspaces(settings.workspaces.filter((x) => x !== w))}>Remove</button>
        </li>
      {/each}
      {#if !settings.workspaces.length}<li class="muted">None yet.</li>{/if}
    </ul>
    <button onclick={addWorkspace}>Add folder…</button>
  </section>

  <section class="card wide">
    <div class="row">
      <h2>Sync</h2>
      <span class="spacer"></span>
      <label class="row check small">
        Sync automatically
        <select value={settings.sync_interval_minutes ?? ''} onchange={(e) => setInterval_(e.currentTarget.value)} aria-label="Sync interval">
          <option value="">never</option>
          <option value="15">every 15 minutes</option>
          <option value="60">every hour</option>
          <option value="240">every 4 hours</option>
        </select>
      </label>
      <button class="primary" onclick={syncNow} disabled={syncing}>{syncing ? 'Syncing…' : 'Sync now'}</button>
    </div>
    {#if sync?.outcome === 'conflict'}
      <p class="warn">Both machines changed the same files. Choose which version of each to keep.</p>
      {#each sync.files as f (f.path)}
        <div class="conflict">
          <div class="mono path">{f.path}</div>
          <div class="sides">
            {#each [['ours', 'This machine', f.ours], ['theirs', 'Other machine', f.theirs]] as [side, label, text]}
              <label class="side card" class:picked={choices[f.path] === side}>
                <span class="row"
                  ><input type="radio" name={f.path} value={side} bind:group={choices[f.path]} /> <strong>{label}</strong></span
                >
                <pre class="mono">{text ?? '(deleted)'}</pre>
              </label>
            {/each}
          </div>
        </div>
      {/each}
      <div class="row">
        <span class="spacer"></span>
        <button class="primary" disabled={Object.keys(choices).length < sync.files.length} onclick={resolve}>Finish sync</button>
      </div>
    {:else if sync?.outcome === 'newer_format'}
      <p class="warn">
        {sync.file} was saved by a newer aip (format {sync.format}). Update aip on this machine, then sync again.
      </p>
    {:else if sync}
      <p class="muted">{syncText[sync.outcome] ?? sync.outcome}</p>
    {/if}
  </section>

  <section class="card wide">
    <div class="row">
      <h2>Recent changes</h2>
      <span class="spacer"></span>
      <button onclick={undoLast} disabled={!history.length}>Undo the last change</button>
    </div>
    <ul class="plain history" data-testid="history">
      {#each history.slice(0, 30) as e (e.id)}
        <li class="row"><span>{e.summary}</span><span class="spacer"></span><span class="muted small">{when(e.at)}</span></li>
      {/each}
      {#if !history.length}<li class="muted">No changes yet.</li>{/if}
    </ul>
  </section>

  <section class="card wide">
    <h2>File manager</h2>
    <p class="muted small">Add “Open with aip” to your file manager’s right-click menu for folders.</p>
    <ul class="plain">
      {#each integrations as i (i.name)}
        <li class="row">
          <label class="row check">
            <input type="checkbox" checked={i.enabled} disabled={!i.available} onchange={() => toggleIntegration(i)} />
            <strong>{i.label}</strong>
          </label>
          <span class="muted small">{i.note}</span>
        </li>
      {/each}
      {#if !integrations.length}<li class="muted">No supported file manager found.</li>{/if}
    </ul>
  </section>
</div>

<style>
  .page {
    margin-bottom: 14px;
  }
  .grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 16px;
    align-items: start;
  }
  .card {
    padding: 16px 18px;
  }
  .wide {
    grid-column: 1 / -1;
  }
  h2 {
    margin-bottom: 8px;
  }
  .plain {
    list-style: none;
    margin: 8px 0 12px;
    padding: 0;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .row {
    gap: 8px;
  }
  .check {
    gap: 8px;
  }
  .small {
    font-size: 12.5px;
  }
  .warn {
    color: var(--amber);
  }
  .conflict {
    margin: 12px 0;
  }
  .path {
    font-weight: 600;
    margin-bottom: 6px;
  }
  .sides {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 10px;
  }
  .side {
    padding: 10px;
    cursor: pointer;
    box-shadow: none;
  }
  .side.picked {
    border-color: var(--accent);
    box-shadow: 0 0 0 2px var(--accent-soft);
  }
  pre {
    margin: 8px 0 0;
    max-height: 260px;
    overflow: auto;
    white-space: pre-wrap;
    font-size: 12px;
  }
  .history {
    max-height: 320px;
    overflow: auto;
  }
</style>
