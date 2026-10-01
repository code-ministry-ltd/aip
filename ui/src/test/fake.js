// A fake core for component tests: records every command and answers from
// the fixtures (or from `overrides`).
import { setBackend } from '../lib/api.js';
import { mock, fixtures } from '../lib/mock.js';

export function fakeCore(overrides = {}) {
  const calls = [];
  setBackend((cmd, args) => {
    calls.push([cmd, args]);
    if (cmd in overrides) return Promise.resolve(overrides[cmd](args));
    return mock(cmd, args);
  });
  return {
    calls,
    named: (cmd) => calls.filter(([c]) => c === cmd).map(([, a]) => a),
  };
}

export const overview = () => structuredClone(fixtures.overview);

export const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));
