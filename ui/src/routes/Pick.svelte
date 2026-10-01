<script>
  // The picker window (`aip pick DIR`, aip://pick): choose a harness and a
  // persona with the keyboard alone, in either order, then launch.
  //   c / p / d   Claude Code, Pi, Claude desktop
  //   0           no persona;  1–9  a persona
  //   ← →         switch column;  ↑ ↓  move;  Enter  launch;  Esc  close
  import { onMount } from 'svelte';
  import { api } from '../lib/api.js';
  import { last, tilde, targetLabel } from '../lib/format.js';

  let { dir, notify } = $props();

  let ctx = $state(null);
  let error = $state('');
  let target = $state('claude');
  let persona = $state('');
  let column = $state('target');
  let picked = $state({ target: false, persona: false });
  let busy = $state(false);

  const keys = { claude: 'c', pi: 'p', 'claude-desktop': 'd' };

  onMount(async () => {
    try {
      ctx = await api.pickContext(dir);
      if (ctx.last) {
        target = ctx.last[0];
        persona = ctx.last[1] ?? '';
      }
    } catch (e) {
      error = String(e);
    }
  });

  const personaOptions = $derived(ctx ? [['', 'No persona'], ...ctx.personas] : []);

  async function launch() {
    if (busy || !ctx) return;
    busy = true;
    try {
      const r = await api.launch(ctx.dir, target, persona || null);
      if (r.notes?.length) notify(r.notes.join('\n'));
      await api.closeWindow();
    } catch (e) {
      notify(String(e), 'bad');
      busy = false;
    }
  }

  function choose(kind, value) {
    if (kind === 'target') target = value;
    else persona = value;
    picked[kind] = true;
    column = kind === 'target' ? 'persona' : 'target';
    // Both chosen, in whichever order: go.
    if (picked.target && picked.persona) launch();
  }

  function move(delta) {
    if (column === 'target') {
      const list = ctx.targets;
      target = list[(list.indexOf(target) + delta + list.length) % list.length];
    } else {
      const list = personaOptions.map(([n]) => n);
      persona = list[(list.indexOf(persona) + delta + list.length) % list.length];
    }
  }

  function key(e) {
    if (!ctx) return;
    if (e.key === 'Escape') return api.closeWindow();
    if (e.key === 'Enter') return (e.preventDefault(), launch());
    if (e.key === 'ArrowLeft' || e.key === 'ArrowRight' || e.key === 'Tab') {
      e.preventDefault();
      column = column === 'target' ? 'persona' : 'target';
      return;
    }
    if (e.key === 'ArrowDown') return (e.preventDefault(), move(1));
    if (e.key === 'ArrowUp') return (e.preventDefault(), move(-1));
    const t = ctx.targets.find((t) => keys[t] === e.key.toLowerCase());
    if (t) return choose('target', t);
    if (/^[0-9]$/.test(e.key)) {
      const opt = personaOptions[Number(e.key)];
      if (opt) choose('persona', opt[0]);
    }
  }
</script>

<svelte:window onkeydown={key} />

<div class="pick">
  {#if error}
    <p class="bad">{error}</p>
  {:else if ctx}
    <header>
      <h1>{last(ctx.dir)}</h1>
      <div class="muted mono small">{tilde(ctx.dir)}</div>
    </header>
    <div class="cols">
      <section class:focus={column === 'target'} aria-label="Open in">
        <h3>Open in</h3>
        {#each ctx.targets as t}
          <button class="opt" class:on={target === t} onclick={() => choose('target', t)} data-testid="target-{t}">
            <kbd>{keys[t]}</kbd>{targetLabel[t]}
          </button>
        {/each}
      </section>
      <section class:focus={column === 'persona'} aria-label="Persona">
        <h3>Persona</h3>
        {#each personaOptions as [name, description], i}
          <button class="opt" class:on={persona === name} onclick={() => choose('persona', name)} title={description}>
            <kbd>{i < 10 ? i : ''}</kbd>{name || description}
          </button>
        {/each}
      </section>
    </div>
    <footer class="row">
      <span class="muted small">Press a key in each column, in either order. Enter launches, Esc closes.</span>
      <span class="spacer"></span>
      <button class="primary" onclick={launch} disabled={busy}>Launch {targetLabel[target]}{persona ? ` · ${persona}` : ''}</button>
    </footer>
  {:else}
    <p class="muted">…</p>
  {/if}
</div>

<style>
  .pick {
    padding: 18px 20px;
    height: 100%;
    display: flex;
    flex-direction: column;
    gap: 14px;
  }
  .small {
    font-size: 12px;
  }
  .cols {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 12px;
    flex: 1;
    min-height: 0;
  }
  section {
    display: flex;
    flex-direction: column;
    gap: 3px;
    padding: 8px;
    border-radius: var(--radius);
    border: 1px solid var(--line);
    overflow: auto;
  }
  section.focus {
    border-color: var(--accent);
    box-shadow: 0 0 0 2px var(--accent-soft);
  }
  h3 {
    font-size: 12px;
    text-transform: uppercase;
    color: var(--ink-3);
    letter-spacing: 0.05em;
    margin: 2px 4px 6px;
  }
  .opt {
    display: flex;
    gap: 10px;
    align-items: center;
    text-align: left;
    border-color: transparent;
    background: transparent;
  }
  .opt.on {
    background: var(--accent-soft);
    color: var(--ink);
    font-weight: 600;
  }
  kbd {
    font-family: var(--mono);
    font-size: 11px;
    min-width: 18px;
    text-align: center;
    padding: 1px 4px;
    border-radius: 4px;
    border: 1px solid var(--line);
    color: var(--ink-3);
  }
  .bad {
    color: var(--red);
  }
</style>
