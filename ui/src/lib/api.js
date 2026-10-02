// The only way the UI reaches aip: Tauri commands into aip-core (plan D7).
// Outside Tauri (vite dev, tests) a fixture backend stands in, so every
// screen can be developed and tested without the app.

import { mock } from './mock.js';

const inTauri = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;

let backend = null;

/** Replace the backend (tests). */
export function setBackend(b) {
  backend = b;
}

async function call(cmd, args = {}) {
  if (backend) return backend(cmd, args);
  if (inTauri) {
    const { invoke } = await import('@tauri-apps/api/core');
    return invoke(cmd, args);
  }
  return mock(cmd, args);
}

export const api = {
  ready: () => call('ready'),
  overview: () => call('overview'),
  inventory: () => call('inventory'),
  folderView: (folder, persona) => call('folder_view', { folder, persona: persona || null }),
  personaDetail: (name) => call('persona_detail', { name }),
  personaEdit: (persona, skill, add, confirm) => call('persona_edit', { persona, skill, add, confirm }),
  personaSet: (persona, skills, confirm) => call('persona_set', { persona, skills, confirm }),
  personaCreate: (name, description, confirm) => call('persona_create', { name, description, confirm }),
  skillRm: (dir, confirm) => call('skill_rm', { dir, confirm }),
  skillCp: (dir, asName, confirm) => call('skill_cp', { dir, asName: asName || null, confirm }),
  skillDiff: (a, b) => call('skill_diff', { a, b }),
  undo: (confirm) => call('undo', { confirm }),
  history: () => call('history'),
  launch: (folder, target, persona) => call('launch', { folder, target, persona: persona || null }),
  trustPi: (folder) => call('trust_pi', { folder }),
  projectClear: (folder) => call('project_clear', { folder }),
  setWorkspaces: (workspaces, syncIntervalMinutes) =>
    call('set_workspaces', { workspaces, syncIntervalMinutes: syncIntervalMinutes ?? null }),
  setUpdateChecks: (enabled) => call('set_update_checks', { enabled }),
  syncNow: () => call('sync_now'),
  syncResolve: (choices) => call('sync_resolve', { choices }),
  pickContext: (dir) => call('pick_context', { dir }),
  integrations: () => call('integrations'),
  setIntegration: (name, enabled) => call('set_integration', { name, enabled }),
  reveal: (path) => call('reveal', { path }),
  closeWindow: () => call('close_window'),
  firstRun: () => call('first_run'),
  createRoot: () => call('create_root'),
  cloneRoot: (url) => call('clone_root', { url }),
  importV0: (confirm) => call('import_v0', { confirm }),
  cliStatus: () => call('cli_status'),
  installCli: () => call('install_cli'),
  updateStatus: () => call('update_status'),
  updateInstall: () => call('update_install'),
};

/** Ask the user for a folder (Tauri dialog; a prompt elsewhere). */
export async function chooseFolder(title = 'Choose a folder') {
  if (inTauri) {
    const { open } = await import('@tauri-apps/plugin-dialog');
    return open({ directory: true, multiple: false, title });
  }
  return window.prompt(title, '/Users/jim/code/shop');
}

/** Listen for an app event (no-op outside Tauri). Returns an unlisten function. */
export async function onEvent(name, fn) {
  if (!inTauri) return () => {};
  const { listen } = await import('@tauri-apps/api/event');
  return listen(name, (e) => fn(e.payload));
}
