import { describe, it, expect } from 'vitest';
import { render } from '@testing-library/svelte';
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
