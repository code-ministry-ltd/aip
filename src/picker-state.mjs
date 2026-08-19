// Pure, unit-testable logic for the aip import interactive file browser.
// The UI layer (src/picker.mjs) drives these functions; nothing here touches
// the terminal, so node --test can cover it deterministically.

import { readdirSync } from 'node:fs';
import path from 'node:path';

// List a directory as dirs/files with source-root-relative paths. Rel paths
// always use '/' separators (portable to the shell copy core and Windows).
// Non-regular entries (symlinks, sockets, ...) are skipped so the picker only
// ever offers real files.
export function listDir(absRoot, rel) {
  const abs = rel ? path.join(absRoot, rel) : absRoot;
  const dirs = [];
  const files = [];
  for (const entry of readdirSync(abs, { withFileTypes: true })) {
    if (entry.name === '.DS_Store') continue;
    const entryRel = rel ? `${rel}/${entry.name}` : entry.name;
    if (entry.isDirectory()) dirs.push({ name: entry.name, rel: entryRel });
    else if (entry.isFile()) files.push({ name: entry.name, rel: entryRel });
  }
  dirs.sort((a, b) => a.name.localeCompare(b.name));
  files.sort((a, b) => a.name.localeCompare(b.name));
  return { dirs, files };
}

// Toggle a relative path in a selection Set; returns a new Set.
export function toggleSelection(selected, rel) {
  const next = new Set(selected);
  if (next.has(rel)) next.delete(rel);
  else next.add(rel);
  return next;
}

// Merge a list of newly confirmed relative paths into an existing selection.
export function mergeSelection(selected, rels) {
  const next = new Set(selected);
  for (const rel of rels) next.add(rel);
  return next;
}

// Go up one directory level; '' is the source root itself.
export function upFrom(rel) {
  if (!rel) return rel;
  const idx = rel.lastIndexOf('/');
  return idx === -1 ? '' : rel.slice(0, idx);
}
