import { afterEach } from 'vitest';
import { cleanup } from '@testing-library/svelte';
import { answer, dialog } from '../lib/dialog.svelte.js';

afterEach(() => {
  cleanup();
  if (dialog.open) answer(false);
});
