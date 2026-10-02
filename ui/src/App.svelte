<script>
  import { onMount } from 'svelte';
  import { api, onEvent } from './lib/api.js';
  import { setHome, tilde } from './lib/format.js';
  import Skills from './routes/Skills.svelte';
  import Personas from './routes/Personas.svelte';
  import Launch from './routes/Launch.svelte';
  import Machine from './routes/Machine.svelte';
  import Pick from './routes/Pick.svelte';
  import Toast from './components/Toast.svelte';
  import Dialog from './components/Dialog.svelte';
  import FirstRun from './components/FirstRun.svelte';
  import { ask } from './lib/dialog.svelte.js';

  let route = $state(parseHash());
  let overview = $state(null);
  let error = $state('');
  let toast = $state(null);
  let update = $state(null);
  let broken = $state([]);
  let updating = $state(false);

  function parseHash() {
    const h = (typeof location !== 'undefined' ? location.hash : '') || '#/';
    const [path, query = ''] = h.slice(1).split('?');
    return { path: path || '/', params: Object.fromEntries(new URLSearchParams(query)) };
  }

  async function refresh() {
    try {
      overview = await api.overview();
      setHome(overview.home);
      error = '';
    } catch (e) {
      error = String(e);
    }
  }

  export function notify(text, kind = 'info') {
    toast = { text, kind, at: Date.now() };
  }

  async function undo() {
    const what = await api.undo(false);
    if (!what) return notify('Nothing to undo');
    if (!(await ask({ title: `Undo: ${what}?`, confirmLabel: 'Undo', note: '' }))) return;
    try {
      await api.undo(true);
      notify(`Undone: ${what}`, 'good');
      refresh();
    } catch (e) {
      notify(String(e), 'bad');
    }
  }

  onMount(() => {
    const onHash = () => (route = parseHash());
    window.addEventListener('hashchange', onHash);
    refresh().then(() => {
      api.ready();
      checkForUpdate();
    });
    let unlisten = () => {};
    onEvent('reverify', (problems) => (broken = problems)).then((u) => (unlisten = u));
    return () => {
      window.removeEventListener('hashchange', onHash);
      unlisten();
    };
  });

  /** Update checks are on by default and can be turned off (spec decision 7). */
  async function checkForUpdate() {
    if (route.path === '/pick' || !overview || overview.settings.update_checks === false) return;
    try {
      const s = await api.updateStatus();
      if (s.available) update = s;
    } catch {
      // Offline or rate-limited: try again next start.
    }
  }

  async function installUpdate() {
    updating = true;
    try {
      await api.updateInstall(); // restarts the app
    } catch (e) {
      notify(String(e), 'bad');
      updating = false;
    }
  }

  // The opt-in sync timer (spec SC7). Conflicts wait for the Machine screen.
  $effect(() => {
    const minutes = overview?.settings.sync_interval_minutes;
    if (!minutes || route.path === '/pick') return;
    const id = setInterval(async () => {
      try {
        const r = await api.syncNow();
        if (r.outcome === 'conflict') notify('Sync needs you: open This machine ▸ Sync', 'bad');
        else if (r.outcome === 'pulled' || r.outcome === 'merged') refresh();
      } catch (e) {
        notify(`Sync failed: ${e}`, 'bad');
      }
    }, minutes * 60_000);
    return () => clearInterval(id);
  });

  const nav = [
    { path: '/', label: 'Skills', icon: 'M4 5h16M4 12h16M4 19h10' },
    { path: '/personas', label: 'Personas', icon: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm-7 8a7 7 0 0 1 14 0' },
    { path: '/launch', label: 'Launch', icon: 'M5 19 19 5M9 5h10v10' },
    { path: '/machine', label: 'This machine', icon: 'M4 6h16v10H4zM8 20h8M12 16v4' },
  ];
</script>

{#if route.path === '/pick'}
  <Pick dir={route.params.dir || ''} {notify} />
{:else}
  <div class="shell">
    <aside>
      <div class="brand">
        <img src="/aip.png" alt="" width="28" height="28" />
        <span>aip</span>
      </div>
      <nav>
        {#each nav as item}
          <a href={'#' + item.path} class:active={route.path === item.path}>
            <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"
              ><path d={item.icon} fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" /></svg
            >
            {item.label}
          </a>
        {/each}
      </nav>
      <div class="spacer"></div>
      <button class="ghost undo" onclick={undo} title="Undo the last skill or persona change">↶ Undo</button>
      {#if overview}
        <div class="foot muted">
          <div title={overview.root}>{tilde(overview.root)}</div>
          <div>v{overview.version}</div>
        </div>
      {/if}
    </aside>
    <main>
      {#if error}
        <div class="card problem">
          <h2>aip could not read your setup</h2>
          <p class="mono">{error}</p>
          <button onclick={refresh}>Try again</button>
        </div>
      {:else if overview && !overview.root_exists}
        <FirstRun {notify} ondone={refresh} />
      {:else if overview}
        {#if update}
          <div class="card banner" data-testid="update">
            <span>aip {update.latest} is available (you have {update.current}).</span>
            <span class="spacer"></span>
            {#if update.can_install}
              <button class="primary" disabled={updating} onclick={installUpdate}>{updating ? 'Updating…' : 'Update and restart'}</button>
            {:else}
              <span class="muted">To update, {update.advice}.</span>
            {/if}
            <button class="ghost" onclick={() => (update = null)} aria-label="Dismiss">✕</button>
          </div>
        {/if}
        {#if broken.length}
          <div class="card banner warn" data-testid="reverify">
            <div>
              <strong>After a harness update, some personas no longer load as expected:</strong>
              <ul>
                {#each broken as p}
                  <li>
                    {p.persona} in {p.harness} {p.version}: {p.error ?? `missing ${p.missing.join(', ')}`}
                  </li>
                {/each}
              </ul>
            </div>
            <span class="spacer"></span>
            <button class="ghost" onclick={() => (broken = [])} aria-label="Dismiss">✕</button>
          </div>
        {/if}
        {#if route.path === '/'}
          <Skills {overview} {notify} onchange={refresh} />
        {:else if route.path === '/personas'}
          <Personas {overview} {notify} onchange={refresh} />
        {:else if route.path === '/launch'}
          <Launch {overview} {notify} onchange={refresh} folder={route.params.dir} />
        {:else if route.path === '/machine'}
          <Machine {overview} {notify} onchange={refresh} />
        {/if}
      {/if}
    </main>
  </div>
{/if}
<Toast {toast} />
<Dialog />

<style>
  .shell {
    display: grid;
    grid-template-columns: 200px 1fr;
    height: 100%;
  }
  aside {
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding: 16px 12px;
    border-right: 1px solid var(--line);
    background: var(--surface-2);
  }
  .brand {
    display: flex;
    align-items: center;
    gap: 10px;
    font-weight: 750;
    font-size: 18px;
    padding: 0 8px 14px;
  }
  .brand img {
    border-radius: 8px;
    image-rendering: pixelated;
  }
  nav {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  nav a {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 10px;
    border-radius: 8px;
    color: var(--ink-2);
    text-decoration: none;
    font-weight: 550;
  }
  nav a:hover {
    background: var(--surface);
  }
  nav a.active {
    background: var(--surface);
    color: var(--accent);
    box-shadow: var(--shadow);
  }
  .undo {
    text-align: left;
  }
  .foot {
    font-size: 11.5px;
    padding: 8px 10px 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  main {
    overflow: auto;
    padding: 24px 28px 40px;
  }
  .banner {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 14px;
    margin-bottom: 16px;
    background: var(--accent-soft);
  }
  .banner.warn {
    background: var(--amber-soft);
    align-items: flex-start;
  }
  .banner ul {
    margin: 6px 0 0;
    padding-left: 18px;
  }
  .problem {
    max-width: 560px;
    padding: 24px;
  }
  .problem p {
    margin: 10px 0;
  }
</style>
