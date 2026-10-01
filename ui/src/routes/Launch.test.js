import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/svelte';
import Launch from './Launch.svelte';
import { fakeCore, overview, tick } from '../test/fake.js';

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
    expect(core.named('launch')).toEqual([{ folder: '/Users/jim/code/shop', target: 'pi', persona: 'writer' }]);
    expect(notify).toHaveBeenCalledWith(expect.stringContaining('Started Pi with writer'), 'good');
  });

  it('right-click on a folder offers recent combinations first', async () => {
    const core = fakeCore();
    render(Launch, { overview: overview(), notify: vi.fn() });
    await tick();
    await fireEvent.contextMenu(screen.getByText('career'));
    const items = screen.getAllByRole('menuitem');
    expect(items[0].textContent).toBe('Pi · writer (recent)');
    await fireEvent.click(items[0]);
    await tick();
    expect(core.named('launch')).toEqual([
      { folder: '/Users/jim/Documents/obsidian-md/research/career', target: 'pi', persona: 'writer' },
    ]);
  });
});
