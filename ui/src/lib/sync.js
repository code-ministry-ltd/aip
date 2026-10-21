// Syncing the personas repository from anywhere in the app: the Sync now
// button, the sync when aip opens and the sync on changes.
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

/** How long changes must stay unchanged before sync on changes sends them. */
export const QUIET_MS = 2 * 60_000;

/**
 * Sync on changes: feed it each sync state as it is read, and it says when
 * changes have settled for `quietMs` and are due a sync. Each settled state
 * is tried once, so a failed sync (offline, a conflict) is not repeated
 * until something changes again.
 */
export function changeWatcher(quietMs = QUIET_MS) {
  let seen = null;
  let since = 0;
  let tried = null;
  return (state, now) => {
    if (state.fingerprint !== seen) {
      seen = state.fingerprint;
      since = now;
    }
    if (!state.remote || !state.pending || tried === seen || now - since < quietMs) return false;
    tried = seen;
    return true;
  };
}
