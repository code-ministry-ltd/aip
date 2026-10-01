import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/svelte';
import StackView from './StackView.svelte';
import { mock } from '../lib/mock.js';

async function stack(harness, persona) {
  const v = await mock('folder_view', { folder: '/Users/jim/code/shop', persona });
  return v.stacks.find((s) => s.harness === harness);
}

describe('StackView', () => {
  it('shows the always-on total the core computed, and each outcome', async () => {
    const s = await stack('claude', 'coder');
    render(StackView, { stack: s });
    expect(screen.getByTestId('total').textContent).toBe(String(s.always_on_tokens));
    // The total is the sum of every copy that loads.
    const sum = s.rows.flatMap((r) => r.copies.filter((c) => c.loads)).reduce((n, c) => n + c.location.skill.always_on_tokens, 0);
    expect(s.always_on_tokens).toBe(sum);
    expect(screen.getByText(/BOTH load/)).toBeTruthy();
    expect(screen.getByText('Persona · coder')).toBeTruthy();
  });

  it('offers Resolve only on rows with more than one copy', async () => {
    const s = await stack('pi', 'coder');
    const onresolve = vi.fn();
    render(StackView, { stack: s, onresolve });
    const buttons = screen.getAllByText('Resolve…');
    expect(buttons).toHaveLength(s.rows.filter((r) => r.copies.length > 1).length);
    await fireEvent.click(buttons[0]);
    expect(onresolve).toHaveBeenCalledWith(expect.objectContaining({ name: 'review' }), expect.anything());
    expect(screen.getByText(/does not trust this folder/)).toBeTruthy();
  });

  it('marks copies that do not load', async () => {
    const s = await stack('pi', 'coder');
    const { container } = render(StackView, { stack: s });
    expect(container.querySelectorAll('.chip.off')).toHaveLength(1);
  });
});
