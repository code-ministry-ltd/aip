<script>
  let { toast } = $props();
  let visible = $state(false);
  let timer;

  $effect(() => {
    if (toast) {
      visible = true;
      clearTimeout(timer);
      timer = setTimeout(() => (visible = false), toast.kind === 'bad' ? 7000 : 3500);
    }
  });
</script>

{#if toast && visible}
  <div class="toast {toast.kind}" role="status">{toast.text}</div>
{/if}

<style>
  .toast {
    position: fixed;
    right: 20px;
    bottom: 20px;
    max-width: 460px;
    padding: 10px 14px;
    border-radius: 10px;
    background: var(--ink);
    color: var(--paper);
    box-shadow: var(--shadow);
    font-weight: 550;
    white-space: pre-wrap;
    z-index: 50;
  }
  .toast.good {
    background: var(--green);
    color: #fff;
  }
  .toast.bad {
    background: var(--red);
    color: #fff;
  }
</style>
