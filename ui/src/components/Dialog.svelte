<script>
  import { dialog, answer } from '../lib/dialog.svelte.js';

  function key(e) {
    if (!dialog.open) return;
    if (e.key === 'Escape') answer(false);
    if (e.key === 'Enter' && !e.shiftKey) answer(true);
  }
</script>

<svelte:window onkeydown={key} />

{#if dialog.open}
  <div class="backdrop" role="presentation" onclick={() => answer(false)}>
    <div class="card modal" role="dialog" tabindex="-1" aria-modal="true" aria-label={dialog.title} onclick={(e) => e.stopPropagation()} onkeydown={() => {}}>
      <h2>{dialog.title}</h2>
      {#if dialog.lines.length}
        <ul>
          {#each dialog.lines as l}<li class="mono">{l}</li>{/each}
        </ul>
      {/if}
      {#if dialog.body}<pre class="mono">{dialog.body}</pre>{/if}
      {#if dialog.note}<p class="muted small">{dialog.note}</p>{/if}
      <div class="row">
        <span class="spacer"></span>
        {#if dialog.cancelLabel}<button onclick={() => answer(false)}>{dialog.cancelLabel}</button>{/if}
        <button class="primary" class:danger-bg={dialog.danger} onclick={() => answer(true)}>{dialog.confirmLabel}</button>
      </div>
    </div>
  </div>
{/if}

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    background: rgba(20, 25, 34, 0.45);
    display: grid;
    place-items: center;
    z-index: 40;
  }
  .modal {
    width: min(620px, 92vw);
    max-height: 80vh;
    overflow: auto;
    padding: 20px 22px;
  }
  ul {
    margin: 12px 0;
    padding-left: 18px;
  }
  li {
    margin: 4px 0;
    word-break: break-all;
  }
  pre {
    background: var(--surface-2);
    padding: 10px;
    border-radius: 8px;
    max-height: 40vh;
    overflow: auto;
    white-space: pre-wrap;
  }
  .small {
    font-size: 12px;
  }
  .danger-bg {
    background: var(--red);
    border-color: var(--red);
  }
</style>
