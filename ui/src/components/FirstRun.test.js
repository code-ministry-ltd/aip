import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/svelte';
import FirstRun from './FirstRun.svelte';
import { answer } from '../lib/dialog.svelte.js';
import { fakeCore, tick } from '../test/fake.js';

describe('first run', () => {
  it('shows the harnesses and creates a repository', async () => {
    const core = fakeCore();
    const ondone = vi.fn();
    render(FirstRun, { notify: vi.fn(), ondone });
    await tick();
    expect(screen.getByText('2.1.285 (Claude Code)')).toBeTruthy();
    expect(screen.getByText('not found on PATH')).toBeTruthy();
    await fireEvent.click(screen.getByText('Create it'));
    await tick();
    expect(core.named('create_root')).toHaveLength(1);
    expect(ondone).toHaveBeenCalled();
  });

  it('offers to convert local 0.x profiles and push them, previewed first', async () => {
    const core = fakeCore();
    render(FirstRun, { notify: vi.fn(), ondone: vi.fn() });
    await tick();
    const card = screen.getByTestId('v0').textContent;
    expect(card).toContain('push them to git@github.com:you/agent-profiles.git');
    expect(card).toContain('remove aip 0.x from this machine');
    await fireEvent.click(screen.getByText('Convert and push…'));
    await tick();
    answer(true);
    await tick();
    expect(core.named('import_v0')).toEqual([{ confirm: false }, { confirm: true }]);
  });

  it('without 0.x there is no import offer; clone needs a URL', async () => {
    const core = fakeCore({
      first_run: () => ({ harnesses: [], root: '/h/agent-personas', root_exists: false, v0_repo: false, v0_profiles: null, v0_remote: null, v0_install: false }),
    });
    render(FirstRun, { notify: vi.fn(), ondone: vi.fn() });
    await tick();
    expect(screen.queryByTestId('v0')).toBeNull();
    const clone = screen.getByText('Clone');
    expect(clone.disabled).toBe(true);
    await fireEvent.input(screen.getByLabelText('Repository URL'), { target: { value: 'git@example.com:me/p.git' } });
    await fireEvent.click(clone);
    await tick();
    expect(core.named('clone_root')).toEqual([{ url: 'git@example.com:me/p.git' }]);
  });

  it('local profiles without a remote are imported', async () => {
    fakeCore({
      first_run: () => ({ harnesses: [], root: '/h/agent-personas', root_exists: false, v0_repo: false, v0_profiles: '/h/agent-profiles', v0_remote: null, v0_install: false }),
    });
    render(FirstRun, { notify: vi.fn(), ondone: vi.fn() });
    await tick();
    expect(screen.getByText('Import aip 0.x profiles…')).toBeTruthy();
    expect(screen.getByTestId('v0').textContent).not.toContain('remove aip 0.x');
  });

  it('cloning a 0.x repository goes straight to converting it', async () => {
    let cloned = false;
    const core = fakeCore({
      clone_root: () => {
        cloned = true;
        return null;
      },
      first_run: () => ({ harnesses: [], root: '/h/agent-personas', root_exists: false, v0_repo: cloned, v0_profiles: null, v0_remote: null, v0_install: false }),
    });
    const ondone = vi.fn();
    render(FirstRun, { notify: vi.fn(), ondone });
    await tick();
    await fireEvent.input(screen.getByLabelText('Repository URL'), { target: { value: 'git@example.com:me/old.git' } });
    await fireEvent.click(screen.getByText('Clone'));
    await tick();
    // The preview is open; the card replaces the repository choices.
    expect(core.named('import_v0')).toEqual([{ confirm: false }]);
    expect(screen.getByText('Convert to personas…')).toBeTruthy();
    expect(screen.queryByText('Create it')).toBeNull();
    answer(true);
    await tick();
    expect(core.named('import_v0')).toEqual([{ confirm: false }, { confirm: true }]);
    expect(ondone).toHaveBeenCalled();
  });

  it('offers to remove a 0.x install when there is nothing to convert', async () => {
    fakeCore({
      first_run: () => ({ harnesses: [], root: '/h/agent-personas', root_exists: false, v0_repo: false, v0_profiles: null, v0_remote: null, v0_install: true }),
    });
    render(FirstRun, { notify: vi.fn(), ondone: vi.fn() });
    await tick();
    expect(screen.getByText('Remove aip 0.x…')).toBeTruthy();
    expect(screen.getByText('3. Your personas repository')).toBeTruthy();
  });
});
