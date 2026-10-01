// One modal at a time: "here is exactly what will change — apply?"

export const dialog = $state({
  open: false,
  title: '',
  lines: [],
  body: '',
  confirmLabel: 'Apply',
  cancelLabel: 'Cancel',
  note: '',
  danger: false,
  resolve: null,
});

/** Show a preview and resolve to true (apply) or false (cancel). */
export function ask({
  title,
  lines = [],
  body = '',
  confirmLabel = 'Apply',
  cancelLabel = 'Cancel',
  note = 'You can undo this afterwards.',
  danger = false,
}) {
  return new Promise((resolve) => {
    Object.assign(dialog, { open: true, title, lines, body, confirmLabel, cancelLabel, note, danger, resolve });
  });
}

export function answer(yes) {
  const r = dialog.resolve;
  dialog.open = false;
  dialog.resolve = null;
  r?.(yes);
}

/**
 * The preview-then-confirm flow for any change: call `fn(false)` for the
 * plan, show it, and on Apply call `fn(true)`.
 */
export async function previewThenApply(fn, { confirmLabel = 'Apply', danger = false } = {}) {
  const first = await fn(false);
  if (first?.kind !== 'preview') return first;
  const ok = await ask({ title: first.plan.summary, lines: first.plan.preview, confirmLabel, danger });
  if (!ok) return null;
  return fn(true);
}

/** Show text with a single Close button. */
export function show(title, body) {
  return ask({ title, body, confirmLabel: 'Close', cancelLabel: '', note: '' });
}
