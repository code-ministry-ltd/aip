import { describe, it, expect } from 'vitest';
import { changeWatcher } from './sync.js';

const st = (fingerprint, pending = true, remote = true) => ({ remote, pending, fingerprint });

describe('sync on changes', () => {
  it('waits for changes to settle, then syncs once', () => {
    const due = changeWatcher(1000);
    expect(due(st('a'), 0)).toBe(false);
    expect(due(st('a'), 999)).toBe(false);
    expect(due(st('b'), 999)).toBe(false); // edited again: the wait restarts
    expect(due(st('b'), 1500)).toBe(false);
    expect(due(st('b'), 1999)).toBe(true);
    expect(due(st('b'), 5000)).toBe(false); // tried; not again until it changes
    expect(due(st('c'), 5000)).toBe(false);
    expect(due(st('c'), 6000)).toBe(true);
  });

  it('never syncs a clean repository or one without a remote', () => {
    const due = changeWatcher(0);
    expect(due(st('a', false), 10)).toBe(false);
    expect(due(st('b', true, false), 10)).toBe(false);
  });
});
