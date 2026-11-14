import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/svelte';
import Personas from './Personas.svelte';
import { answer } from '../lib/dialog.svelte.js';
import { fakeCore, overview, tick } from '../test/fake.js';

describe('Personas', () => {
  it('updates the budget live and saves the whole list as one change', async () => {
    const core = fakeCore();
    const onchange = vi.fn();
    render(Personas, { overview: overview(), notify: vi.fn(), onchange });
    await tick();
    // coder = commit-messages (25) + review (9)
    expect(screen.getByTestId('persona-total').textContent).toBe('+34');
    await fireEvent.click(screen.getByLabelText(/prose/));
    expect(screen.getByTestId('persona-total').textContent).toBe('+63');
    // Pi ignores the persona's review (a global review exists): 21 + 25 + 29.
    expect(screen.getByTestId('total-pi').textContent).toBe('75');
    expect(screen.getByTestId('total-claude').textContent).toBe(String(47 + 63));
    await fireEvent.click(screen.getByText('Save'));
    await tick();
    answer(true);
    await tick();
    expect(core.named('persona_set')).toEqual([
      { persona: 'coder', skills: ['commit-messages', 'review', 'prose'], confirm: false },
      { persona: 'coder', skills: ['commit-messages', 'review', 'prose'], confirm: true },
    ]);
    expect(onchange).toHaveBeenCalledOnce();
  });

  it('cancelling a save writes nothing', async () => {
    const core = fakeCore();
    render(Personas, { overview: overview(), notify: vi.fn(), onchange: vi.fn() });
    await tick();
    await fireEvent.click(screen.getByLabelText(/review/));
    await fireEvent.click(screen.getByText('Save'));
    await tick();
    answer(false);
    await tick();
    expect(core.named('persona_set').map((a) => a.confirm)).toEqual([false]);
  });

  it('deletes a persona after a preview, then selects the next one', async () => {
    const core = fakeCore();
    const onchange = vi.fn();
    const ov = overview();
    render(Personas, { overview: ov, notify: vi.fn(), onchange });
    await tick();
    const first = ov.personas[0].name;
    await fireEvent.click(screen.getByText('Delete persona…'));
    await tick();
    answer(true);
    await tick();
    expect(core.named('persona_delete')).toEqual([
      { name: first, confirm: false },
      { name: first, confirm: true },
    ]);
    expect(onchange).toHaveBeenCalledOnce();
    const next = ov.personas.find((p) => p.name !== first)?.name;
    expect(screen.getByRole('heading', { name: next })).toBeTruthy();
  });
});

describe('Personas: a persona that cannot be read', () => {
  const broken = (missing) => {
    const o = overview();
    o.personas.unshift({
      name: 'thinking',
      description: '',
      skills: [],
      always_on_tokens: 0,
      warnings: [],
      error: "personas/thinking.toml: skill 'creative-thinking' is not in the library",
      missing_skills: missing,
    });
    return o;
  };

  it('offers to remove a missing skill instead of only deleting', async () => {
    const core = fakeCore();
    const onchange = vi.fn();
    render(Personas, { overview: broken(['creative-thinking']), notify: vi.fn(), onchange });
    await tick();
    await fireEvent.click(screen.getByText('Remove creative-thinking from thinking…'));
    await tick();
    answer(true);
    await tick();
    expect(core.named('persona_drop_missing')).toEqual([
      { name: 'thinking', confirm: false },
      { name: 'thinking', confirm: true },
    ]);
    expect(core.named('persona_delete')).toEqual([]);
    expect(onchange).toHaveBeenCalledOnce();
  });

  it('counts several missing skills', async () => {
    fakeCore();
    render(Personas, { overview: broken(['a', 'b']), notify: vi.fn(), onchange: vi.fn() });
    await tick();
    expect(screen.getByText('Remove 2 missing skills from thinking…')).toBeTruthy();
  });

  it('offers only Delete when nothing is missing (some other error)', async () => {
    fakeCore();
    render(Personas, { overview: broken([]), notify: vi.fn(), onchange: vi.fn() });
    await tick();
    expect(screen.queryByText(/^Remove /)).toBeNull();
    expect(screen.getByText('Delete persona…')).toBeTruthy();
  });
});

describe('Personas: unsent changes', () => {
  it('offers Sync now only while there are changes to send', async () => {
    fakeCore();
    render(Personas, { overview: overview(), notify: vi.fn(), onchange: vi.fn() });
    await tick();
    expect(screen.queryByText('Sync now')).toBeNull();
  });

  it('syncs and refreshes', async () => {
    const core = fakeCore({ sync_now: () => ({ outcome: 'pushed' }) });
    const notify = vi.fn();
    const onchange = vi.fn();
    const o = overview();
    o.sync.pending = true;
    render(Personas, { overview: o, notify, onchange });
    await tick();
    await fireEvent.click(screen.getByText('Sync now'));
    await tick();
    expect(core.named('sync_now')).toHaveLength(1);
    expect(notify).toHaveBeenCalledWith('Sent this machine’s changes.', 'good');
    expect(onchange).toHaveBeenCalled();
  });
});
