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

  it('offers import-v0 when 0.x is present, previewed first', async () => {
    const core = fakeCore();
    render(FirstRun, { notify: vi.fn(), ondone: vi.fn() });
    await tick();
    expect(screen.getByTestId('v0').textContent).toContain('remove the 0.x shell hook');
    await fireEvent.click(screen.getByText('Import aip 0.x profiles…'));
    await tick();
    answer(true);
    await tick();
    expect(core.named('import_v0')).toEqual([{ confirm: false }, { confirm: true }]);
  });

  it('without 0.x there is no import offer; clone needs a URL', async () => {
    const core = fakeCore({
      first_run: () => ({ harnesses: [], root: '/h/agent-personas', root_exists: false, v0_profiles: null, v0_hook: false }),
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
});
