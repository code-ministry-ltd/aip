import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent, within } from '@testing-library/svelte';
import Skills from './Skills.svelte';
import { fakeCore, overview, tick } from '../test/fake.js';

describe('Skills', () => {
  it('draws one lane per harness with every source type', async () => {
    fakeCore();
    render(Skills, { overview: overview(), notify: vi.fn(), onchange: vi.fn() });
    await tick();
    const claude = screen.getByTestId('lane-claude');
    const pi = screen.getByTestId('lane-pi');
    expect(within(claude).getByText('global')).toBeTruthy();
    expect(within(claude).getByText('claude.ai account')).toBeTruthy();
    expect(within(claude).getByText('plugin tools')).toBeTruthy();
    expect(within(pi).getByText('package pi-web-access')).toBeTruthy();
    expect(screen.getByText('testing')).toBeTruthy(); // a project skill
    expect(screen.getByText('citations')).toBeTruthy(); // a library skill
    expect(screen.getByTestId('account-note')).toBeTruthy();
    expect(screen.getByText(/Other folders \(1\)/)).toBeTruthy();
  });

  it('filters the inventory by search, source and duplicates', async () => {
    fakeCore();
    render(Skills, { overview: overview(), notify: vi.fn(), onchange: vi.fn() });
    await tick();
    await fireEvent.click(screen.getByText('All skills'));
    const all = screen.getAllByTestId('inv-row').length;
    expect(all).toBe(11);
    await fireEvent.click(screen.getByLabelText('Duplicates only'));
    expect(screen.getAllByTestId('inv-row')).toHaveLength(3);
    await fireEvent.click(screen.getByLabelText('Duplicates only'));
    await fireEvent.change(screen.getByLabelText('Source'), { target: { value: 'library' } });
    expect(screen.getAllByTestId('inv-row')).toHaveLength(4);
    await fireEvent.input(screen.getByLabelText('Search skills'), { target: { value: 'prose' } });
    expect(screen.getAllByTestId('inv-row')).toHaveLength(1);
  });

  it('folder view shows the core stacks for the chosen folder and persona', async () => {
    const core = fakeCore();
    render(Skills, { overview: overview(), notify: vi.fn(), onchange: vi.fn() });
    await tick();
    await fireEvent.click(screen.getByText('A folder'));
    await fireEvent.change(screen.getByLabelText('Folder'), { target: { value: '/Users/jim/code/shop' } });
    await fireEvent.change(screen.getByLabelText('Persona'), { target: { value: 'coder' } });
    await tick(10);
    expect(core.named('folder_view').at(-1)).toEqual({ folder: '/Users/jim/code/shop', persona: 'coder' });
    expect(screen.getAllByTestId('total').map((t) => t.textContent)).toEqual(['92', '21']);
    expect(screen.getByTestId('pi-trust')).toBeTruthy();
  });
});
