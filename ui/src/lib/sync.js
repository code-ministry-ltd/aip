// Syncing the personas repository from anywhere in the app: the Sync now
// button, the sync when aip opens and the timer.
import { api } from './api.js';

export const syncText = {
  no_remote: 'This personas repository has no remote, so changes stay on this machine.',
  up_to_date: 'Up to date.',
  pushed: 'Sent this machine’s changes.',
  pulled: 'Fetched changes from your other machines.',
  merged: 'Merged changes from both sides.',
};

/** Sync, report the outcome and refresh. `quiet` reports only what arrived or went wrong. */
export async function runSync({ notify, onchange, quiet = false }) {
  try {
    const r = await api.syncNow();
    if (r.outcome === 'conflict') notify('Sync needs you: open Settings ▸ Sync', 'bad');
    else if (r.outcome === 'newer_format') notify(`Sync stopped: ${r.file} was saved by a newer aip. Update aip here first.`, 'bad');
    else if (!quiet || r.outcome === 'pulled' || r.outcome === 'merged') notify(syncText[r.outcome] ?? r.outcome, 'good');
    onchange?.();
    return r;
  } catch (e) {
    notify(`Sync failed: ${e}`, 'bad');
    return null;
  }
}
