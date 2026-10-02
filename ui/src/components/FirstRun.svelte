<script>
  // First run (spec "Install"): which harnesses are here, then create a
  // personas repository or clone one. aip 0.x (a cloned 0.x repository, local
  // profiles, or an install) is converted and removed in one previewed step.
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

  async function clone() {
    busy = true;
    try {
      await api.cloneRoot(url);
      fr = await api.firstRun();
    } catch (e) {
      notify(String(e), 'bad');
      return;
    } finally {
      busy = false;
    }
    // An aip 0.x repository: offer to convert it straight away.
    if (fr.v0_repo) return importV0();
    notify('Cloned your personas repository', 'good');
    ondone?.();
  }

  const removing = $derived(fr?.v0_install ? ' and remove aip 0.x from this machine' : '');
  const step = (n) => (fr?.v0_profiles || fr?.v0_install ? n + 1 : n);

  async function importV0() {
    const r = await change((c) => api.importV0(c), { notify, onchange: ondone, confirmLabel: fr.v0_repo || fr.v0_remote ? 'Convert' : fr.v0_profiles ? 'Import' : 'Remove',
    });
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

    {#if fr.v0_repo}
      <section class="card accent" data-testid="v0">
        <h2>2. Convert your repository</h2>
        <p>
          <span class="mono">{tilde(fr.root)}</span> holds aip 0.x profiles. aip can convert them into personas, commit the
          result and push it back{removing}. The old files stay in Git history. You will see exactly what changes first.
        </p>
        <button class="primary" disabled={busy} onclick={importV0}>Convert to personas…</button>
      </section>
    {:else if fr.v0_profiles}
      <section class="card accent" data-testid="v0">
        <h2>2. Bring over aip 0.x</h2>
        <p>
          You have aip 0.x profiles in <span class="mono">{tilde(fr.v0_profiles)}</span>.
          {#if fr.v0_remote}
            aip can convert them into personas and push them to <span class="mono">{fr.v0_remote}</span>, so your other
            machines get them too{removing}.
          {:else}
            aip can turn them into personas{removing}.
          {/if}
          You will see exactly what changes first.
        </p>
        <button class="primary" disabled={busy} onclick={importV0}
          >{fr.v0_remote ? 'Convert and push…' : 'Import aip 0.x profiles…'}</button
        >
      </section>
    {:else if fr.v0_install}
      <section class="card accent" data-testid="v0">
        <h2>2. Remove aip 0.x</h2>
        <p>aip 0.x is still installed on this machine. Its shell hook would get in the way of 2.0.</p>
        <button class="primary" disabled={busy} onclick={importV0}>Remove aip 0.x…</button>
      </section>
    {/if}

    {#if !fr.v0_repo}
    <section class="card">
      <h2>{step(2)}. Your personas repository</h2>
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
