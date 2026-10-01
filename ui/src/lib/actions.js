// The actions offered on a skill copy, wherever it appears: the inventory,
// the scope map and flagged rows in the launch preview (spec SC13). Every
// change goes through preview-then-confirm and the same core operation as
// its CLI command.

import { api } from './api.js';
import { previewThenApply, show } from './dialog.svelte.js';
import { sourceLabel, tilde } from './format.js';

/** Run a change with its preview; report the outcome. */
export async function change(fn, { notify, onchange, danger = false, confirmLabel = 'Apply' }) {
  try {
    const r = await previewThenApply(fn, { danger, confirmLabel });
    if (r?.kind === 'done') {
      notify(`Done: ${r.summary}`, 'good');
      onchange?.();
    }
    return r;
  } catch (e) {
    notify(String(e), 'bad');
    return null;
  }
}

export async function compare(a, b, notify) {
  try {
    const text = await api.skillDiff(a.skill.dir, b.skill.dir);
    await show(`Compare ${a.skill.name}: ${sourceLabel(a.source)} ↔ ${sourceLabel(b.source)}`, text);
  } catch (e) {
    notify(String(e), 'bad');
  }
}

/**
 * Menu items for one copy of a skill.
 * `others` are the other copies with the same name (for Compare).
 * `personas` is the overview's persona list (for add/remove).
 */
export function skillMenu(loc, { personas = [], others = [], notify, onchange }) {
  const ctx = { notify, onchange };
  const s = loc.skill;
  const items = [{ heading: `${s.name} · ${sourceLabel(loc.source)}` }];

  for (const o of others) {
    items.push({ label: `Compare with ${sourceLabel(o.source)} copy`, run: () => compare(loc, o, notify) });
  }

  if (loc.source.kind === 'library') {
    const inP = personas.filter((p) => p.skills.includes(s.name));
    const outP = personas.filter((p) => !p.skills.includes(s.name) && !p.error);
    if (items.length > 1) items.push({ sep: true });
    for (const p of outP) {
      items.push({
        label: `Add to persona ${p.name}`,
        run: () => change((c) => api.personaEdit(p.name, s.name, true, c), ctx),
      });
    }
    for (const p of inP) {
      items.push({
        label: `Remove from persona ${p.name}`,
        run: () => change((c) => api.personaEdit(p.name, s.name, false, c), ctx),
      });
    }
  } else {
    items.push({
      label: 'Copy into the library',
      run: () => change((c) => api.skillCp(s.dir, null, c), ctx),
    });
  }

  items.push({ sep: true });
  items.push({ label: 'Reveal in file manager', run: () => api.reveal(s.dir).catch((e) => notify(String(e), 'bad')) });
  if (loc.read_only) {
    items.push({ label: `Managed by ${sourceLabel(loc.source)}`, disabled: true });
  } else {
    items.push({
      label: `Delete this copy (${tilde(s.dir)})`,
      danger: true,
      run: () => change((c) => api.skillRm(s.dir, c), { ...ctx, danger: true, confirmLabel: 'Move to Trash' }),
    });
  }
  return items;
}
