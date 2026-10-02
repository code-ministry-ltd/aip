<script>
  // First run (spec "Install"): which harnesses are here, then create a
  // personas repository or clone one, and offer to import aip 0.x.
  import { onMount } from 'svelte';
  import { api } from '../lib/api.js';
  import { change } from '../lib/actions.js';
  import { tilde, harnessLabel } from '../lib/format.js';

  let { notify, ondone } = $props();

  let fr = $state(null);
  let url = $state('');
  let busy = $state(false);

  onMount(async () => {
    try {
      fr = await api.firstRun();
    } catch (e) {
      notify(String(e), 'bad');
    }
  });

  async function run(fn, done) {
    busy = true;
    try {
      await fn();
      notify(done, 'good');
      ondone?.();
    } catch (e) {
      notify(String(e), 'bad');
    } finally {
      busy = false;
    }
  }

  const create = () => run(() => api.createRoot(), 'Created your personas repository');
  const clone = () => run(() => api.cloneRoot(url), 'Cloned your personas repository');

  async function importV0() {
    const r = await change((c) => api.importV0(c), { notify, onchange: ondone, confirmLabel: 'Import' });
    if (r?.kind === 'done') ondone?.();
  }
</script>

<div class="first">
  <h1>Welcome to aip</h1>
  <p class="muted lead">
    aip keeps your skills in a library and groups them into personas. Launch Claude Code or Pi with a persona when you want
    its skills; otherwise they start as usual.
  </p>

  {#if fr}
    <section class="card">
      <h2>1. Your harnesses</h2>
      <ul>
        {#each fr.harnesses as h}
          <li class="row">
            <span class="badge {h.harness}">{harnessLabel[h.harness]}</span>
            {#if h.version}<span class="mono">{h.version}</span>{:else}<span class="muted">not found on PATH</span>{/if}
          </li>
        {/each}
      </ul>
      {#if fr.harnesses.every((h) => !h.version)}
        <p class="warn">Neither Claude Code nor Pi was found. Install one, then come back; you can still set up personas now.</p>
      {/if}
    </section>

    {#if fr.v0_profiles}
      <section class="card accent" data-testid="v0">
        <h2>2. Bring over aip 0.x</h2>
        <p>
          You have aip 0.x profiles in <span class="mono">{tilde(fr.v0_profiles)}</span>. aip can turn them into personas{fr.v0_hook
            ? ' and remove the 0.x shell hook'
            : ''}. You will see exactly what changes first.
        </p>
        <button class="primary" disabled={busy} onclick={importV0}>Import aip 0.x profiles…</button>
      </section>
    {/if}

    <section class="card">
      <h2>{fr.v0_profiles ? '3' : '2'}. Your personas repository</h2>
      <p class="muted">It is a Git repository at <span class="mono">{tilde(fr.root)}</span>, so it can sync between machines.</p>
      <div class="choices">
        <div>
          <h3>Start fresh</h3>
          <p class="muted small">With a few example skills and two personas to edit or delete.</p>
          <button class="primary" disabled={busy} onclick={create}>Create it</button>
        </div>
        <div>
          <h3>Use one from another machine</h3>
          <form
            class="row"
            onsubmit={(e) => {
              e.preventDefault();
              clone();
            }}
          >
            <input placeholder="git@github.com:you/agent-personas.git" bind:value={url} aria-label="Repository URL" />
            <button disabled={busy || !url.trim()} type="submit">Clone</button>
          </form>
        </div>
      </div>
    </section>
  {/if}
</div>

<style>
  .first {
    max-width: 720px;
    display: flex;
    flex-direction: column;
    gap: 16px;
  }
  .lead {
    margin: 0;
  }
  .card {
    padding: 16px 18px;
  }
  .card.accent {
    background: var(--accent-soft);
  }
  h2 {
    margin-bottom: 8px;
  }
  h3 {
    font-size: 14px;
    margin-bottom: 4px;
  }
  ul {
    list-style: none;
    padding: 0;
    margin: 0;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .row {
    gap: 8px;
  }
  .choices {
    display: grid;
    grid-template-columns: 1fr 1.4fr;
    gap: 18px;
    margin-top: 10px;
  }
  .choices input {
    flex: 1;
  }
  .small {
    font-size: 12.5px;
  }
  .warn {
    color: var(--amber);
  }
</style>
