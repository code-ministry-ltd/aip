<script>
  // A right-click menu. `menu` is { x, y, items: [{ label, run, danger?, disabled?, sep? }] }
  // or null; picking an item closes it.
  let { menu = $bindable(null) } = $props();

  // Keep the menu inside the window; a taller one scrolls (see max-height).
  let el = $state(null);
  let height = $state(0);
  $effect(() => {
    if (menu && el) height = el.offsetHeight;
  });
  const margin = 8;
  const left = $derived(menu ? Math.max(margin, Math.min(menu.x, window.innerWidth - 260)) : 0);
  const top = $derived(menu ? Math.max(margin, Math.min(menu.y, window.innerHeight - height - margin)) : 0);

  function pick(item) {
    menu = null;
    item.run?.();
  }

  function key(e) {
    if (menu && e.key === 'Escape') menu = null;
  }
</script>

<svelte:window onkeydown={key} onclick={() => (menu = null)} />

{#if menu}
  <div
    class="menu card"
    role="menu"
    tabindex="-1"
    style="left: {left}px; top: {top}px"
    bind:this={el}
    onclick={(e) => e.stopPropagation()}
    onkeydown={key}
  >
    {#each menu.items as item}
      {#if item.sep}
        <div class="sep"></div>
      {:else if item.heading}
        <div class="heading">{item.heading}</div>
      {:else}
        <button role="menuitem" class="ghost" class:danger={item.danger} disabled={item.disabled} onclick={() => pick(item)}
          >{item.label}</button
        >
      {/if}
    {/each}
  </div>
{/if}

<style>
  .menu {
    position: fixed;
    z-index: 45;
    min-width: 220px;
    max-height: calc(100vh - 16px);
    overflow-y: auto;
    padding: 4px;
    display: flex;
    flex-direction: column;
  }
  button {
    text-align: left;
    border: 0;
    padding: 6px 10px;
    border-radius: 6px;
  }
  button.danger {
    color: var(--red);
    background: transparent;
  }
  .sep {
    height: 1px;
    background: var(--line);
    margin: 4px 2px;
  }
  .heading {
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
    color: var(--ink-3);
    padding: 6px 10px 2px;
  }
</style>
