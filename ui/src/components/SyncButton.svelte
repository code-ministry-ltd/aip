<script>
  // Sync now, shown while this machine has changes its other machines have
  // not received.
  import { runSync } from '../lib/sync.js';

  let { overview, notify, onchange } = $props();
  let syncing = $state(false);

  async function syncNow() {
    syncing = true;
    try {
      await runSync({ notify, onchange });
    } finally {
      syncing = false;
    }
  }
</script>

{#if overview.sync?.pending}
  <button onclick={syncNow} disabled={syncing} title="Send this machine’s changes to your other machines">
    {syncing ? 'Syncing…' : 'Sync now'}
  </button>
{/if}
