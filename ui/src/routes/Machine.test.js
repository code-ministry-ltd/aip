import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/svelte';
import Machine from './Machine.svelte';
import { answer } from '../lib/dialog.svelte.js';
import { fakeCore, overview, tick } from '../test/fake.js';

describe('Settings', () => {
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

describe('Settings: the sync remote', () => {
  it('shows the remote and changes it', async () => {
    const core = fakeCore();
    render(Machine, { overview: overview(), notify: vi.fn(), onchange: vi.fn() });
    await tick();
    expect(screen.getByTestId('remote').textContent).toContain('git@github.com:you/agent-personas.git');
    await fireEvent.click(screen.getByText('Change'));
    await tick();
    const save = screen.getByText('Save', { selector: '[data-testid="remote"] button' });
    expect(save.disabled).toBe(true);
    await fireEvent.input(screen.getByLabelText('Remote URL'), { target: { value: ' git@example.com:me/p.git ' } });
    await fireEvent.click(save);
    await tick();
    expect(core.named('set_sync_remote')).toEqual([{ url: 'git@example.com:me/p.git' }]);
  });

  it('turns sync when aip opens off', async () => {
    const core = fakeCore();
    render(Machine, { overview: overview(), notify: vi.fn(), onchange: vi.fn() });
    await tick();
    const box = screen.getByLabelText('When aip opens');
    expect(box.checked).toBe(true);
    await fireEvent.click(box);
    await tick();
    expect(core.named('set_sync_on_open')).toEqual([{ enabled: false }]);
  });

  it('removes the remote after asking', async () => {
    const core = fakeCore();
    render(Machine, { overview: overview(), notify: vi.fn(), onchange: vi.fn() });
    await tick();
    await fireEvent.click(screen.getByText('Remove', { selector: '[data-testid="remote"] button' }));
    await tick();
    answer(true);
    await tick();
    expect(core.named('set_sync_remote')).toEqual([{ url: null }]);
    expect(screen.getByTestId('remote').textContent).toContain('none');
    expect(screen.getByText('Set remote')).toBeTruthy();
  });
});

describe('Settings: updates and the command-line tool', () => {
  it('checks for updates and offers the updater when it can install', async () => {
    const core = fakeCore();
    render(Machine, { overview: overview(), notify: vi.fn(), onchange: vi.fn() });
    await tick();
    await fireEvent.click(screen.getByText('Check for updates'));
    await tick();
    expect(screen.getByTestId('update-result').textContent).toContain('2.0.1 is available');
    await fireEvent.click(screen.getByText('Update and restart'));
    await tick();
    expect(core.named('update_install')).toHaveLength(1);
  });

  it('a package install gets advice, not a button', async () => {
    fakeCore({
      update_status: () => ({
        current: '2.0.0', latest: '2.0.1', available: true, can_install: false,
        advice: 'update it with aur; aip never replaces a package manager’s files', error: null,
        channel: { kind: 'package', name: 'aur' }, path: { kind: 'package_manager', name: 'aur' },
      }),
    });
    render(Machine, { overview: overview(), notify: vi.fn(), onchange: vi.fn() });
    await tick();
    await fireEvent.click(screen.getByText('Check for updates'));
    await tick();
    expect(screen.getByTestId('update-result').textContent).toContain('never replaces');
    expect(screen.queryByText('Update and restart')).toBeNull();
  });

  it('links the command-line tool', async () => {
    const core = fakeCore();
    render(Machine, { overview: overview(), notify: vi.fn(), onchange: vi.fn() });
    await tick();
    await fireEvent.click(screen.getByText('Install command-line tool'));
    await tick();
    expect(core.named('install_cli')).toHaveLength(1);
  });

  it('chooses the terminal: an installed one, or another by command, and tests it', async () => {
    const core = fakeCore();
    render(Machine, { overview: overview(), notify: vi.fn(), onchange: vi.fn() });
    await tick();
    const select = screen.getByLabelText('Terminal');
    await fireEvent.change(select, { target: { value: 'iTerm' } });
    await tick();
    await fireEvent.change(select, { target: { value: 'custom' } });
    await tick();
    await fireEvent.input(screen.getByLabelText('Terminal command'), { target: { value: 'wezterm start --' } });
    await fireEvent.click(screen.getByText('Save', { selector: '[data-testid="terminal"] button' }));
    await tick();
    expect(core.named('set_terminal')).toEqual([{ terminal: 'iTerm' }, { terminal: 'wezterm start --' }]);
    await fireEvent.click(screen.getByText('Test'));
    await tick();
    expect(core.named('terminal_test')).toHaveLength(1);
  });
});

