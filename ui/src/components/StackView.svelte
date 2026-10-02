<script>
  // The launch preview for one harness: every skill by layer, and what
  // actually loads (spec "Launch preview").
  import { layerLabel, harnessLabel, sourceLabel, tokens } from '../lib/format.js';

  let { stack, onresolve = null } = $props();

  function cell(row, layerIndex) {
    return row.copies.filter((c) => c.layer === layerIndex);
  }

  const flagged = $derived(stack.rows.filter((r) => r.copies.length > 1).length);
  const loaded = $derived(stack.rows.reduce((n, r) => n + r.copies.filter((c) => c.loads).length, 0));
</script>

<section class="card stack" data-harness={stack.harness}>
  <header class="row">
    <span class="badge {stack.harness}">{harnessLabel[stack.harness]}</span>
    <span class="muted">{loaded} skills load</span>
    {#if flagged}<span class="badge warn">{flagged} duplicate{flagged > 1 ? 's' : ''}</span>{/if}
    <span class="spacer"></span>
    <span class="total" title="Always-on context: names and descriptions in the skill catalog"
      ><strong data-testid="total">{tokens(stack.always_on_tokens)}</strong> tokens always on</span
    >
  </header>
  {#if !stack.project_layers_load}
    <p class="note">Pi does not trust this folder, so its project skills do not load here.</p>
  {/if}
  <div class="grid" style="--cols: {stack.layers.length}">
    <div class="h name">Skill</div>
    {#each stack.layers as l}<div class="h layer {l.kind}">{layerLabel(l)}</div>{/each}
    <div class="h">What loads</div>

    {#each stack.rows as row (row.name)}
      <div class="name mono" class:flag={row.copies.length > 1}>{row.name}</div>
      {#each stack.layers as _, li}
        <div class="slot">
          {#each cell(row, li) as c}
            <span
              class="chip"
              class:off={!c.loads}
              class:twice={row.loads_twice && c.loads}
              title="{c.location.skill.description} — {c.location.skill.dir} ({sourceLabel(c.location.source)})"
              >{c.loads ? '●' : '○'} {sourceLabel(c.location.source)}</span
            >
          {/each}
        </div>
      {/each}
      <div class="out" class:warn={row.copies.length > 1}>
        {row.outcome}
        {#if row.copies.length > 1 && onresolve}
          <button class="ghost tiny" onclick={(e) => { e.stopPropagation(); onresolve(row, e); }}>Resolve…</button>
        {/if}
      </div>
    {/each}
  </div>
  {#if !stack.rows.length}<p class="muted pad">No skills load.</p>{/if}
</section>

<style>
  .stack {
    padding: 14px 16px 16px;
  }
  header {
    margin-bottom: 10px;
  }
  .total {
    color: var(--ink-2);
  }
  .note {
    margin: 0 0 10px;
    padding: 8px 10px;
    border-radius: 8px;
    background: var(--amber-soft);
    color: var(--amber);
    font-size: 13px;
  }
  .grid {
    display: grid;
    grid-template-columns: minmax(130px, 1.1fr) repeat(var(--cols), minmax(110px, 1fr)) minmax(200px, 2fr);
    align-items: center;
    border-top: 1px solid var(--line);
  }
  .grid > div {
    padding: 7px 8px;
    border-bottom: 1px solid var(--line);
    min-height: 36px;
    display: flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 4px;
  }
  .h {
    font-size: 11.5px;
    font-weight: 650;
    color: var(--ink-3);
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }
  .h.layer.persona {
    color: var(--accent);
  }
  .name.flag {
    color: var(--amber);
    font-weight: 600;
  }
  .chip {
    font-size: 11.5px;
    padding: 1px 8px;
    border-radius: 999px;
    background: var(--green-soft);
    color: var(--green);
    white-space: nowrap;
  }
  .chip.off {
    background: transparent;
    color: var(--ink-3);
    text-decoration: line-through;
    border: 1px dashed var(--line);
  }
  .chip.twice {
    background: var(--red-soft);
    color: var(--red);
  }
  .out {
    font-size: 13px;
    color: var(--ink-2);
  }
  .out.warn {
    color: var(--amber);
    font-weight: 550;
  }
  .tiny {
    padding: 1px 8px;
    font-size: 12px;
  }
  .pad {
    padding: 8px;
  }
</style>
