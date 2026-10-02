import { describe, it, expect } from 'vitest';
import { splitArgs, joinArgs } from './format.js';

describe('argument strings', () => {
  it('split like a shell and join back', () => {
    expect(splitArgs('--model opus')).toEqual(['--model', 'opus']);
    expect(splitArgs(`  -p "two words" 'it''s' a\\ b ""  `)).toEqual(['-p', 'two words', 'its', 'a b', '']);
    expect(splitArgs('')).toEqual([]);
    for (const args of [['--model', 'opus'], ['say', "it's here"], ['a b', '$HOME', '']]) {
      expect(splitArgs(joinArgs(args))).toEqual(args);
    }
  });
});
