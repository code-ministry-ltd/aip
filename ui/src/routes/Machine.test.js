import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/svelte';
import Machine from './Machine.svelte';
import { answer } from '../lib/dialog.svelte.js';
import { fakeCore, overview, tick } from '../test/fake.js';

describe('This machine', () => {
  it('turns file-manager menus on and off through the core', async () => {
    const core = fakeCore();
    const notify = vi.fn();
    render(Machine, { overview: overview(), notify, onchange: vi.fn() });
    await tick();
    const dolphin = screen.getByLabelText(/Dolphin/);
    expect(dolphin.disabled).toBe(true); // not installed here
    expect(screen.getByLabelText(/Nautilus/).checked).toBe(true);
    await fireEvent.click(screen.getByLabelText(/Nemo/));
    await tick();
    expect(core.named('set_integration')).toEqual([{ name: 'nemo', enabled: true }]);
    expect(notify).toHaveBeenCalledWith('nemo on', 'good');
  });

  it('shows both sides of a sync conflict and resolves with the choices', async () => {
    const conflict = {
      outcome: 'conflict',
      files: [{ path: 'personas/coder.toml', ours: 'skills = ["a"]', theirs: 'skills = ["b"]' }],
    };
    const core = fakeCore({ sync_now: () => conflict, sync_resolve: () => ({ outcome: 'pushed' }) });
    render(Machine, { overview: overview(), notify: vi.fn(), onchange: vi.fn() });
    await tick();
    await fireEvent.click(screen.getByText('Sync now'));
    await tick();
    expect(screen.getByText('skills = ["a"]')).toBeTruthy();
    expect(screen.getByText('skills = ["b"]')).toBeTruthy();
    const finish = screen.getByText('Finish sync');
    expect(finish.disabled).toBe(true);
    await fireEvent.click(screen.getAllByRole('radio')[1]); // theirs
    await fireEvent.click(finish);
    await tick();
    answer(true);
    await tick();
    expect(core.named('sync_resolve')).toEqual([{ choices: [['personas/coder.toml', 'theirs']] }]);
  });
});
