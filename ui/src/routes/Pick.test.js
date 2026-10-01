import { describe, it, expect, vi } from 'vitest';
import { render, fireEvent } from '@testing-library/svelte';
import Pick from './Pick.svelte';
import { fakeCore, tick } from '../test/fake.js';

const dir = '/Users/jim/code/shop';

async function open() {
  const core = fakeCore();
  render(Pick, { dir, notify: vi.fn() });
  await tick();
  return core;
}

const press = (key) => fireEvent.keyDown(window, { key });

describe('picker', () => {
  it('harness then persona launches through the core', async () => {
    const core = await open();
    await press('p');
    expect(core.named('launch')).toEqual([]);
    await press('2');
    await tick();
    expect(core.named('launch')).toEqual([{ folder: dir, target: 'pi', persona: 'writer' }]);
    expect(core.named('close_window')).toHaveLength(1);
  });

  it('persona then harness works too', async () => {
    const core = await open();
    await press('0');
    await press('d');
    await tick();
    expect(core.named('launch')).toEqual([{ folder: dir, target: 'claude-desktop', persona: null }]);
  });

  it('Enter launches the remembered choice; arrows change it', async () => {
    const core = await open();
    // Remembered: claude + coder.
    await press('ArrowDown'); // target column: claude -> pi
    await press('ArrowRight');
    await press('ArrowUp'); // persona column: coder -> none
    await press('Enter');
    await tick();
    expect(core.named('launch')).toEqual([{ folder: dir, target: 'pi', persona: null }]);
  });

  it('Escape closes without launching', async () => {
    const core = await open();
    await press('Escape');
    expect(core.named('launch')).toEqual([]);
    expect(core.named('close_window')).toHaveLength(1);
  });
});
