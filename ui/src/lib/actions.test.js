import { describe, it, expect, vi, beforeEach } from 'vitest';
import { skillMenu } from './actions.js';
import { dialog, answer } from './dialog.svelte.js';
import { fakeCore, overview, tick } from '../test/fake.js';
import { fixtures } from './mock.js';

const locs = fixtures.inventory.inventory.locations;
const globalReview = locs[0];
const libReview = locs.find((l) => l.source.kind === 'library' && l.skill.name === 'review');
const account = locs.find((l) => l.source.kind === 'account');

function item(items, label) {
  return items.find((i) => i.label && i.label.startsWith(label));
}

describe('skill actions', () => {
  let notify, onchange;
  beforeEach(() => {
    notify = vi.fn();
    onchange = vi.fn();
  });

  it('delete previews, and cancelling changes nothing', async () => {
    const core = fakeCore();
    const items = skillMenu(globalReview, { notify, onchange });
    item(items, 'Delete this copy').run();
    await tick();
    expect(dialog.open).toBe(true);
    answer(false);
    await tick();
    expect(core.named('skill_rm')).toEqual([{ dir: globalReview.skill.dir, confirm: false }]);
    expect(onchange).not.toHaveBeenCalled();
  });

  it('delete applies on confirmation through the same core operation', async () => {
    const core = fakeCore();
    item(skillMenu(globalReview, { notify, onchange }), 'Delete this copy').run();
    await tick();
    answer(true);
    await tick();
    expect(core.named('skill_rm').map((a) => a.confirm)).toEqual([false, true]);
    expect(core.named('skill_rm')[1].dir).toBe(globalReview.skill.dir);
    expect(onchange).toHaveBeenCalledOnce();
  });

  it('read-only copies cannot be deleted', () => {
    const items = skillMenu(account, { notify, onchange });
    expect(item(items, 'Delete')).toBeUndefined();
    expect(item(items, 'Managed by').disabled).toBe(true);
  });

  it('library skills offer persona add and remove; others offer copy into the library', async () => {
    const core = fakeCore();
    const personas = overview().personas;
    const lib = skillMenu(libReview, { personas, notify, onchange });
    expect(item(lib, 'Add to persona writer')).toBeTruthy();
    expect(item(lib, 'Remove from persona coder')).toBeTruthy();
    expect(item(lib, 'Copy into the library')).toBeUndefined();
    item(lib, 'Remove from persona coder').run();
    await tick();
    answer(true);
    await tick();
    expect(core.named('persona_edit')).toEqual([
      { persona: 'coder', skill: 'review', add: false, confirm: false },
      { persona: 'coder', skill: 'review', add: false, confirm: true },
    ]);
    const g = skillMenu(globalReview, { personas, notify, onchange });
    item(g, 'Copy into the library').run();
    await tick();
    answer(true);
    await tick();
    expect(core.named('skill_cp').map((a) => a.confirm)).toEqual([false, true]);
  });

  it('compare shows the core diff', async () => {
    const core = fakeCore();
    item(skillMenu(globalReview, { others: [libReview], notify, onchange }), 'Compare with library').run();
    await tick();
    expect(core.named('skill_diff')).toEqual([{ a: globalReview.skill.dir, b: libReview.skill.dir }]);
    expect(dialog.body).toBe('identical\n');
    answer(true);
  });
});
