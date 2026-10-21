import { describe, it, expect } from 'vitest';
import { render, screen, fireEvent, within } from '@testing-library/svelte';
import App from './App.svelte';
import { fakeCore, overview, tick } from './test/fake.js';

const withSync = (sync, settings = {}) => {
  const o = overview();
  o.sync = sync;
  Object.assign(o.settings, settings);
  return () => o;
};

describe('App: sync when aip opens', () => {
  it('syncs once on open when there is a remote', async () => {
    const core = fakeCore({ overview: withSync({ remote: true, pending: false }) });
    render(App);
    await tick(10);
    expect(core.named('sync_now')).toHaveLength(1);
  });

  it('does not sync without a remote, or when turned off', async () => {
    let core = fakeCore({ overview: withSync({ remote: false, pending: false }) });
    render(App);
    await tick(10);
    expect(core.named('sync_now')).toHaveLength(0);
    core = fakeCore({ overview: withSync({ remote: true, pending: false }, { sync_on_open: false }) });
    render(App);
    await tick(10);
    expect(core.named('sync_now')).toHaveLength(0);
  });
});

describe('App: unsynced changes', () => {
  const pending = { remote: true, pending: true, fingerprint: 'x' };

  it('warns with a banner only when sync on changes is off', async () => {
    fakeCore({ overview: withSync(pending, { sync_on_open: false, sync_on_changes: false }) });
    render(App);
    await tick(10);
    expect(screen.getByTestId('unsynced').textContent).toContain('have not received');
    await fireEvent.click(within(screen.getByTestId('unsynced')).getByLabelText('Dismiss'));
    expect(screen.queryByTestId('unsynced')).toBeNull();
  });

  it('shows no banner while sync on changes is on', async () => {
    fakeCore({ overview: withSync(pending, { sync_on_open: false }) });
    render(App);
    await tick(10);
    expect(screen.queryByTestId('unsynced')).toBeNull();
  });

  it('checks the repository again when the window comes back', async () => {
    const core = fakeCore({
      overview: withSync({ remote: true, pending: false, fingerprint: 'clean' }, { sync_on_open: false, sync_on_changes: false }),
      sync_state: () => pending,
    });
    render(App);
    await tick(10);
    expect(screen.queryByTestId('unsynced')).toBeNull();
    window.dispatchEvent(new Event('focus'));
    await tick(10);
    expect(core.named('sync_state')).toHaveLength(1);
    expect(screen.getByTestId('unsynced')).toBeTruthy();
  });
});
