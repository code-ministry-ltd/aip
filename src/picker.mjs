// aip import interactive picker.
//
// Browsed by aip.sh / aip.ps1 when the user runs `aip import HARNESS` in a
// terminal: browse the harness config root, multi-select files (spacebar) and
// profiles, then emit NUL-separated records on stdout for the shell to act on.
//
//   node bin/aip-picker.js HARNESS SOURCE_ROOT [--all-profiles NAME... |
//                                                   --profiles a,b | NAME...]
//
// stdout: 'file\0<rel>\0' per selected file, 'profile\0<name>\0' per profile.
// exit: 0 selections emitted, 130 user cancelled, 1 error (message on stderr).
// All UI renders to stderr (clack), so stdout carries only the records.

import { intro, outro, cancel, isCancel, multiselect, select } from '@clack/prompts';
import { listDir, mergeSelection, upFrom } from './picker-state.mjs';

class Cancelled extends Error {}

const args = process.argv.slice(2);
const harness = args[0];
const sourceRoot = args[1];
if (!harness || !sourceRoot) {
  console.error('aip: usage: aip-picker.js HARNESS SOURCE_ROOT [--all-profiles|--profiles LIST|NAME...]');
  process.exit(1);
}

let allProfiles = false;
let profilesOpt = '';
const profileNames = [];
for (let i = 2; i < args.length; i++) {
  if (args[i] === '--all-profiles') allProfiles = true;
  else if (args[i] === '--profiles') {
    profilesOpt = args[i + 1] || '';
    i++;
  } else profileNames.push(args[i]);
}
const fixedProfiles = allProfiles
  ? profileNames
  : profilesOpt
    ? profilesOpt.split(',').filter(Boolean)
    : null;

const OUT = { output: process.stderr };

async function main() {
  intro(`aip import ${harness}`, OUT);
  let selected = new Set();
  let rel = '';

  while (true) {
    let listing;
    try {
      listing = listDir(sourceRoot, rel);
    } catch {
      cancel(`cannot read ${rel || sourceRoot}`);
      process.exit(1);
    }
    const picked = await multiselect({
      message: `Select files to import from ${rel || '.'}`,
      options: listing.files.map((f) => ({ value: f.rel, label: f.name })),
      required: false,
      ...OUT,
    });
    if (isCancel(picked)) throw new Cancelled();
    selected = mergeSelection(selected, picked);

    const navigation = await select({
      message: 'Where to next?',
      options: [
        ...(rel
          ? [{ value: '__up__', label: '⬆ go up one level' }]
          : []),
        ...listing.dirs.map((d) => ({ value: d.rel, label: `${d.name}/` })),
        { value: '__done__', label: '✅ done choosing files' },
      ],
      ...OUT,
    });
    if (isCancel(navigation)) throw new Cancelled();
    if (navigation === '__done__') break;
    rel = navigation === '__up__' ? upFrom(rel) : navigation;
  }

  if (selected.size === 0) {
    cancel('no files selected', OUT);
    process.exit(130);
  }

  let chosenProfiles = fixedProfiles;
  if (chosenProfiles === null) {
    const picked = await multiselect({
      message: 'Copy into which profiles?',
      options: [
        { value: '__all__', label: 'All profiles' },
        ...profileNames.map((n) => ({ value: n, label: n })),
      ],
      required: false,
      ...OUT,
    });
    if (isCancel(picked)) throw new Cancelled();
    chosenProfiles = picked.includes('__all__') ? profileNames : picked;
  }
  if (chosenProfiles.length === 0) {
    cancel('no profiles selected', OUT);
    process.exit(130);
  }

  const records = [];
  for (const relPath of selected) records.push('file', relPath);
  for (const name of chosenProfiles) records.push('profile', name);
  records.push('');
  process.stdout.write(records.join('\0'), () => {
    outro(`importing ${selected.size} file(s) into ${chosenProfiles.length} profile(s)`, OUT);
    process.exit(0);
  });
}

main().catch((error) => {
  if (error instanceof Cancelled) {
    cancel('import cancelled', OUT);
    process.exit(130);
  }
  console.error(`aip: interactive picker failed: ${error && error.message ? error.message : error}`);
  process.exit(1);
});
