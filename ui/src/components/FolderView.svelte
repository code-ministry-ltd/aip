<script>
  // Each harness's stack for one folder, optionally with a persona: the
  // launch preview (spec "Launch preview"). Flagged rows can be resolved in
  // place.
  import { api } from '../lib/api.js';
  import { skillMenu } from '../lib/actions.js';
  import { tilde } from '../lib/format.js';
  import StackView from './StackView.svelte';
  import Menu from './Menu.svelte';

  let { folder, persona = '', overview, notify, onchange = null, view = $bindable(null) } = $props();

  let error = $state('');
  let loading = $state(false);
  let menu = $state(null);
  let seq = 0;

  async function load() {
    if (!folder) return;
    const mine = ++seq;
    loading = true;
    try {
      const v = await api.folderView(folder, persona);
      if (mine === seq) {
        view = v;
        error = '';
      }
    } catch (e) {
      if (mine === seq) {
        view = null;
        error = String(e);
      }
    } finally {
      if (mine === seq) loading = false;
    }
  }

  $effect(() => {
    folder;
    persona;
    load();
  });

  function changed() {
    load();
    onchange?.();
  }

  function resolve(row, e) {
    const items = [];
    for (const c of row.copies) {
      const others = row.copies.filter((o) => o !== c).map((o) => o.location);
      items.push(...skillMenu(c.location, { personas: overview.personas, others, notify, onchange: changed }));
      items.push({ sep: true });
    }
    items.pop();
    const r = e?.target?.getBoundingClientRect?.();
    menu = { x: r ? r.left : 200, y: r ? r.bottom + 4 : 200, items };
  }

  async function trust() {
    try {
      await api.trustPi(view.folder);
      notify('Pi now trusts this folder', 'good');
      load();
    } catch (e) {
      notify(String(e), 'bad');
    }
  }

  async function clearProject() {
    try {
      const log = await api.projectClear(view.folder);
      notify(log.length ? log.join('\n') : 'Nothing to clear', 'good');
      load();
    } catch (e) {
      notify(String(e), 'bad');
    }
  }

  const piUntrusted = $derived(
    view && (view.pi_trust.state === 'ask' || (view.pi_trust.state !== 'ask' && view.pi_trust.trusted === false)),
  );
</script>

{#if error}
  <div class="card warn-box">{error}</div>
{:else if view}
  {#if view.applied?.persona}
    <div class="card banner">
      <span
        >The persona <strong>{view.applied.persona}</strong> is written into this folder, because a desktop app (such as
        Claude desktop) was opened here with it: that is the only way to give one a persona. Its skills and settings stay in the folder's
        project files, hidden from Git, so anything opened here, including a plain <span class="mono">claude</span>, gets
        them until you remove them.</span
      >
      <span class="spacer"></span>
      <button onclick={clearProject}>Remove from this folder</button>
    </div>
  {/if}
  {#if piUntrusted}
    <div class="card banner" data-testid="pi-trust">
      <span>
        {#if view.pi_trust.state === 'ask'}
          Pi has not been told whether to trust {tilde(view.folder)}. Without a decision, Pi in a GUI (such as Paseo) skips
          its project skills.
        {:else}
          Pi is set not to trust {tilde(view.folder)}, so its project skills do not load.
        {/if}
      </span>
      <span class="spacer"></span>
      <button class="primary" onclick={trust}>Trust this folder for Pi</button>
    </div>
  {/if}
  <div class="stacks" class:loading>
    {#each view.stacks as stack (stack.harness)}
      <StackView {stack} onresolve={resolve} />
    {/each}
  </div>
{:else if loading}
  <p class="muted">Reading {tilde(folder)}…</p>
{/if}
<Menu bind:menu />

<style>
  .stacks {
    display: flex;
    flex-direction: column;
    gap: 14px;
  }
  .loading {
    opacity: 0.6;
  }
  .banner {
    display: flex;
    gap: 12px;
    align-items: center;
    padding: 10px 14px;
    margin-bottom: 12px;
    background: var(--amber-soft);
    color: var(--ink);
  }
  .warn-box {
    padding: 12px 14px;
    color: var(--red);
  }
</style>
