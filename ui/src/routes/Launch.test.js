import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/svelte';
import Launch from './Launch.svelte';
import { fakeCore, overview, tick } from '../test/fake.js';
import { answer } from '../lib/dialog.svelte.js';

describe('Launch', () => {
  it('launches the chosen folder, target and persona through the core', async () => {
    const core = fakeCore();
    const notify = vi.fn();
    render(Launch, { overview: overview(), notify });
    await tick();
    await fireEvent.click(screen.getByRole('radio', { name: 'Pi' }));
    await fireEvent.change(screen.getByLabelText('Persona'), { target: { value: 'writer' } });
    await fireEvent.click(screen.getByText('Launch Pi'));
    await tick();
    expect(core.named('launch')).toEqual([{ folder: '/Users/jim/code/shop', target: 'pi', persona: 'writer', args: null }]);
    expect(notify).toHaveBeenCalledWith(expect.stringContaining('Started Pi with writer'), 'good');
  });

  it('right-click on a folder offers favourites and recent combinations first', async () => {
    const core = fakeCore();
    render(Launch, { overview: overview(), notify: vi.fn() });
    await tick();
    await fireEvent.contextMenu(screen.getByText('career'));
    const items = screen.getAllByRole('menuitem');
    expect(items[0].textContent).toBe('★ Career notes'); // favourites, then recent
    expect(items[1].textContent).toBe('Pi · writer (recent)');
    await fireEvent.click(items[1]);
    await tick();
    expect(core.named('launch')).toEqual([
      { folder: '/Users/jim/Documents/obsidian-md/research/career', target: 'pi', persona: 'writer', args: null },
    ]);
  });
});

describe('Launch favourites', () => {
  it('launches a favourite with its saved arguments', async () => {
    const core = fakeCore();
    render(Launch, { overview: overview(), notify: vi.fn() });
    await tick();
    await fireEvent.click(screen.getByText('★ Shop review'));
    await tick();
    expect(core.named('launch')).toEqual([
      { folder: '/Users/jim/code/shop', target: 'claude', persona: 'coder', args: ['--model', 'opus'] },
    ]);
  });

  it('saves the form as a favourite, arguments included', async () => {
    const core = fakeCore();
    render(Launch, { overview: overview(), notify: vi.fn() });
    await tick();
    await fireEvent.click(screen.getByRole('radio', { name: 'Pi' }));
    await fireEvent.input(screen.getByLabelText('Arguments'), { target: { value: '--thinking "very high"' } });
    await fireEvent.click(screen.getByText('☆ Save as favourite'));
    expect(screen.getByLabelText('Favourite name').value).toBe('shop · Pi · coder');
    await fireEvent.input(screen.getByLabelText('Favourite name'), { target: { value: 'Deep Pi' } });
    await fireEvent.click(screen.getByText('Save favourite'));
    await tick();
    expect(core.named('favourite_save')).toEqual([
      {
        favourite: { name: 'Deep Pi', dir: '/Users/jim/code/shop', target: 'pi', persona: 'coder', args: ['--thinking', 'very high'] },
        replacing: null,
      },
    ]);
    expect(core.named('favourites_list').length).toBe(2); // reloaded
  });

  it('edits and deletes through the right-click menu', async () => {
    const core = fakeCore();
    render(Launch, { overview: overview(), notify: vi.fn() });
    await tick();
    await fireEvent.contextMenu(screen.getByText('★ Shop review'));
    await fireEvent.click(screen.getByRole('menuitem', { name: 'Edit or rename…' }));
    expect(screen.getByLabelText('Arguments').value).toBe('--model opus');
    await fireEvent.input(screen.getByLabelText('Favourite name'), { target: { value: 'Review' } });
    await fireEvent.click(screen.getByText('Save changes'));
    await tick();
    expect(core.named('favourite_save')[0].replacing).toBe('Shop review');
    expect(core.named('favourite_save')[0].favourite.name).toBe('Review');

    await fireEvent.contextMenu(screen.getByText('★ Career notes'));
    await fireEvent.click(screen.getByRole('menuitem', { name: 'Delete' }));
    await tick();
    answer(true);
    await tick();
    expect(core.named('favourite_remove')).toEqual([{ name: 'Career notes' }]);
  });

  it('folder right-click lists that folder’s favourites first', async () => {
    fakeCore();
    render(Launch, { overview: overview(), notify: vi.fn() });
    await tick();
    await fireEvent.contextMenu(screen.getAllByText('shop')[0]);
    expect(screen.getAllByRole('menuitem')[0].textContent).toBe('★ Shop review');
  });

  it('lists favourites first in the side panel, launching in one click', async () => {
    const core = fakeCore();
    render(Launch, { overview: overview(), notify: vi.fn(), onchange: vi.fn() });
    await tick();
    const panel = screen.getByRole('region', { name: 'Favourites' });
    expect(panel.textContent).toContain('★ Shop review');
    await fireEvent.click(screen.getByText('★ Shop review'));
    await tick();
    expect(core.named('launch')).toHaveLength(1);
  });

  it('says how to add a favourite when there are none', async () => {
    fakeCore({ favourites_list: () => [] });
    render(Launch, { overview: overview(), notify: vi.fn(), onchange: vi.fn() });
    await tick();
    expect(screen.getByRole('region', { name: 'Favourites' }).textContent).toContain('Save as favourite');
  });
});

describe('Launch folders', () => {
  it('shows a folder chosen elsewhere and refreshes recent launches after launching', async () => {
    fakeCore();
    const onchange = vi.fn();
    render(Launch, { overview: overview(), notify: vi.fn(), onchange, folder: '/Users/jim/elsewhere/new-thing' });
    await tick();
    expect(screen.getAllByTitle('/Users/jim/elsewhere/new-thing').some((el) => el.tagName === 'BUTTON')).toBe(true);
    await fireEvent.click(screen.getByText(/^Launch /));
    await tick();
    expect(onchange).toHaveBeenCalledOnce();
  });
});

