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

