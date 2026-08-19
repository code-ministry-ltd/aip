import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { listDir, toggleSelection, mergeSelection, upFrom } from '../../src/picker-state.mjs';

function makeTree() {
  const dir = mkdtempSync(join(tmpdir(), 'aip-picker-'));
  mkdirSync(join(dir, 'sub'));
  mkdirSync(join(dir, '.hidden'));
  mkdirSync(join(dir, 'sub', 'nested'));
  writeFileSync(join(dir, 'auth.json'), '');
  writeFileSync(join(dir, 'sub', 'b.md'), '');
  writeFileSync(join(dir, 'sub', 'nested', 'c.txt'), '');
  writeFileSync(join(dir, '.DS_Store'), '');
  symlinkSync(join(dir, 'auth.json'), join(dir, 'link.json'));
  return dir;
}

test('listDir splits dirs and files, sorted, with rel paths', () => {
  const dir = makeTree();
  try {
    const root = listDir(dir, '');
    assert.deepEqual(root.dirs.map((d) => d.name), ['.hidden', 'sub']);
    assert.deepEqual(root.dirs.map((d) => d.rel), ['.hidden', 'sub']);
    assert.deepEqual(root.files.map((f) => f.name), ['auth.json']);
    assert.deepEqual(root.files.map((f) => f.rel), ['auth.json']);

    const sub = listDir(dir, 'sub');
    assert.deepEqual(sub.dirs.map((d) => d.rel), ['sub/nested']);
    assert.deepEqual(sub.files.map((f) => f.rel), ['sub/b.md']);

    assert.deepEqual(listDir(dir, 'sub/nested').files.map((f) => f.rel), ['sub/nested/c.txt']);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('listDir skips non-regular entries (symlinks, .DS_Store)', () => {
  const dir = makeTree();
  try {
    const { files } = listDir(dir, '');
    assert.deepEqual(files.map((f) => f.name), ['auth.json']);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('listDir throws for a missing directory', () => {
  assert.throws(() => listDir('/definitely/not/here', ''));
});

test('toggleSelection adds and removes without mutating the input', () => {
  const base = new Set(['a']);
  const added = toggleSelection(base, 'b');
  assert.deepEqual([...added].sort(), ['a', 'b']);
  const removed = toggleSelection(added, 'a');
  assert.deepEqual([...removed], ['b']);
  assert.deepEqual([...base], ['a']);
});

test('mergeSelection accumulates rel paths', () => {
  const merged = mergeSelection(new Set(['a']), ['b', 'c']);
  assert.deepEqual([...merged].sort(), ['a', 'b', 'c']);
  assert.deepEqual([...mergeSelection(merged, ['a'])].sort(), ['a', 'b', 'c']);
});

test('upFrom walks back one level and stops at the root', () => {
  assert.equal(upFrom(''), '');
  assert.equal(upFrom('a.json'), '');
  assert.equal(upFrom('sub/nested'), 'sub');
  assert.equal(upFrom('sub'), '');
});
