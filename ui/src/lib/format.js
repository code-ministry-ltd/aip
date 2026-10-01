// Small display helpers shared by every screen.

let home = '';

export function setHome(h) {
  home = h || '';
}

/** A path with the home folder shown as ~. */
export function tilde(p) {
  if (!p) return '';
  if (home && (p === home || p.startsWith(home + '/'))) return '~' + p.slice(home.length);
  return p;
}

export function last(p) {
  return (p || '').split('/').filter(Boolean).pop() || p;
}

export const harnessLabel = { claude: 'Claude Code', pi: 'Pi' };
export const targetLabel = { claude: 'Claude Code', pi: 'Pi', 'claude-desktop': 'Claude desktop' };

/** Plain label for a skill's source. */
export function sourceLabel(src) {
  switch (src.kind) {
    case 'user':
      return 'global';
    case 'account':
      return 'claude.ai account';
    case 'project':
      return 'project';
    case 'library':
      return 'library';
    case 'plugin':
      return `plugin ${src.id.split('@')[0]}${src.enabled ? '' : ' (off)'}`;
    case 'package':
      return `package ${src.id.replace(/^npm:/, '')}`;
    default:
      return src.kind;
  }
}

export function layerLabel(l) {
  switch (l.kind) {
    case 'everywhere':
      return 'Everywhere';
    case 'parent':
      return `Parent · ${last(l.path)}`;
    case 'folder':
      return `This folder · ${last(l.path)}`;
    case 'persona':
      return `Persona · ${l.name}`;
    default:
      return l.kind;
  }
}

export function tokens(n) {
  return n >= 1000 ? `${(n / 1000).toFixed(1)}k` : `${n}`;
}
