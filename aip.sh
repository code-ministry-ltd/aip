# aip — AI Profile for Bash and Zsh. Source this file from your shell profile.

: "${_AIP_PROFILE_ROOT:=${HOME}/agent-profiles}"
_AIP_VERSION='0.4.0'
# Directory containing aip.sh at dot-source time; used to locate the interactive
# picker (bin/aip-picker.js) when it ships alongside the script.
case ${ZSH_VERSION-} in
  '') _AIP_PICKER_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) 2>/dev/null || _AIP_PICKER_DIR= ;;
  *) _AIP_PICKER_DIR=${0:A:h} ;;
esac

_aip_error() {
  _aip_spinner_stop
  printf 'aip: %s\n' "$*" >&2
}

_aip_warn() {
  _aip_spinner_stop
  printf 'aip: warning: %s\n' "$*" >&2
}

_aip_update() {
  [ "$#" -eq 0 ] || { _aip_error 'usage: aip update'; return 2; }
  (
    _aip_clear_git_routing
    if ! command -v npx >/dev/null 2>&1; then
      _aip_error 'update requires Node.js (npx) on PATH'
      return 1
    fi
    command npx --yes @code-ministry/aip@latest update
  )
}

_aip_version() {
  [ "$#" -eq 0 ] || { _aip_error 'usage: aip version'; return 2; }
  printf 'aip %s\n' "$_AIP_VERSION"
}

_aip_clear_git_routing() {
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
}

_aip_git() {
  command git "$@"
}

_aip_file_link_count() {
  command stat -c '%h' "$1" 2>/dev/null || command stat -f '%l' "$1" 2>/dev/null
}

_aip_find_hardlinked_git_metadata() {
  local profile=$1 entries file count
  entries=$(command mktemp "${TMPDIR:-/tmp}/aip-git-files.XXXXXX") || return 2
  command find "$profile/.git" -path "$profile/.git/objects" -prune -o -type f -print0 >|"$entries" || { command rm -f "$entries"; return 2; }
  # Cleanup unlinks the name; the loop keeps its already-open descriptor.
  # shellcheck disable=SC2094
  while IFS= read -r -d '' file; do
    count=$(_aip_file_link_count "$file") || { command rm -f "$entries"; return 2; }
    if [ "$count" -gt 1 ]; then
      printf '%s\n' "$file"
      command rm -f "$entries"
      return 0
    fi
  done <"$entries"
  command rm -f "$entries"
  return 1
}

_aip_prepare_ssh_transport() {
  local profile=$1 effective variant executable command_prefix command_remainder quoted
  effective=${GIT_SSH_COMMAND-}
  if [ -z "$effective" ]; then
    effective=$(_aip_git -C "$profile" config --get core.sshCommand 2>/dev/null) || effective=
  fi
  if [ -z "$effective" ] && [ -n "${GIT_SSH-}" ]; then
    executable=$(printf '%s' "$GIT_SSH" | command sed "s/'/'\\\\''/g") || return
    effective="'$executable'"
  fi
  [ -n "$effective" ] || effective=ssh

  case $effective in
    \"*)
      quoted=${effective#\"}; executable=${quoted%%\"*}
      command_prefix="\"$executable\""; command_remainder=${quoted#*\"}
      ;;
    \'*)
      quoted=${effective#\'}; executable=${quoted%%\'*}
      command_prefix="'$executable'"; command_remainder=${quoted#*\'}
      ;;
    *)
      executable=${effective%%[[:space:]]*}
      command_prefix=$executable; command_remainder=${effective#"$executable"}
      ;;
  esac

  variant=${GIT_SSH_VARIANT-}
  if [ -z "$variant" ]; then
    variant=$(_aip_git -C "$profile" config --get ssh.variant 2>/dev/null) || variant=
  fi
  if [ -z "$variant" ] || [ "$variant" = auto ]; then
    executable=${executable##*/}
    _aip_ascii_lower "$executable"
    case $_AIP_ASCII_LOWER in
      plink|plink.exe|putty|putty.exe) variant=plink ;;
      tortoiseplink|tortoiseplink.exe) variant=tortoiseplink ;;
      *) variant=ssh ;;
    esac
  fi
  _aip_ascii_lower "$variant"
  case $_AIP_ASCII_LOWER in
    plink|putty|tortoiseplink) effective="$command_prefix -batch$command_remainder" ;;
    ssh) effective="$command_prefix -o BatchMode=yes$command_remainder" ;;
    *) return 1 ;;
  esac
  _AIP_SSH_COMMAND=$effective
  _AIP_SSH_VARIANT=$variant
}

_aip_require_git_mutation_state() {
  local profile=$1 relative metadata_path lock_file
  _aip_git_is_contained "$profile" || { _aip_error "$_AIP_GIT_CONTAINMENT_ERROR"; return 1; }
  for relative in FETCH_HEAD ORIG_HEAD MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_START index; do
    metadata_path=$profile/.git/$relative
    if { [ -e "$metadata_path" ] || [ -L "$metadata_path" ]; } && { [ ! -f "$metadata_path" ] || [ -L "$metadata_path" ]; }; then
      _aip_error "Git metadata path must be an ordinary file before remote sync: $metadata_path"
      return 1
    fi
  done
  lock_file=$(command find "$profile/.git" -path "$profile/.git/aip-sync.lock" -prune -o -name '*.lock' -print -quit 2>/dev/null) || {
    _aip_error "Git metadata locks could not be inspected: $profile/.git"
    return 1
  }
  if [ -n "$lock_file" ]; then
    _aip_error "local Git operation is blocked by an existing lock file; inspect: $lock_file"
    return 1
  fi
  for metadata_path in "$profile/.git" "$profile/.git/objects" "$profile/.git/refs"; do
    [ -d "$metadata_path" ] || {
      _aip_error "Git metadata is not writable for remote sync: $metadata_path"
      return 1
    }
    relative=$(command mktemp "$metadata_path/.aip-write-probe.XXXXXX") || { _aip_error "Git metadata is not writable for remote sync: $metadata_path"; return 1; }
    command rm -f "$relative" || return 1
  done
  _aip_git -C "$profile" status --porcelain >/dev/null 2>&1 || {
    _aip_error "local Git repository became unreadable during remote sync: $profile"
    return 1
  }
  _aip_git -C "$profile" fsck --connectivity-only --no-dangling >/dev/null 2>&1 || {
    _aip_error "local Git repository failed its integrity check during remote sync: $profile"
    return 1
  }
}

_aip_mount_target_is_profile_or_descendant() {
  [ "$2" = "$1" ] || case $2 in "$1"/*) true ;; *) false ;; esac
}

_aip_require_no_nested_mounts() {
  local root=$1 root_physical mounts target
  root_physical=$(builtin cd "$root" 2>/dev/null && builtin pwd -P) || {
    _aip_error "profiles directory is unreadable: $root"
    return 1
  }
  mounts=$(command mktemp "${TMPDIR:-/tmp}/aip-mounts.XXXXXX") || return
  if [ -r /proc/self/mountinfo ]; then
    command awk '{ print $5 }' /proc/self/mountinfo >|"$mounts" || { command rm -f "$mounts"; return 1; }
    # Cleanup unlinks the name; the loop keeps its already-open descriptor.
    # shellcheck disable=SC2094
    while IFS= read -r target; do
      target=$(printf '%s\n' "$target" | command sed 's/\\040/ /g; s/\\134/\\/g')
      if _aip_mount_target_is_profile_or_descendant "$root_physical" "$target"; then
        command rm -f "$mounts"
        _aip_error "profiles directory is or contains a mount point and cannot be staged or deleted safely: $target"
        return 1
      fi
    done <"$mounts"
  elif command mount >|"$mounts" 2>/dev/null; then
    # Cleanup unlinks the name; the loop keeps its already-open descriptor.
    # shellcheck disable=SC2094
    while IFS= read -r target; do
      target=$(printf '%s\n' "$target" | command sed -n 's/^.* on \(.*\) ([^()]*)$/\1/p')
      if _aip_mount_target_is_profile_or_descendant "$root_physical" "$target"; then
        command rm -f "$mounts"
        _aip_error "profiles directory is or contains a mount point and cannot be staged or deleted safely: $target"
        return 1
      fi
    done <"$mounts"
  else
    command rm -f "$mounts"
    _aip_error 'could not inspect mount points before a recursive profiles directory operation'
    return 1
  fi
  command rm -f "$mounts"
}

_aip_git_is_contained() {
  local repository=$1 top git_dir common_dir expected_top expected_git actual_top actual_git actual_common linked_metadata hardlinked_metadata alternate
  _AIP_GIT_CONTAINMENT_ERROR=
  top=$(_aip_git -C "$repository" rev-parse --show-toplevel 2>/dev/null) || { _AIP_GIT_CONTAINMENT_ERROR="Git repository is unreadable: $repository"; return 1; }
  git_dir=$(_aip_git -C "$repository" rev-parse --absolute-git-dir 2>/dev/null) || { _AIP_GIT_CONTAINMENT_ERROR="Git repository is unreadable: $repository"; return 1; }
  common_dir=$(_aip_git -C "$repository" rev-parse --git-common-dir 2>/dev/null) || { _AIP_GIT_CONTAINMENT_ERROR="Git repository is unreadable: $repository"; return 1; }
  expected_top=$(builtin cd "$repository" 2>/dev/null && builtin pwd -P) || { _AIP_GIT_CONTAINMENT_ERROR="profiles directory is unreadable: $repository"; return 1; }
  expected_git=$(builtin cd "$repository/.git" 2>/dev/null && builtin pwd -P) || { _AIP_GIT_CONTAINMENT_ERROR="Git metadata is unreadable: $repository/.git"; return 1; }
  actual_top=$(builtin cd "$top" 2>/dev/null && builtin pwd -P) || { _AIP_GIT_CONTAINMENT_ERROR="configured Git worktree is unreadable: $top"; return 1; }
  actual_git=$(builtin cd "$git_dir" 2>/dev/null && builtin pwd -P) || { _AIP_GIT_CONTAINMENT_ERROR="configured Git metadata is unreadable: $git_dir"; return 1; }
  case $common_dir in /*) ;; *) common_dir=$repository/$common_dir ;; esac
  actual_common=$(builtin cd "$common_dir" 2>/dev/null && builtin pwd -P) || { _AIP_GIT_CONTAINMENT_ERROR="configured common Git metadata is unreadable: $common_dir"; return 1; }
  if [ "$actual_top" != "$expected_top" ] || [ "$actual_git" != "$expected_git" ] || [ "$actual_common" != "$expected_git" ]; then
    _AIP_GIT_CONTAINMENT_ERROR='Git repository routing escapes the profiles repository; remove core.worktree or external Git routing'
    return 1
  fi
  linked_metadata=$(command find "$repository/.git" -type l -print -quit 2>/dev/null) || { _AIP_GIT_CONTAINMENT_ERROR="Git metadata is unreadable: $repository/.git"; return 1; }
  if [ -n "$linked_metadata" ]; then
    _AIP_GIT_CONTAINMENT_ERROR="Git metadata contains a symbolic link; remove or repair: $linked_metadata"
    return 1
  fi
  hardlinked_metadata=$(_aip_find_hardlinked_git_metadata "$repository")
  case $? in
    0)
      _AIP_GIT_CONTAINMENT_ERROR="Git metadata contains a hard-linked mutable file; replace it with an independent copy: $hardlinked_metadata"
      return 1
      ;;
    2)
      _AIP_GIT_CONTAINMENT_ERROR="Git metadata hard links could not be inspected: $repository/.git"
      return 1
      ;;
  esac
  for alternate in "$repository/.git/objects/info/alternates" "$repository/.git/objects/info/http-alternates"; do
    if [ -e "$alternate" ] || [ -L "$alternate" ]; then
      _AIP_GIT_CONTAINMENT_ERROR="Git object alternates escape the profiles repository; remove: $alternate"
      return 1
    fi
  done
}

_aip_require_git_containment() {
  _aip_git_is_contained "$1" || {
    _aip_error "$_AIP_GIT_CONTAINMENT_ERROR"
    return 1
  }
}

_aip_require_root_repo() {
  { [ -d "$_AIP_PROFILE_ROOT" ] && [ -d "$_AIP_PROFILE_ROOT/.git" ] && [ ! -L "$_AIP_PROFILE_ROOT/.git" ]; } || {
    _aip_error "profiles directory is not a Git repository: $_AIP_PROFILE_ROOT; run 'aip create NAME' or 'aip doctor'"
    return 2
  }
}

_aip_list_profile_names() {
  local profile_path name entries
  [ -d "$_AIP_PROFILE_ROOT" ] || return 0
  entries=$(command mktemp "${TMPDIR:-/tmp}/aip-profiles.XXXXXX") || return 1
  command find -H "$_AIP_PROFILE_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 >|"$entries" || { command rm -f "$entries"; return 1; }
  # Cleanup unlinks the name; the loop keeps its already-open descriptor.
  # shellcheck disable=SC2094
  while IFS= read -r -d '' profile_path; do
    [ ! -L "$profile_path" ] || continue
    name=${profile_path##*/}
    _aip_validate_name "$name" || continue
    { [ -e "$profile_path/.aip/outfit" ] || [ -L "$profile_path/.aip/outfit" ]; } || continue
    printf '%s\n' "$name"
  done <"$entries"
  command rm -f "$entries"
}

_aip_write_root_gitignore() {
  printf '%s\n' \
    '# aip-managed root exclusions' \
    '.default' \
    '.aip-*/' \
    >"$_AIP_PROFILE_ROOT/.gitignore"
}

_aip_ensure_root_repo() {
  local root=$_AIP_PROFILE_ROOT
  command mkdir -p "$root" || return 1
  if [ -L "$root/.git" ]; then
    _aip_error 'profiles repository metadata must not be a symbolic link: %s' "$root/.git"
    return 1
  fi
  if [ ! -d "$root/.git" ]; then
    if ! _aip_git -C "$root" init -q -b main ||
       ! _aip_git -C "$root" config core.symlinks true ||
       ! _aip_git -C "$root" config core.longpaths true; then
      return 1
    fi
  fi
  _aip_git -C "$root" var GIT_AUTHOR_IDENT >/dev/null 2>&1 || {
    _aip_error "configure Git identity with 'git config --global user.name NAME' and 'git config --global user.email EMAIL'"
    return 1
  }
  { [ -e "$root/.gitignore" ] || [ -L "$root/.gitignore" ]; } || _aip_write_root_gitignore || return 1
}

_aip_validate_name() {
  local value=${1-}
  [ -n "$value" ] || return 1
  case $value in *$'\n'*|*$'\r'*) return 1 ;; esac
  LC_ALL=C printf '%s\n' "$value" | command grep -Eq '^[a-z0-9]([a-z0-9_-]{0,62}[a-z0-9])?$' || return 1
  case $value in con|prn|aux|nul|com[1-9]|lpt[1-9]) return 1 ;; esac
}

_aip_find_utf8_locale() {
  local candidate charmap
  for candidate in C.UTF-8 C.utf8 en_US.UTF-8 UTF-8; do
    charmap=$(LC_ALL=$candidate command locale charmap 2>/dev/null) || continue
    case $charmap in UTF-8|UTF8|utf-8|utf8)
      printf '%s\n' "$candidate"
      return 0
      ;;
    esac
  done
  return 1
}

_aip_utf8_length() (
  local value=${1-} utf8_locale
  utf8_locale=$(_aip_find_utf8_locale) || return
  LC_ALL=$utf8_locale
  export LC_ALL
  printf '%s' "$value" | command iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || return 1
  # Reject C0/C1 controls and DEL by codepoint. The locale's [[:cntrl:]] class is
  # not portable (e.g. macOS en_US.UTF-8 does not classify U+0085 as control),
  # so walk the UTF-8 bytes explicitly; iconv above guarantees they are valid.
  printf '%s' "$value" | command od -A n -t u1 -v | command awk '
    { for (i = 1; i <= NF; i++) byte[n++] = $i + 0 }
    END {
      i = 0
      while (i < n) {
        c = byte[i]
        if (c >= 128 && c < 192) { i++; continue }
        if (c < 128) { cp = c; len = 1 }
        else if (c < 224) { cp = c - 192; len = 2 }
        else if (c < 240) { cp = c - 224; len = 3 }
        else { cp = c - 240; len = 4 }
        for (j = 1; j < len; j++) cp = cp * 64 + (byte[i + j] - 128)
        i += len
        if (cp < 32 || cp == 127 || (cp >= 128 && cp <= 159)) exit 1
      }
    }' || return 1
  printf '%s\n' "${#value}"
)

_aip_validate_outfit() {
  local length
  [ -n "${1-}" ] || return 1
  length=$(_aip_utf8_length "$1") || return 1
  [ "$length" -le 64 ] || return 1
}

_aip_validate_utf8_text_file() {
  local file=$1
  command iconv -f UTF-8 -t UTF-8 "$file" >/dev/null 2>&1 || return 1
  command od -A n -t u1 -v "$file" | command awk '{ for (i = 1; i <= NF; i++) if ($i == 0) invalid = 1 } END { exit invalid }'
}

_aip_profile_path() {
  printf '%s/%s\n' "$_AIP_PROFILE_ROOT" "$1"
}

_aip_read_name_file() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  local first extra
  _aip_validate_utf8_text_file "$1" || return 1
  {
    IFS= read -r first || [ -n "$first" ] || return 1
    if IFS= read -r extra || [ -n "$extra" ]; then
      : "$extra"
      return 1
    fi
  } <"$1"
  first=${first%"$(printf '\r')"}
  _aip_validate_name "$first" || return 1
  printf '%s\n' "$first"
}

_aip_read_outfit() {
  local outfit extra parent=${1%/*}
  { [ -d "$parent" ] && [ ! -L "$parent" ] && [ -f "$1" ] && [ ! -L "$1" ]; } || return 1
  _aip_validate_utf8_text_file "$1" || return 1
  {
    IFS= read -r outfit || [ -n "$outfit" ] || return 1
    if IFS= read -r extra || [ -n "$extra" ]; then return 1; fi
  } <"$1"
  outfit=${outfit%"$(printf '\r')"}
  _aip_validate_outfit "$outfit" || return 1
  printf '%s\n' "$outfit"
}

_aip_is_required_profile_link() {
  case ${1-} in
    claude/skills|codex/AGENTS.md|codex/skills|pi/AGENTS.md|pi/skills|opencode/AGENTS.md|opencode/skills) return 0 ;;
    *) return 1 ;;
  esac
}

_aip_check_live_profile_links() {
  local profile=$1 entries link_path relative
  entries=$(command mktemp "${TMPDIR:-/tmp}/aip-links.XXXXXX") || return
  command find "$profile" -path "$profile/.git" -prune -o -type l -print0 >|"$entries" || { command rm -f "$entries"; return 1; }
  # Cleanup unlinks the name; the loop keeps its already-open descriptor.
  # shellcheck disable=SC2094
  while IFS= read -r -d '' link_path; do
    relative=${link_path#"$profile"/}
    if ! _aip_is_required_profile_link "$relative" && ! _aip_is_passthrough_link "$relative" "$profile"; then
      command rm -f "$entries"
      _aip_error "profile contains an unsupported symbolic link that could escape its boundary: $relative"
      return 1
    fi
  done <"$entries"
  command rm -f "$entries"
}

_aip_passthrough_rels() {
  # The per-harness pass-through allowlist: machine-local configuration inputs that
  # every profile falls back to unless it defines the path itself. Names are matched
  # without a trailing slash; each maps to the same relative path under the harness
  # default root. Only these paths may ever be linked by pass-through maintenance.
  case ${1-} in
    pi) printf '%s\n' models.json auth.json settings.json themes prompts extensions ;;
    claude) printf '%s\n' settings.json settings.local.json .credentials.json agents commands context-mode output-styles workflows keybindings.json plugins ;;
    codex) printf '%s\n' config.toml auth.json plugins ;;
    opencode) printf '%s\n' opencode.json auth.json tui.json agent command plugins ;;
    *) return 1 ;;
  esac
}

_aip_relative_path() {
  # $1 from-directory, $2 target path (both absolute); prints the relative path from
  # $1 to $2 (e.g. from ~/agent-profiles/work/pi to ~/.pi/agent/models.json prints
  # ../../../.pi/agent/models.json). POSIX-only helper; no dependency on GNU realpath.
  local from=$1 to=$2 from_rest to_rest result='' component
  case $from in /*) ;; *) from=$PWD/$from ;; esac
  case $to in /*) ;; *) to=$PWD/$to ;; esac
  from=${from%/}
  to=${to%/}
  from_rest=${from#/}
  to_rest=${to#/}
  while [ -n "$from_rest" ] && [ -n "$to_rest" ]; do
    [ "${from_rest%%/*}" = "${to_rest%%/*}" ] || break
    case $from_rest in
      */*) from_rest=${from_rest#*/} ;;
      *) from_rest= ;;
    esac
    case $to_rest in
      */*) to_rest=${to_rest#*/} ;;
      *) to_rest= ;;
    esac
  done
  result=$to_rest
  while [ -n "$from_rest" ]; do
    case $from_rest in
      */*) component=${from_rest%%/*}; from_rest=${from_rest#*/} ;;
      *) component=$from_rest; from_rest= ;;
    esac
    [ -n "$component" ] || break
    result=../$result
  done
  [ -n "$result" ] || result=.
  printf '%s\n' "$result"
}

_aip_normalize_path() {
  # Prints $1 with '.' and '..' components resolved lexically (POSIX, no filesystem
  # access). Requires an absolute path; root-level '..' is ignored.
  local input=$1 out='' comp remaining
  case $input in /*) ;; *) return 1 ;; esac
  remaining=${input#/}
  while [ -n "$remaining" ]; do
    comp=${remaining%%/*}
    case $remaining in */*) remaining=${remaining#*/} ;; *) remaining= ;; esac
    if [ -z "$comp" ] || [ "$comp" = . ]; then continue
    elif [ "$comp" = .. ]; then
      case $out in
        */*) out=${out%/*} ;;
        *) out= ;;
      esac
    else
      out=${out:+$out/}$comp
    fi
  done
  printf '/%s\n' "$out"
}

_aip_resolve_path() {
  # Portable canonical resolution (macOS has no readlink -f): follows the final
  # symlink chain (bounded, so loops cannot hang) then normalises lexically. Broken
  # links resolve to their lexical target, which is exactly what the pass-through
  # boundary needs to accept or reject them.
  local path=$1 link depth=0
  case $path in /*) ;; *) path=$PWD/$path ;; esac
  while [ -L "$path" ] && [ "$depth" -lt 40 ]; do
    link=$(command readlink "$path") || return 1
    case $link in
      /*) path=$link ;;
      *) path=${path%/*}/$link ;;
    esac
    depth=$((depth + 1))
  done
  _aip_normalize_path "$path"
}

_aip_is_passthrough_link() {
  # $1 relative link path (e.g. pi/models.json), $2 profile path. Returns 0 when the
  # link is a pass-through link: allowlisted rel whose target is confined to the
  # harness default root. Accepts broken links whose raw target is exactly the
  # expected relative path; for absolute targets the canonical target must resolve
  # under the root, and when it cannot resolve (broken link) the raw target must stay
  # inside the root after lexical ..-normalisation (so crafted ../ escapes are
  # rejected even when the escape path does not exist).
  local relative=$1 profile=$2 harness rel root expected raw canonical resolved_root
  harness=${relative%%/*}
  rel=${relative#*/}
  case $harness in pi|claude|codex|opencode) ;; *) return 1 ;; esac
  case $rel in */*|'') return 1 ;; esac
  _aip_passthrough_rels "$harness" | command grep -Fxq "$rel" || return 1
  root=$(_aip_import_harness_root "$harness") || return 1
  [ -n "$root" ] || return 1
  resolved_root=$(_aip_resolve_path "$root") || resolved_root=$root
  expected=$(_aip_relative_path "$profile/$harness" "$root/$rel")
  raw=$(command readlink "$profile/$relative" 2>/dev/null) || return 1
  [ "$raw" = "$expected" ] && return 0
  canonical=$(_aip_resolve_path "$profile/$relative") || return 1
  case $canonical in "$resolved_root"/*) return 0 ;; *) return 1 ;; esac
}

_AIP_PASSTHROUGH_BEGIN='# aip pass-through (machine-local, do not sync) BEGIN'
_AIP_PASSTHROUGH_END='# aip pass-through END'

_aip_gitignore_passthrough_entries() {
  # $1 = .gitignore path; prints the current pass-through entries, one per line.
  local gitignore=$1
  [ -f "$gitignore" ] || return 0
  command awk -v begin="$_AIP_PASSTHROUGH_BEGIN" -v end="$_AIP_PASSTHROUGH_END" '
    $0 == begin { in_block = 1; next }
    in_block && $0 == end { in_block = 0; next }
    in_block && $0 != "" { print }
  ' "$gitignore"
}

_aip_gitignore_set_passthrough_block() {
  # $1 = .gitignore path, $2 = entries file (newline-separated, may be absent/empty).
  # Rewrites only the marked block in place; every other line is preserved verbatim.
  local gitignore=$1 entries=$2 temporary has_entries=0
  [ -f "$gitignore" ] || return 1
  if [ -n "$entries" ] && [ -s "$entries" ]; then has_entries=1; fi
  temporary=$(command mktemp "${gitignore}.XXXXXX") || return 1
  command awk -v begin="$_AIP_PASSTHROUGH_BEGIN" -v end="$_AIP_PASSTHROUGH_END" -v entries="$entries" -v has="$has_entries" '
    $0 == begin { in_block = 1; next }
    in_block && $0 == end { in_block = 0; next }
    in_block { next }
    { print }
    END {
      if (!has) exit
      print begin
      while ((getline line < entries) > 0) print line
      close(entries)
      print end
    }
  ' "$gitignore" >"$temporary" || { command rm -f "$temporary"; return 1; }
  command mv "$temporary" "$gitignore" || { command rm -f "$temporary"; return 1; }
}

_aip_gitignore_remove_passthrough_entry() {
  # $1 = .gitignore path, $2 = harness-qualified entry (e.g. pi/models.json).
  # Removes one entry from the pass-through block; leaves the block empty/removed
  # when it held only that entry. Used by aip import when a profile-owned copy
  # replaces a pass-through link.
  local gitignore=$1 rel=$2 current entries
  current=$(_aip_gitignore_passthrough_entries "$gitignore")
  entries=$(command mktemp "${TMPDIR:-/tmp}/aip-passthrough-entries.XXXXXX") || return 1
  : >|"$entries"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ "$entry" = "$rel" ] || printf '%s\n' "$entry" >>"$entries"
  done <<EOF
$current
EOF
  _aip_gitignore_set_passthrough_block "$gitignore" "$entries" || { command rm -f "$entries"; return 1; }
  command rm -f "$entries"
}

_aip_passthrough() {
  # $1 harness, $2 profile name. Ensures the profile's pass-through links for one
  # harness match the machine-local default root: creates missing links (never
  # overwriting an existing path, skipping paths already tracked in Git), removes
  # broken links with a warning, and reconciles the profile's .gitignore block.
  # Never fails: problems warn and the caller proceeds (pass-through is a fallback).
  local harness=$1 name=$2 profile_path root rel source dest expected
  local current entries removed_this_run='' link_rel
  profile_path=$(_aip_profile_path "$name")
  root=$(_aip_import_harness_root "$harness") || return 0
  [ -d "$root" ] || return 0
  [ -d "$profile_path/$harness" ] || return 0

  # 1. Remove broken pass-through links (their raw target is a pass-through target but
  #    the machine-local file or directory is gone). Removing first lets a link be
  #    re-created below when the default path comes back.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    dest=$profile_path/$harness/$rel
    if [ -L "$dest" ] && _aip_is_passthrough_link "$harness/$rel" "$profile_path" && [ ! -e "$dest" ]; then
      if command rm -f "$dest" 2>/dev/null; then
        _aip_warn "removed stale pass-through link $name/$harness/$rel (its machine-local target is gone)"
        removed_this_run=${removed_this_run:+$removed_this_run }$harness/$rel
      else
        _aip_warn "could not remove stale pass-through link $name/$harness/$rel"
      fi
    fi
  done < <(_aip_passthrough_rels "$harness")

  # 2. Create missing links for allowlisted paths that exist in the default root and
  #    are absent from the profile (or were just removed as broken). A real file or
  #    directory in the profile shadows the link; a path already tracked in Git is
  #    exempt (the profile owns it and keeps syncing it).
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    dest=$profile_path/$harness/$rel
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      continue  # existing path shadows the link (profile precedence)
    fi
    [ -e "$root/$rel" ] || continue
    if _aip_git -C "$_AIP_PROFILE_ROOT" ls-files --error-unmatch -- "$name/$harness/$rel" >/dev/null 2>&1; then
      continue
    fi
    expected=$(_aip_relative_path "$profile_path/$harness" "$root/$rel")
    if ! command ln -s "$expected" "$dest" 2>/dev/null; then
      _aip_warn "could not create pass-through link $name/$harness/$rel -> $expected"
    fi
  done < <(_aip_passthrough_rels "$harness")

  # 3. Reconcile the .gitignore block. Entries are harness-qualified (pi/models.json,
  #    codex/auth.json, …) so a name like auth.json never collides across harnesses.
  #    Convergent rule: an entry is added when a pass-through link exists (and the
  #    path is untracked); removed when the path exists but is not a pass-through
  #    link (profile override), is tracked, or was just removed as broken; and
  #    otherwise left exactly as it is (absent paths keep their entry state so
  #    machines without the default file never fight machines that have it). Other
  #    harnesses' entries are preserved untouched.
  current=$(_aip_gitignore_passthrough_entries "$profile_path/.gitignore")
  entries=$(command mktemp "${TMPDIR:-/tmp}/aip-passthrough-entries.XXXXXX") || return 0
  : >|"$entries"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    dest=$profile_path/$harness/$rel
    if [ -L "$dest" ] && _aip_is_passthrough_link "$harness/$rel" "$profile_path" && [ -e "$dest" ]; then
      if ! _aip_git -C "$_AIP_PROFILE_ROOT" ls-files --error-unmatch -- "$name/$harness/$rel" >/dev/null 2>&1; then
        printf '%s\n' "$harness/$rel" >>"$entries"
      fi
    elif [ -e "$dest" ]; then
      :  # path exists but is not a pass-through link: no entry
    elif case " $removed_this_run " in *" $harness/$rel "*) true ;; *) false ;; esac; then
      :  # link removed as broken this run: no entry
    elif ! printf '%s\n' "$current" | command grep -Fxq "$harness/$rel"; then
      :  # path absent and no current entry: nothing to do
    else
      :  # path absent but entry present (convergence): keep it
      printf '%s\n' "$harness/$rel" >>"$entries"
    fi
  done < <(_aip_passthrough_rels "$harness")
  # Preserve other harnesses' entries from the current block untouched (only
  # harness-qualified entries are recognised; stray unqualified lines are dropped).
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case $rel in pi/*|claude/*|codex/*|opencode/*) ;; *) continue ;; esac
    case ${rel%%/*} in "$harness") continue ;; esac
    case " $removed_this_run " in *" $rel "*) continue ;; esac
    printf '%s\n' "$rel" >>"$entries"
  done <<EOF
$current
EOF
  if ! _aip_gitignore_set_passthrough_block "$profile_path/.gitignore" "$entries"; then
    _aip_warn "could not update $name/.gitignore pass-through entries"
  fi
  command rm -f "$entries"
  return 0
}

_aip_passthrough_profile() {
  # $1 profile name: maintains pass-through links for every harness (create/clone).
  local name=$1 harness
  for harness in pi claude codex opencode; do
    _aip_passthrough "$harness" "$name"
  done
}

_aip_find_project_marker() {
  local dir=$PWD parent
  while :; do
    if [ -e "$dir/.aip-profile" ] || [ -L "$dir/.aip-profile" ]; then
      _AIP_PROJECT_MARKER=$dir/.aip-profile
      _AIP_PROJECT_NAME=$(_aip_read_name_file "$_AIP_PROJECT_MARKER") || return 2
      return 0
    fi
    [ "$dir" = / ] && return 1
    parent=${dir%/*}
    [ -n "$parent" ] || parent=/
    dir=$parent
  done
}

_aip_require_profile() {
  local name=$1 profile_path
  _aip_validate_name "$name" || {
    _aip_error "invalid profile name '$name'"
    return 2
  }
  profile_path=$(_aip_profile_path "$name")
  [ -d "$profile_path" ] || {
    _aip_error "profile '$name' does not exist"
    return 2
  }
  [ ! -L "$profile_path" ] || {
    _aip_error "profile '$name' path must not be a symbolic link"
    return 2
  }
  _aip_require_root_repo || return
}

_aip_resolve_profile() {
  local explicit_supplied=0 explicit='' name
  _AIP_RESOLVE_REASON=
  if [ "$#" -gt 0 ]; then explicit_supplied=1; explicit=$1; fi

  if [ "$explicit_supplied" -eq 1 ]; then
    _aip_require_profile "$explicit" || return
    _AIP_RESOLVED_NAME=$explicit
    _AIP_RESOLVED_SOURCE=explicit
    return 0
  fi

  if [ -n "${AIP_PROFILE-}" ]; then
    _aip_require_profile "$AIP_PROFILE" || return
    _AIP_RESOLVED_NAME=$AIP_PROFILE
    _AIP_RESOLVED_SOURCE=session
    return 0
  fi

  _aip_find_project_marker
  case $? in
    0)
      _aip_require_profile "$_AIP_PROJECT_NAME" || return
      _AIP_RESOLVED_NAME=$_AIP_PROJECT_NAME
      _AIP_RESOLVED_SOURCE="project ($_AIP_PROJECT_MARKER)"
      return 0
      ;;
    2)
      _aip_error "invalid project marker '$_AIP_PROJECT_MARKER'"
      return 2
      ;;
  esac

  if [ -e "$_AIP_PROFILE_ROOT/.default" ] || [ -L "$_AIP_PROFILE_ROOT/.default" ]; then
    name=$(_aip_read_name_file "$_AIP_PROFILE_ROOT/.default") || {
      _aip_error "invalid default profile marker '$_AIP_PROFILE_ROOT/.default'"
      return 2
    }
    _aip_require_profile "$name" || return
    _AIP_RESOLVED_NAME=$name
    _AIP_RESOLVED_SOURCE=default
    return 0
  fi

  _AIP_RESOLVE_REASON=no-selection
  [ "${_AIP_RESOLVE_QUIET-}" = 1 ] || _aip_error "no profile selected; run 'aip create NAME' then 'aip use NAME'"
  return 2
}

_aip_write_profile_files() {
  local profile_path=$1 outfit=$2
  command mkdir -p "$profile_path/.aip" "$profile_path/skills" "$profile_path/claude" "$profile_path/codex" "$profile_path/pi" "$profile_path/opencode" || return
  command chmod 700 "$profile_path" || return
  printf '%s\n' "$outfit" >"$profile_path/.aip/outfit" || return
  : >"$profile_path/skills/.gitkeep" || return
  printf '%s\n' '# Common profile instructions' >"$profile_path/AGENTS.md" || return
  printf '%s\n' '@../AGENTS.md' '' '# Claude Code instructions' >"$profile_path/claude/CLAUDE.md" || return
  printf '%s\n' '# Codex instructions' >"$profile_path/codex/instructions.md" || return
  printf '%s\n' '# Pi instructions' >"$profile_path/pi/APPEND_SYSTEM.md" || return
  printf '%s\n' \
    '# aip-managed credential and runtime exclusions' \
    '.env' '.env.*' '!.env.example' '*.pem' '*.key' '*.p12' '*.pfx' \
    '.netrc' '.npmrc' '.pypirc' 'id_rsa' 'id_dsa' 'id_ecdsa' 'id_ed25519' 'node_modules/' \
    'claude/.credentials.json' 'claude/history.jsonl' 'claude/projects/' 'claude/session-env/' 'claude/shell-snapshots/' 'claude/statsig/' 'claude/todos/' 'claude/debug/' 'claude/cache/' 'claude/logs/' 'claude/file-history/' \
    'codex/auth.json' 'codex/history.jsonl' 'codex/sessions/' 'codex/archived_sessions/' 'codex/log/' 'codex/logs/' 'codex/cache/' 'codex/*.db' 'codex/*.db-*' 'codex/*.sqlite' 'codex/*.sqlite-*' \
    'pi/auth.json' 'pi/sessions/' 'pi/logs/' 'pi/cache/' \
    'opencode/auth.json' 'opencode/sessions/' 'opencode/logs/' 'opencode/cache/' \
    >"$profile_path/.gitignore" || return
  command ln -s ../skills "$profile_path/claude/skills" || return
  command ln -s ../AGENTS.md "$profile_path/codex/AGENTS.md" || return
  command ln -s ../skills "$profile_path/codex/skills" || return
  command ln -s ../AGENTS.md "$profile_path/pi/AGENTS.md" || return
  command ln -s ../skills "$profile_path/pi/skills" || return
  command ln -s ../AGENTS.md "$profile_path/opencode/AGENTS.md" || return
  command ln -s ../skills "$profile_path/opencode/skills" || return
}

_aip_publish_profile_directory() (
  local source=$1 destination=$2 lock=${2}.aip-publish-lock token token_path nested
  command mkdir "$lock" 2>/dev/null || { _aip_error "another profile publication is using: $destination"; return 1; }
  trap 'command rmdir "$lock" 2>/dev/null || :' EXIT
  { [ ! -e "$destination" ] && [ ! -L "$destination" ]; } || { _aip_error "destination already exists: $destination"; return 1; }
  token="$$-$(command date +%s)-${RANDOM-0}"
  token_path=$source/.aip-publish-token
  printf '%s\n' "$token" >|"$token_path" || return
  command mv "$source" "$destination" || return
  if [ "$(command cat "$destination/.aip-publish-token" 2>/dev/null)" != "$token" ]; then
    nested=$destination/${source##*/}
    if [ "$(command cat "$nested/.aip-publish-token" 2>/dev/null)" = "$token" ]; then
      command mv "$nested" "$source" || _aip_error "publication raced with another filesystem writer; recover the staged profile from: $nested"
    fi
    _aip_error "destination appeared during profile publication and was not overwritten: $destination"
    return 1
  fi
  command rm -f "$destination/.aip-publish-token" || return
  { [ -d "$destination" ] && [ ! -L "$destination" ]; } || {
    _aip_error "published profile failed its postcondition: $destination"
    return 1
  }
)

_aip_create() (
  _aip_clear_git_routing
  local name=${1-} outfit=plain destination stage temporary
  [ -n "$name" ] || {
    _aip_error 'usage: aip create NAME [--outfit OUTFIT]'
    return 2
  }
  shift
  if [ "${1-}" = --outfit ] && [ "$#" -eq 2 ]; then
    outfit=$2
    shift 2
  fi
  [ "$#" -eq 0 ] || {
    _aip_error 'usage: aip create NAME [--outfit OUTFIT]'
    return 2
  }
  _aip_validate_name "$name" || {
    _aip_error "invalid profile name '$name'"
    return 2
  }
  _aip_validate_outfit "$outfit" || {
    _aip_error 'outfit must be one non-empty line of at most 64 characters'
    return 2
  }
  _aip_git --version >/dev/null 2>&1 || {
    _aip_error 'Git is required'
    return 1
  }
  command mkdir -p "$_AIP_PROFILE_ROOT" || return
  destination=$(_aip_profile_path "$name")
  { [ ! -e "$destination" ] && [ ! -L "$destination" ]; } || {
    _aip_error "destination already exists: $destination"
    return 1
  }
  _aip_ensure_root_repo || {
    _aip_error "could not create profile '$name'"
    return 1
  }
  _aip_require_git_containment "$_AIP_PROFILE_ROOT" || return
  stage=$(command mktemp -d "$_AIP_PROFILE_ROOT/.aip-stage.XXXXXX") || return
  temporary=$stage/$name
  if ! command mkdir "$temporary" ||
     ! _aip_write_profile_files "$temporary" "$outfit" ||
     ! _aip_publish_profile_directory "$temporary" "$destination"; then
    command rm -rf "$stage"
    _aip_error "could not create profile '$name'"
    return 1
  fi
  command rmdir "$stage" || return
  _aip_passthrough_profile "$name"
  _aip_git -C "$_AIP_PROFILE_ROOT" add .gitignore "$name" || {
    _aip_error "could not commit profile '$name'; check Git identity and hooks"
    return 1
  }
  if ! _aip_git -C "$_AIP_PROFILE_ROOT" diff --cached --quiet --; then
    _aip_git -C "$_AIP_PROFILE_ROOT" commit -q -m 'aip: create profile' || {
      _aip_error "could not commit profile '$name'; check Git identity and hooks"
      return 1
    }
  fi
  printf "Created profile '%s' at %s\n" "$name" "$destination"
)

_aip_use() {
  [ "$#" -eq 1 ] || {
    _aip_error 'usage: aip use NAME'
    return 2
  }
  _aip_require_profile "$1" || return
  AIP_PROFILE=$1
  export AIP_PROFILE
  printf "Using profile '%s' for this shell\n" "$1"
}

_aip_which() {
  [ "$#" -le 1 ] || {
    _aip_error 'usage: aip which [NAME]'
    return 2
  }
  if [ "$#" -eq 1 ]; then _aip_resolve_profile "$1" || return
  else _aip_resolve_profile || return
  fi
  _aip_profile_path "$_AIP_RESOLVED_NAME"
}

_aip_write_marker() {
  local destination=$1 name=$2 temporary
  if [ -d "$destination" ] || [ -L "$destination" ]; then
    _aip_error "marker path is not a regular file: $destination"
    return 1
  fi
  temporary=$(command mktemp "${destination}.XXXXXX") || return
  if ! printf '%s\n' "$name" >|"$temporary" || ! command mv -f "$temporary" "$destination" ||
     [ "$(_aip_read_name_file "$destination" 2>/dev/null)" != "$name" ]; then
    command rm -f "$temporary"
    return 1
  fi
}

_aip_default() {
  [ "$#" -le 1 ] || {
    _aip_error 'usage: aip default [NAME]'
    return 2
  }
  if [ "$#" -eq 0 ]; then
    _aip_read_name_file "$_AIP_PROFILE_ROOT/.default" || {
      _aip_error 'no default profile is set'
      return 1
    }
    return
  fi
  _aip_require_profile "$1" || return
  command mkdir -p "$_AIP_PROFILE_ROOT" || return
  _aip_write_marker "$_AIP_PROFILE_ROOT/.default" "$1" || return
  printf "Default profile is now '%s'\n" "$1"
}

_aip_local() {
  [ "$#" -le 1 ] || {
    _aip_error 'usage: aip local [NAME|--remove]'
    return 2
  }
  if [ "$#" -eq 0 ]; then
    _aip_read_name_file "$PWD/.aip-profile" || {
      _aip_error 'no profile marker exists in the current directory'
      return 1
    }
    return
  fi
  if [ "$1" = --remove ]; then
    { [ -e "$PWD/.aip-profile" ] || [ -L "$PWD/.aip-profile" ]; } || {
      _aip_error 'no profile marker exists in the current directory'
      return 1
    }
    command rm -f "$PWD/.aip-profile" || return
    printf 'Removed %s/.aip-profile\n' "$PWD"
    return
  fi
  _aip_require_profile "$1" || return
  _aip_write_marker "$PWD/.aip-profile" "$1" || return
  printf "This directory now uses profile '%s'\n" "$1"
}

_aip_outfit() {
  [ "$#" -eq 2 ] || {
    _aip_error 'usage: aip outfit NAME OUTFIT'
    return 2
  }
  _aip_require_profile "$1" || return
  _aip_validate_sync_layout "$(_aip_profile_path "$1")" allow-invalid-outfit || return
  _aip_validate_outfit "$2" || {
    _aip_error 'outfit must be one printable, non-empty line of at most 64 characters'
    return 2
  }
  local outfit_path temporary
  outfit_path=$(_aip_profile_path "$1")/.aip/outfit
  temporary=$(command mktemp "${outfit_path}.XXXXXX") || return
  if ! printf '%s\n' "$2" >|"$temporary" || ! command mv -f "$temporary" "$outfit_path"; then
    command rm -f "$temporary"
    return 1
  fi
  printf "Profile '%s' now wears %s\n" "$1" "$2"
}

_aip_clone() (
  _aip_clear_git_routing
  [ "$#" -eq 2 ] || {
    _aip_error 'usage: aip clone SOURCE TARGET'
    return 2
  }
  local source_name=$1 target_name=$2 source_path target_path stage temporary tarball
  _aip_require_profile "$source_name" || return
  [ ! -L "$(_aip_profile_path "$source_name")" ] || {
    _aip_error 'source profile path must not be a symbolic link'
    return 1
  }
  _aip_validate_name "$target_name" || {
    _aip_error "invalid profile name '$target_name'"
    return 2
  }
  # Capture the source profile's committed executable paths before the sync
  # checkpoint can re-stage files from disk (where the executable bit may
  # differ, and never exists on platforms without file modes such as Windows).
  local clone_record clone_execs=''
  while IFS= read -r -d '' clone_record; do
    case ${clone_record%%$'\t'*} in
      100755*) clone_execs+="${clone_record#*$'\t'}"$'\n' ;;
    esac
  done < <(_aip_git -C "$_AIP_PROFILE_ROOT" ls-files -s -z -- "$source_name/")
  source_path=$(_aip_profile_path "$source_name")
  _aip_require_git_containment "$_AIP_PROFILE_ROOT" || return
  target_path=$(_aip_profile_path "$target_name")
  { [ ! -e "$target_path" ] && [ ! -L "$target_path" ]; } || {
    _aip_error "destination already exists: $target_path"
    return 1
  }
  _aip_sync clone || return
  stage=$(command mktemp -d "$_AIP_PROFILE_ROOT/.aip-stage.XXXXXX") || return
  temporary=$stage/$target_name
  tarball=$(command mktemp "${TMPDIR:-/tmp}/aip-archive.XXXXXX") || { command rm -rf "$stage"; return; }
  if ! command mkdir "$temporary" ||
     ! _aip_git -C "$_AIP_PROFILE_ROOT" archive -o "$tarball" HEAD "$source_name" ||
     ! command tar -xf "$tarball" --strip-components=1 -C "$temporary" ||
     ! _aip_validate_sync_layout "$temporary" ||
     ! command chmod 700 "$temporary" ||
     ! _aip_publish_profile_directory "$temporary" "$target_path"; then
    command rm -rf "$stage"
    command rm -f "$tarball"
    _aip_error "could not clone profile '$source_name'"
    return 1
  fi
  command rm -f "$tarball"
  command rmdir "$stage" || return
  _aip_passthrough_profile "$target_name"
  _aip_git -C "$_AIP_PROFILE_ROOT" add "$target_name" || {
    _aip_error "could not commit clone of profile '$source_name'; check Git identity and hooks"
    return 1
  }
  # Executable bits do not survive tar extraction on platforms without file modes
  # (e.g. Windows); restore them from the source profile's committed modes.
  local clone_path chmod_failed=0
  while IFS= read -r clone_path; do
    [ -n "$clone_path" ] || continue
    _aip_git -C "$_AIP_PROFILE_ROOT" update-index --add --chmod=+x -- "$target_name/${clone_path#"$source_name"/}" || chmod_failed=1
  done <<< "$clone_execs"
  if [ "$chmod_failed" -ne 0 ]; then
    _aip_error "could not commit clone of profile '$source_name'; check Git identity and hooks"
    return 1
  fi
  if ! _aip_git -C "$_AIP_PROFILE_ROOT" diff --cached --quiet --; then
    _aip_git -C "$_AIP_PROFILE_ROOT" commit -q -m "aip: clone $source_name" || {
      _aip_error "could not commit clone of profile '$source_name'; check Git identity and hooks"
      return 1
    }
  fi
  printf "Cloned profile '%s' to '%s' at %s\n" "$source_name" "$target_name" "$target_path"
)

_aip_has_unfinished_git_operation() {
  local git_dir=$1/.git
  [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ] ||
    [ -f "$git_dir/MERGE_HEAD" ] || [ -f "$git_dir/CHERRY_PICK_HEAD" ] ||
    [ -f "$git_dir/REVERT_HEAD" ] || [ -f "$git_dir/BISECT_START" ]
}

_aip_delete() (
  _aip_clear_git_routing
  local name=${1-} force=0 profile_path risks='' fully_recoverable=0 default_name='' changes unpushed tags
  [ -n "$name" ] || {
    _aip_error 'usage: aip delete NAME [--force]'
    return 2
  }
  shift
  if [ "${1-}" = --force ] && [ "$#" -eq 1 ]; then force=1; shift; fi
  [ "$#" -eq 0 ] || {
    _aip_error 'usage: aip delete NAME [--force]'
    return 2
  }
  _aip_require_profile "$name" || return
  profile_path=$(_aip_profile_path "$name")
  _aip_require_git_containment "$_AIP_PROFILE_ROOT" || return
  _aip_require_no_nested_mounts "$profile_path" || return
  [ ! -L "$profile_path" ] || {
    _aip_error 'profile path must not be a symbolic link'
    return 1
  }
  [ "${AIP_PROFILE-}" != "$name" ] || {
    _aip_error "cannot delete session profile '$name'; select another profile first"
    return 1
  }
  [ "$(builtin cd "$_AIP_PROFILE_ROOT" && builtin pwd -P)" = "$(builtin cd "${profile_path%/*}" && builtin pwd -P)" ] || {
    _aip_error 'refusing to delete a profile outside the profile root'
    return 1
  }

  if changes=$(_aip_git -C "$_AIP_PROFILE_ROOT" status --porcelain -- "$name" 2>/dev/null); then
    [ -z "$changes" ] || risks='uncommitted changes'
  else
    risks='working-tree state could not be inspected'
  fi
  _aip_has_unfinished_git_operation "$_AIP_PROFILE_ROOT" && risks="${risks:+$risks, }unfinished Git operation"
  if _aip_git -C "$_AIP_PROFILE_ROOT" rev-parse --verify '@{upstream}' >/dev/null 2>&1; then
    if unpushed=$(_aip_git -C "$_AIP_PROFILE_ROOT" rev-list --branches --not --remotes 2>/dev/null); then
      [ -z "$unpushed" ] || risks="${risks:+$risks, }unpushed commits on local branches"
    else
      risks="${risks:+$risks, }commit reachability could not be inspected"
    fi
    _aip_git -C "$_AIP_PROFILE_ROOT" rev-parse --verify refs/stash >/dev/null 2>&1 && risks="${risks:+$risks, }stashed changes"
    if tags=$(_aip_git -C "$_AIP_PROFILE_ROOT" for-each-ref --format='%(refname)' refs/tags 2>/dev/null); then
      [ -z "$tags" ] || risks="${risks:+$risks, }local tags"
    else
      risks="${risks:+$risks, }tags could not be inspected"
    fi
    if [ -z "$risks" ]; then fully_recoverable=1; fi
  else
    risks="${risks:+$risks, }unpushed commits (no upstream)"
  fi

  if [ "$force" -ne 1 ]; then
    if [ ! -t 0 ]; then
      _aip_error "deletion requires confirmation${risks:+ ($risks)}; rerun with --force"
      return 1
    fi
    printf "Delete profile '%s' at %s%s? [y/N] " "$name" "$profile_path" "${risks:+ ($risks)}" >&2
    local answer
    IFS= read -r answer || return 1
    case $answer in y|Y|yes|YES) ;; *) _aip_error 'deletion cancelled'; return 1 ;; esac
  fi

  default_name=$(_aip_read_name_file "$_AIP_PROFILE_ROOT/.default" 2>/dev/null) || default_name=
  command find "$profile_path" -xdev -depth -delete || {
    _aip_error "could not completely delete profile '$name'; no default marker was changed"
    return 1
  }
  { [ ! -e "$profile_path" ] && [ ! -L "$profile_path" ]; } || {
    _aip_error "could not completely delete profile '$name'; no default marker was changed"
    return 1
  }
  if [ "$default_name" = "$name" ]; then command rm -f "$_AIP_PROFILE_ROOT/.default" || return; fi
  if _aip_git -C "$_AIP_PROFILE_ROOT" add -u -- "$name" 2>/dev/null; then
    if ! _aip_git -C "$_AIP_PROFILE_ROOT" diff --cached --quiet -- 2>/dev/null; then
      _aip_git -C "$_AIP_PROFILE_ROOT" commit -q -m "aip: delete profile $name" 2>/dev/null || {
        _aip_error "deletion is complete, but its commit failed; check the profiles repository and commit the removal manually"
      }
    fi
  else
    _aip_error "deletion is complete, but the profiles repository could not stage the removal; inspect it and commit manually"
  fi
  printf 'Deleted %s; ' "$profile_path"
  if [ "$fully_recoverable" -eq 1 ]; then
    printf 'its committed content is recoverable from the configured Git upstream.\n'
  else
    printf 'no complete remote recovery is available; local or unpushed changes were removed.\n'
  fi
)

_aip_resolve_doctor_profile() {
  local explicit_supplied=0 explicit='' name
  if [ "$#" -gt 0 ]; then explicit_supplied=1; explicit=$1; fi
  if [ "$explicit_supplied" -eq 1 ]; then
    _aip_validate_name "$explicit" || { _aip_error "invalid profile name '$explicit'"; return 2; }
    name=$explicit
  elif [ -n "${AIP_PROFILE-}" ]; then
    _aip_validate_name "$AIP_PROFILE" || { _aip_error "invalid profile name '$AIP_PROFILE'"; return 2; }
    name=$AIP_PROFILE
  else
    if _aip_find_project_marker; then
      name=$_AIP_PROJECT_NAME
    else
      case $? in
        2) _aip_error "invalid project marker '$_AIP_PROJECT_MARKER'"; return 2 ;;
      esac
      if [ -e "$_AIP_PROFILE_ROOT/.default" ] || [ -L "$_AIP_PROFILE_ROOT/.default" ]; then
        name=$(_aip_read_name_file "$_AIP_PROFILE_ROOT/.default") || { _aip_error "invalid default profile marker '$_AIP_PROFILE_ROOT/.default'"; return 2; }
      else
        _aip_error "no profile selected; run 'aip create NAME' then 'aip use NAME'"
        return 2
      fi
    fi
  fi
  _AIP_RESOLVED_NAME=$name
  local profile_path
  profile_path=$(_aip_profile_path "$name")
  { [ -d "$profile_path" ] || [ -L "$profile_path" ]; } || { _aip_error "profile '$name' does not exist"; return 2; }
}

_aip_doctor_passthrough() {
  # Reports pass-through links and warns (never fails) on broken ones.
  local profile_path=$1 name=$2 harness root rel dest
  for harness in pi claude codex opencode; do
    root=$(_aip_import_harness_root "$harness") || continue
    [ -d "$root" ] || continue
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      dest=$profile_path/$harness/$rel
      if [ -L "$dest" ] && _aip_is_passthrough_link "$harness/$rel" "$profile_path"; then
        if [ -e "$dest" ]; then
          printf 'OK: pass-through %s/%s -> %s\n' "$name" "$harness/$rel" "$(command readlink "$dest")"
        else
          printf 'WARN: pass-through %s/%s is broken (its machine-local target is missing)\n' "$name" "$harness/$rel"
        fi
      fi
    done < <(_aip_passthrough_rels "$harness")
  done
}

_aip_doctor_profile_layout() {
  local profile_path=$1 name=$2 pair link expected directory
  for directory in .aip skills claude codex pi opencode; do
    if [ ! -d "$profile_path/$directory" ] || [ -L "$profile_path/$directory" ]; then
      printf 'ERROR: required directory is missing or linked: %s/%s\n' "$name" "$directory"
      return 1
    fi
  done
  for pair in 'claude/skills:../skills' 'codex/AGENTS.md:../AGENTS.md' 'codex/skills:../skills' 'pi/AGENTS.md:../AGENTS.md' 'pi/skills:../skills' 'opencode/AGENTS.md:../AGENTS.md' 'opencode/skills:../skills'; do
    link=${pair%%:*}
    expected=${pair#*:}
    if [ ! -L "$profile_path/$link" ] || [ "$(command readlink "$profile_path/$link" 2>/dev/null)" != "$expected" ]; then
      printf 'ERROR: %s/%s should link to %s\n' "$name" "$link" "$expected"
      printf "FIX: ln -sfn '%s' '%s/%s'\n" "$expected" "$profile_path" "$link"
      return 1
    fi
  done
  if ! _aip_check_live_profile_links "$profile_path"; then return 1; fi
  for link in .aip/outfit .gitignore AGENTS.md skills/.gitkeep claude/CLAUDE.md codex/instructions.md pi/APPEND_SYSTEM.md; do
    if [ ! -f "$profile_path/$link" ] || [ -L "$profile_path/$link" ]; then
      printf 'ERROR: required file is missing or linked: %s/%s\n' "$name" "$link"
      return 1
    fi
  done
  if ! _aip_validate_sync_layout "$profile_path"; then
    printf 'ERROR: %s content or layout validation failed; repair the diagnostic above\n' "$name"
    return 1
  fi
  _aip_doctor_passthrough "$profile_path" "$name"
  printf 'OK: profile layout and links (%s)\n' "$name"
}

_aip_doctor() (
  _aip_clear_git_routing
  [ "$#" -le 1 ] || {
    _aip_error 'usage: aip doctor [NAME]'
    return 2
  }
  if [ "$#" -eq 1 ]; then _aip_resolve_doctor_profile "$1" || return
  else _aip_resolve_doctor_profile || return
  fi
  local root=$_AIP_PROFILE_ROOT profile_path profile_dir name checked='' errors=0 git_available=1 repo_readable=1 repo_ok=1 harness branch configured_remote configured_merge
  profile_path=$(_aip_profile_path "$_AIP_RESOLVED_NAME")
  if [ -L "$profile_path" ]; then
    printf 'ERROR: profile path must not be a symbolic link\n'
    errors=1
  fi

  if [ ! -d "$root" ] || [ -L "$root/.git" ] || [ ! -d "$root/.git" ]; then
    printf 'ERROR: profiles repository metadata is missing or linked: %s/.git\n' "$root"
    printf 'FIX: restore an ordinary .git directory at the profiles root\n'
    errors=1
    repo_readable=0
    repo_ok=0
  fi
  if ! _aip_git --version >/dev/null 2>&1; then
    printf 'ERROR: Git was not found\n'
    errors=1
    git_available=0
    repo_ok=0
  elif [ "$repo_readable" -eq 1 ]; then
    if ! _aip_git_is_contained "$root"; then
      printf 'ERROR: %s\n' "$_AIP_GIT_CONTAINMENT_ERROR"
      errors=1
      repo_readable=0
      repo_ok=0
    fi
  fi
  if [ "$git_available" -eq 1 ] && [ "$repo_readable" -eq 1 ]; then
    _aip_git -C "$root" var GIT_AUTHOR_IDENT >/dev/null 2>&1 || {
      printf "ERROR: configure Git identity with 'git config --global user.name NAME' and 'git config --global user.email EMAIL'\n"
      errors=1
      repo_ok=0
    }
    _aip_git -C "$root" status --porcelain >/dev/null 2>&1 || {
      printf 'ERROR: profiles Git repository is unreadable\n'
      errors=1
      repo_ok=0
    }
    if [ "$(_aip_git -C "$root" config --bool core.symlinks 2>/dev/null)" = false ]; then
      printf "ERROR: Git symbolic-link checkout is disabled\nFIX: git -C '%s' config core.symlinks true, then re-clone the profiles repository\n" "$root"
      errors=1
      repo_ok=0
    fi
    branch=$(_aip_git -C "$root" branch --show-current 2>/dev/null) || branch=
    if [ -n "$branch" ]; then
      configured_remote=$(_aip_git -C "$root" config --get "branch.$branch.remote" 2>/dev/null) || configured_remote=
      configured_merge=$(_aip_git -C "$root" config --get "branch.$branch.merge" 2>/dev/null) || configured_merge=
      if [ -n "$configured_remote$configured_merge" ] &&
         ! _aip_git -C "$root" rev-parse --verify '@{upstream}' >/dev/null 2>&1; then
        printf 'ERROR: the configured Git upstream cannot be resolved\n'
        printf "FIX: repair or fetch the configured remote branch, or run 'git -C \"%s\" branch --unset-upstream'\n" "$root"
        errors=1
        repo_ok=0
      fi
    fi
  fi

  for name in $(_aip_list_profile_names) "$_AIP_RESOLVED_NAME"; do
    case " $checked " in *" $name "*) continue ;; esac
    checked="$checked $name"
    profile_dir=$(_aip_profile_path "$name")
    { [ -d "$profile_dir" ] && [ ! -L "$profile_dir" ]; } || continue
    _aip_doctor_profile_layout "$profile_dir" "$name" || errors=1
  done

  if [ "$git_available" -eq 1 ] && [ "$repo_readable" -eq 1 ]; then
    if ! _aip_check_tracked_forbidden "$root"; then
      printf 'ERROR: tracked profile path validation failed; see the diagnostic above\n'
      errors=1
    fi
    if _aip_has_unfinished_git_operation "$root" ||
       [ -n "$(_aip_git -C "$root" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
      printf "ERROR: Git conflict or unfinished operation; run 'git -C \"%s\" status', resolve files, then use 'git rebase --continue' or 'git rebase --abort'\n" "$root"
      errors=1
    fi
  fi
  if [ -d "$root/.git/aip-sync.lock" ]; then
    local lock_pid='' lock_host='' current_host=''
    lock_pid=$(command cat "$root/.git/aip-sync.lock/pid" 2>/dev/null) || lock_pid=
    lock_host=$(command cat "$root/.git/aip-sync.lock/host" 2>/dev/null) || lock_host=
    current_host=$(command hostname 2>/dev/null) || current_host=
    case $lock_pid in
      ''|*[!0-9]*) printf 'WARN: sync lock owner is unknown; inspect %s/.git/aip-sync.lock\n' "$root" ;;
      *)
        if [ "$lock_host" = "$current_host" ] && ! command kill -0 "$lock_pid" 2>/dev/null; then
          printf 'WARN: stale sync lock found; the next sync will remove it, or inspect %s/.git/aip-sync.lock\n' "$root"
        else
          printf 'WARN: sync lock is owned by a live or remote process; inspect %s/.git/aip-sync.lock\n' "$root"
        fi
        ;;
    esac
  fi
  [ "$repo_ok" -eq 1 ] && printf 'OK: profiles repository\n'

  for harness in claude codex pi opencode; do
    if _aip_find_real_command "$harness" >/dev/null 2>&1; then
      printf 'OK: %s executable found\n' "$harness"
    else
      printf 'WARN: %s executable was not found; install it before using this wrapper\n' "$harness"
    fi
  done
  [ "$errors" -eq 0 ]
)

_aip_list() (
  _aip_clear_git_routing
  [ "$#" -eq 0 ] || {
    _aip_error 'usage: aip list'
    return 2
  }
  local profile_path name outfit tags default_name='' project_name='' found=0 entries
  default_name=$(_aip_read_name_file "$_AIP_PROFILE_ROOT/.default" 2>/dev/null) || default_name=
  if _aip_find_project_marker 2>/dev/null; then project_name=$_AIP_PROJECT_NAME; fi
  if [ ! -d "$_AIP_PROFILE_ROOT" ]; then
    printf 'No profiles. Create one with: aip create NAME\n'
    return 0
  fi
  entries=$(command mktemp "${TMPDIR:-/tmp}/aip-profiles.XXXXXX") || return
  command find -H "$_AIP_PROFILE_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 >|"$entries" || { command rm -f "$entries"; return 1; }
  while IFS= read -r -d '' profile_path; do
    [ ! -L "$profile_path" ] || continue
    name=${profile_path##*/}
    _aip_validate_name "$name" || continue
    { [ -e "$profile_path/.aip/outfit" ] || [ -L "$profile_path/.aip/outfit" ]; } || continue
    outfit=$(_aip_read_outfit "$profile_path/.aip/outfit") || outfit='invalid outfit'
    tags=
    [ "${AIP_PROFILE-}" = "$name" ] && tags="$tags [session]"
    [ "$project_name" = "$name" ] && tags="$tags [project]"
    [ "$default_name" = "$name" ] && tags="$tags [default]"
    printf '%s — %s%s\n' "$name" "$outfit" "$tags"
    found=1
  done <"$entries"
  command rm -f "$entries"
  [ "$found" -eq 1 ] || printf 'No profiles. Create one with: aip create NAME\n'
)

_aip_git_summary() {
  local repository=$_AIP_PROFILE_ROOT state upstream counts ahead behind changes branch configured_remote configured_merge
  _aip_git_is_contained "$repository" || {
    printf 'unreadable; run aip doctor\n'
    return
  }
  changes=$(_aip_git -C "$repository" status --porcelain 2>/dev/null) || {
    printf 'unreadable; run aip doctor\n'
    return
  }
  if [ -n "$changes" ]; then state=changes; else state=clean; fi
  if _aip_has_unfinished_git_operation "$repository" ||
     [ -n "$(_aip_git -C "$repository" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
    printf '%s, conflict or unfinished Git operation\n' "$state"
    return
  fi
  if _aip_git -C "$repository" rev-parse --verify '@{upstream}' >/dev/null 2>&1; then
    upstream=$(_aip_git -C "$repository" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null) || { printf 'unreadable; run aip doctor\n'; return; }
    counts=$(_aip_git -C "$repository" rev-list --left-right --count 'HEAD...@{upstream}' 2>/dev/null) || { printf 'unreadable; run aip doctor\n'; return; }
    ahead=${counts%%[[:space:]]*}
    behind=${counts##*[[:space:]]}
    case $ahead:$behind in *[!0-9:]*|:|*:) printf 'unreadable; run aip doctor\n'; return ;; esac
    if [ "$ahead" = 0 ] && [ "$behind" = 0 ]; then
      printf '%s, synced with %s\n' "$state" "$upstream"
    elif [ "$behind" = 0 ]; then
      printf '%s, pending push (%s ahead of %s)\n' "$state" "$ahead" "$upstream"
    elif [ "$ahead" = 0 ]; then
      printf '%s, pending pull (%s behind %s)\n' "$state" "$behind" "$upstream"
    else
      printf '%s, diverged (%s ahead, %s behind %s)\n' "$state" "$ahead" "$behind" "$upstream"
    fi
  else
    branch=$(_aip_git -C "$repository" branch --show-current 2>/dev/null) || { printf 'unreadable; run aip doctor\n'; return; }
    configured_remote=$(_aip_git -C "$repository" config --get "branch.$branch.remote" 2>/dev/null) || configured_remote=
    configured_merge=$(_aip_git -C "$repository" config --get "branch.$branch.merge" 2>/dev/null) || configured_merge=
    if [ -n "$configured_remote$configured_merge" ]; then printf 'unreadable; run aip doctor\n'
    else printf '%s, local only\n' "$state"
    fi
  fi
}

_aip_status() (
  _aip_clear_git_routing
  local profile_path outfit harness availability
  _AIP_RESOLVE_REASON=
  if ! _AIP_RESOLVE_QUIET=1 _aip_resolve_profile; then
    if [ "${_AIP_RESOLVE_REASON-}" = no-selection ]; then
      if [ -n "$(_aip_list_profile_names)" ]; then
        printf 'No profile selected. Available profiles:\n'
        _aip_list
        printf "Select one with 'aip use NAME' (this shell) or 'aip default NAME' (persistent).\n"
        return 0
      fi
      _aip_error "no profile selected; run 'aip create NAME' then 'aip use NAME'"
      return 2
    fi
    return 2
  fi
  profile_path=$(_aip_profile_path "$_AIP_RESOLVED_NAME")
  outfit=$(_aip_read_outfit "$profile_path/.aip/outfit") || outfit='invalid outfit'
  printf '🐵 %s — %s\n' "$_AIP_RESOLVED_NAME" "$outfit"
  printf 'Selected by: %s\nPath: %s\n' "$_AIP_RESOLVED_SOURCE" "$profile_path"
  printf 'Git: %s\n' "$(_aip_git_summary)"
  printf 'Harnesses:'
  for harness in claude codex pi opencode; do
    if _aip_find_real_command "$harness" >/dev/null 2>&1; then availability=available; else availability=missing; fi
    printf ' %s=%s' "$harness" "$availability"
  done
  printf '\n'
)

_aip_is_harness() {
  [ "${1-}" = claude ] || [ "${1-}" = codex ] || [ "${1-}" = pi ] || [ "${1-}" = opencode ]
}

_aip_is_command() {
  [ "${1-}" = --help ] || [ "${1-}" = -h ] || [ "${1-}" = help ] ||
    [ "${1-}" = create ] || [ "${1-}" = clone ] || [ "${1-}" = default ] ||
    [ "${1-}" = delete ] || [ "${1-}" = doctor ] || [ "${1-}" = list ] ||
    [ "${1-}" = local ] || [ "${1-}" = outfit ] || [ "${1-}" = remote ] ||
    [ "${1-}" = import ] || [ "${1-}" = run ] ||
    [ "${1-}" = sync ] || [ "${1-}" = use ] || [ "${1-}" = update ] ||
    [ "${1-}" = version ] || [ "${1-}" = which ]
}

_aip_find_real_command() {
  local name=$1 remaining directory candidate
  remaining=${_AIP_REAL_PATH-${PATH-}}:
  while [ -n "$remaining" ]; do
    directory=${remaining%%:*}
    remaining=${remaining#*:}
    [ -n "$directory" ] || directory=.
    candidate=$directory/$name
    if [ -f "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

_aip_ascii_lower() {
  # Fork-free exact equivalent of LC_ALL=C tr uppercase-lowering:
  # only ASCII A-Z folds; every other byte passes through untouched.
  _AIP_ASCII_LOWER=${1-}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//A/a}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//B/b}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//C/c}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//D/d}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//E/e}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//F/f}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//G/g}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//H/h}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//I/i}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//J/j}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//K/k}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//L/l}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//M/m}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//N/n}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//O/o}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//P/p}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//Q/q}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//R/r}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//S/s}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//T/t}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//U/u}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//V/v}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//W/w}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//X/x}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//Y/y}
  _AIP_ASCII_LOWER=${_AIP_ASCII_LOWER//Z/z}
}

_aip_is_forbidden_path() {
  local lower
  _aip_ascii_lower "$1"
  lower=$_AIP_ASCII_LOWER
  case $lower in
    .env.example|*/.env.example) return 1 ;;
    .env|.env.*|*/.env|*/.env.*|*.pem|*.key|*.p12|*.pfx|.netrc|*/.netrc|.npmrc|*/.npmrc|.pypirc|*/.pypirc|id_rsa|*/id_rsa|id_dsa|*/id_dsa|id_ecdsa|*/id_ecdsa|id_ed25519|*/id_ed25519) return 0 ;;
    claude/.credentials.json|claude/history.jsonl|claude/projects|claude/projects/*|claude/session-env|claude/session-env/*|claude/shell-snapshots|claude/shell-snapshots/*|claude/statsig|claude/statsig/*|claude/todos|claude/todos/*|claude/debug|claude/debug/*|claude/cache|claude/cache/*|claude/logs|claude/logs/*|claude/file-history|claude/file-history/*) return 0 ;;
    codex/auth.json|codex/history.jsonl|codex/sessions|codex/sessions/*|codex/archived_sessions|codex/archived_sessions/*|codex/log|codex/log/*|codex/logs|codex/logs/*|codex/cache|codex/cache/*|codex/*.db|codex/*.db-*|codex/*.sqlite|codex/*.sqlite-*) return 0 ;;
    pi/auth.json|pi/sessions|pi/sessions/*|pi/logs|pi/logs/*|pi/cache|pi/cache/*) return 0 ;;
    opencode/auth.json|opencode/sessions|opencode/sessions/*|opencode/logs|opencode/logs/*|opencode/cache|opencode/cache/*) return 0 ;;
    node_modules|node_modules/*|*/node_modules|*/node_modules/*) return 0 ;;
    *) return 1 ;;
  esac
}

_aip_validate_portable_paths_file() {
  local paths_file=$1 lines keys sorted relative remaining component base utf8_locale
  utf8_locale=$(_aip_find_utf8_locale) || { _AIP_PORTABLE_PATH_ERROR='no UTF-8 locale is available'; return 1; }
  command iconv -f UTF-8 -t UTF-8 "$paths_file" >/dev/null 2>&1 || {
    _AIP_PORTABLE_PATH_ERROR='invalid UTF-8 path'
    return 1
  }
  if command od -A n -t u1 "$paths_file" | command awk '{ for (i = 1; i <= NF; i++) if (($i > 0 && $i < 32) || $i == 127 || $i > 126) invalid = 1 } END { exit invalid }'; then :
  else
    _AIP_PORTABLE_PATH_ERROR='path contains a control or non-ASCII byte'
    return 1
  fi
  lines=$(command mktemp "${TMPDIR:-/tmp}/aip-portable.XXXXXX") || return
  keys=$(command mktemp "${TMPDIR:-/tmp}/aip-portable.XXXXXX") || { command rm -f "$lines"; return 1; }
  sorted=$(command mktemp "${TMPDIR:-/tmp}/aip-portable.XXXXXX") || { command rm -f "$lines" "$keys"; return 1; }
  : >|"$lines"
  while IFS= read -r -d '' relative; do
    remaining=$relative
    while :; do
      component=${remaining%%/*}
      if [ -z "$component" ] ||
         case $component in *'<'*|*'>'*|*':'*|*'"'*|*\\*|*'|'*|*'?'*|*'*'*|*'.'|*' ') true ;; *) false ;; esac; then
        _AIP_PORTABLE_PATH_ERROR=$relative
        command rm -f "$lines" "$keys" "$sorted"
        return 1
      fi
      base=${component%%.*}
      _aip_ascii_lower "$component"
      case $_AIP_ASCII_LOWER in
        .git)
          _AIP_PORTABLE_PATH_ERROR=$relative
          command rm -f "$lines" "$keys" "$sorted"
          return 1
          ;;
      esac
      _aip_ascii_lower "$base"
      case $_AIP_ASCII_LOWER in
        con|prn|aux|nul|com[1-9]|lpt[1-9]|conin\$|conout\$)
          _AIP_PORTABLE_PATH_ERROR=$relative
          command rm -f "$lines" "$keys" "$sorted"
          return 1
          ;;
      esac
      [ "$remaining" = "$component" ] && break
      remaining=${remaining#*/}
    done
    printf '%s\n' "$relative" >>"$lines" || { command rm -f "$lines" "$keys" "$sorted"; return 1; }
  done <"$paths_file"
  LC_ALL=C command awk -F / '{
      original = ""; folded = ""
      for (i = 1; i <= NF; i++) {
        original = original (i == 1 ? "" : "/") $i
        folded = folded (i == 1 ? "" : "/") tolower($i)
        print folded "\t" original
      }
    }' "$lines" >|"$keys" || { command rm -f "$lines" "$keys" "$sorted"; return 1; }
  LC_ALL=C command sort "$keys" >|"$sorted" || { command rm -f "$lines" "$keys" "$sorted"; return 1; }
  if ! command awk -F '\t' '
      $1 == previous && $2 != spelling { exit 1 }
      $1 != previous { previous = $1; spelling = $2 }
    ' "$sorted"; then
    _AIP_PORTABLE_PATH_ERROR='case-colliding paths'
    command rm -f "$lines" "$keys" "$sorted"
    return 1
  fi
  command rm -f "$lines" "$keys" "$sorted"
}

_aip_validate_sync_layout() {
  local profile_path=$1 outfit_mode=${2-} pair link expected file directory first_line
  { [ -d "$profile_path" ] && [ ! -L "$profile_path" ]; } || {
    _aip_error 'profile path is missing or linked'
    return 1
  }
  for directory in .aip skills claude codex pi opencode; do
    { [ -d "$profile_path/$directory" ] && [ ! -L "$profile_path/$directory" ]; } || {
      _aip_error "required profile directory is missing or linked: $directory"
      return 1
    }
  done
  for pair in 'claude/skills:../skills' 'codex/AGENTS.md:../AGENTS.md' 'codex/skills:../skills' 'pi/AGENTS.md:../AGENTS.md' 'pi/skills:../skills' 'opencode/AGENTS.md:../AGENTS.md' 'opencode/skills:../skills'; do
    link=${pair%%:*}
    expected=${pair#*:}
    if [ ! -L "$profile_path/$link" ] || [ "$(command readlink "$profile_path/$link" 2>/dev/null)" != "$expected" ]; then
      _aip_error "required profile file or link is missing or invalid: $link"
      return 1
    fi
  done
  _aip_check_live_profile_links "$profile_path" || return
  for file in .aip/outfit .gitignore AGENTS.md skills/.gitkeep claude/CLAUDE.md codex/instructions.md pi/APPEND_SYSTEM.md; do
    { [ -f "$profile_path/$file" ] && [ ! -L "$profile_path/$file" ]; } || {
      _aip_error "required profile file or link is missing or invalid: $file"
      return 1
    }
  done
  for file in .aip/outfit .gitignore AGENTS.md skills/.gitkeep claude/CLAUDE.md codex/instructions.md pi/APPEND_SYSTEM.md; do
    [ "$file" != .aip/outfit ] || [ "$outfit_mode" != allow-invalid-outfit ] || continue
    _aip_validate_utf8_text_file "$profile_path/$file" || {
      _aip_error "required profile text is not valid NUL-free UTF-8: $file"
      return 1
    }
  done
  [ ! -s "$profile_path/skills/.gitkeep" ] || {
    _aip_error 'skills/.gitkeep placeholder must be empty'
    return 1
  }
  if [ "$outfit_mode" != allow-invalid-outfit ]; then
    _aip_read_outfit "$profile_path/.aip/outfit" >/dev/null || {
      _aip_error 'profile outfit is empty, invalid, or longer than 64 characters'
      return 1
    }
  fi
  IFS= read -r first_line <"$profile_path/claude/CLAUDE.md" || first_line=
  first_line=${first_line%$'\r'}
  [ "$first_line" = '@../AGENTS.md' ] || {
    _aip_error 'claude/CLAUDE.md must begin with @../AGENTS.md'
    return 1
  }
}

_aip_ensure_skills_placeholder() {
  local profile_path=$1 placeholder=$1/skills/.gitkeep
  { [ -d "$profile_path" ] && [ ! -L "$profile_path" ] &&
    [ -d "$profile_path/skills" ] && [ ! -L "$profile_path/skills" ]; } || {
    _aip_error 'profile and skills paths must be ordinary directories'
    return 1
  }
  if [ -e "$placeholder" ] || [ -L "$placeholder" ]; then
    { [ -f "$placeholder" ] && [ ! -L "$placeholder" ]; } || {
      _aip_error 'skills/.gitkeep must be an ordinary file'
      return 1
    }
  else
    : >"$placeholder" || return
  fi
}

_aip_profile_prefixes_from_names() {
  local relative
  while IFS= read -r -d '' relative; do
    case $relative in
      */.aip/outfit) printf '%s\n' "${relative%%/*}" ;;
    esac
  done <"$1"
}

_aip_under_profile() {
  local first=${1%%/*} name
  [ "$first" != "$1" ] || return 1
  while IFS= read -r name; do
    [ "$name" = "$first" ] && return 0
  done <"$2"
  return 1
}

_aip_validate_git_tree() {
  local root=$1 tree=$2 relative rel pair link expected entry mode target file first_line text_temp outfit forbidden=0 profiles p
  profiles=$(command mktemp "${TMPDIR:-/tmp}/aip-profiles.XXXXXX") || return
  _AIP_TEMP_PATHS=$(command mktemp "${TMPDIR:-/tmp}/aip-tree.XXXXXX") || { command rm -f "$profiles"; return; }
  _aip_git -C "$root" ls-tree -r "$tree" >|"$_AIP_TEMP_PATHS" || {
    command rm -f "$profiles"
    return 1
  }
  : >|"$profiles"
  while IFS= read -r entry; do
    case ${entry%% *} in 100644) ;; *) continue ;; esac
    relative=${entry#*$'\t'}
    case $relative in */.aip/outfit) printf '%s\n' "${relative%%/*}" >>"$profiles" ;; esac
  done <"$_AIP_TEMP_PATHS"
  if command grep -q '^160000 ' "$_AIP_TEMP_PATHS"; then
    command rm -f "$profiles"
    command rm -f "$_AIP_TEMP_PATHS"
    _AIP_TEMP_PATHS=
    _aip_error 'remote profile contains an unsupported Git submodule'
    return 1
  fi
  # Cleanup unlinks the name; the loop keeps its already-open descriptor.
  # shellcheck disable=SC2094
  while IFS= read -r entry; do
    mode=${entry%% *}
    relative=${entry#*$'\t'}
    if [ "$mode" = 120000 ]; then
      if ! _aip_under_profile "$relative" "$profiles" ||
         ! _aip_is_required_profile_link "${relative#*/}"; then
        command rm -f "$profiles"
        command rm -f "$_AIP_TEMP_PATHS"
        _AIP_TEMP_PATHS=
        _aip_error "remote profile contains an unsupported symbolic link: $relative"
        return 1
      fi
    fi
  done <"$_AIP_TEMP_PATHS"

  _aip_git -C "$root" ls-tree -rz --name-only "$tree" >|"$_AIP_TEMP_PATHS" || {
    command rm -f "$profiles"
    return 1
  }
  if ! _aip_validate_portable_paths_file "$_AIP_TEMP_PATHS"; then
    command rm -f "$profiles"
    command rm -f "$_AIP_TEMP_PATHS"
    _AIP_TEMP_PATHS=
    _aip_error "remote profile contains a path that is not portable to Windows: $_AIP_PORTABLE_PATH_ERROR"
    return 1
  fi
  while IFS= read -r -d '' relative; do
    rel=$relative
    if _aip_under_profile "$relative" "$profiles"; then rel=${relative#*/}; fi
    if _aip_is_forbidden_path "$rel"; then forbidden=1; break; fi
  done <"$_AIP_TEMP_PATHS"
  if [ "$forbidden" -eq 1 ]; then
    command rm -f "$profiles"
    command rm -f "$_AIP_TEMP_PATHS"
    _AIP_TEMP_PATHS=
    _aip_error 'remote profile contains a forbidden credential or runtime path; remove it from the remote history before syncing'
    return 1
  fi

  while IFS= read -r p; do
    [ -n "$p" ] || continue
    for pair in 'claude/skills:../skills' 'codex/AGENTS.md:../AGENTS.md' 'codex/skills:../skills' 'pi/AGENTS.md:../AGENTS.md' 'pi/skills:../skills' 'opencode/AGENTS.md:../AGENTS.md' 'opencode/skills:../skills'; do
      link=${pair%%:*}
      expected=${pair#*:}
      entry=$(_aip_git -C "$root" ls-tree "$tree" -- "$p/$link") || {
        command rm -f "$profiles"
        return 1
      }
      mode=${entry%% *}
      target=$(_aip_git -C "$root" show "$tree:$p/$link" 2>/dev/null) || target=
      if [ "$mode" != 120000 ] || [ "$target" != "$expected" ]; then
        command rm -f "$profiles"
        _aip_error "remote profile has an invalid required link: $p/$link should link to $expected"
        return 1
      fi
    done
    for file in .aip/outfit .gitignore AGENTS.md skills/.gitkeep claude/CLAUDE.md codex/instructions.md pi/APPEND_SYSTEM.md; do
      entry=$(_aip_git -C "$root" ls-tree "$tree" -- "$p/$file") || {
        command rm -f "$profiles"
        return 1
      }
      mode=${entry%% *}
      case $mode in 100644|100755) ;; *)
        command rm -f "$profiles"
        _aip_error "remote profile is missing a regular required file: $p/$file"
        return 1
        ;;
      esac
    done
    text_temp=$(command mktemp "${TMPDIR:-/tmp}/aip-text.XXXXXX") || {
      command rm -f "$profiles"
      return 1
    }
    for file in .aip/outfit .gitignore AGENTS.md skills/.gitkeep claude/CLAUDE.md codex/instructions.md pi/APPEND_SYSTEM.md; do
      if ! _aip_git -C "$root" show "$tree:$p/$file" >|"$text_temp" 2>/dev/null || ! _aip_validate_utf8_text_file "$text_temp"; then
        command rm -f "$text_temp" "$profiles"
        _aip_error "remote required profile text is not valid NUL-free UTF-8: $p/$file"
        return 1
      fi
    done
    _aip_git -C "$root" show "$tree:$p/.aip/outfit" >|"$text_temp" 2>/dev/null || { command rm -f "$text_temp" "$profiles"; return 1; }
    if ! outfit=$(_aip_read_outfit "$text_temp"); then
      command rm -f "$text_temp" "$profiles"
      _aip_error 'remote profile has an invalid outfit label'
      return 1
    fi
    _aip_git -C "$root" show "$tree:$p/skills/.gitkeep" >|"$text_temp" 2>/dev/null || { command rm -f "$text_temp" "$profiles"; return 1; }
    if [ -s "$text_temp" ]; then
      command rm -f "$text_temp" "$profiles"
      _aip_error 'remote profile skills/.gitkeep placeholder must be empty'
      return 1
    fi
    _aip_git -C "$root" show "$tree:$p/claude/CLAUDE.md" >|"$text_temp" 2>/dev/null || { command rm -f "$text_temp" "$profiles"; return 1; }
    IFS= read -r first_line <"$text_temp" || first_line=
    first_line=${first_line%$'\r'}
    command rm -f "$text_temp"
    [ "$first_line" = '@../AGENTS.md' ] || {
      command rm -f "$profiles"
      _aip_error 'remote profile has an invalid Claude import; claude/CLAUDE.md must begin with @../AGENTS.md'
      return 1
    }
    [ "$(_aip_git -C "$root" cat-file -t "$tree:$p/skills" 2>/dev/null)" = tree ] || {
      command rm -f "$profiles"
      _aip_error 'remote profile is missing required skills directory'
      return 1
    }
  done <"$profiles"

  entry=$(_aip_git -C "$root" ls-tree "$tree" -- .gitignore) || {
    command rm -f "$profiles"
    return 1
  }
  case ${entry%% *} in 100644|100755) ;; *)
    command rm -f "$profiles"
    _aip_error 'remote profiles repository is missing the root .gitignore'
    return 1
    ;;
  esac

  command rm -f "$profiles"
  command rm -f "$_AIP_TEMP_PATHS"
  _AIP_TEMP_PATHS=
}

_aip_remove_stale_lock() {
  local lock=$1 pid host current_host
  [ -f "$lock/pid" ] && [ -f "$lock/host" ] || return 1
  pid=$(command cat "$lock/pid" 2>/dev/null) || return 1
  host=$(command cat "$lock/host" 2>/dev/null) || return 1
  current_host=$(command hostname 2>/dev/null) || return 1
  case $pid in ''|*[!0-9]*) return 1 ;; esac
  [ "$host" = "$current_host" ] || return 1
  command kill -0 "$pid" 2>/dev/null && return 1
  command rm -rf -- "$lock"
}

_aip_acquire_lock() {
  local profile=$1 attempts=${_AIP_LOCK_ATTEMPTS-100} attempt=0 pid host timestamp
  case $attempts in ''|*[!0-9]*) attempts=100 ;; esac
  [ "$attempts" -gt 0 ] || attempts=1
  _AIP_SYNC_LOCK=$profile/.git/aip-sync.lock
  while [ "$attempt" -lt "$attempts" ]; do
    if command mkdir "$_AIP_SYNC_LOCK" 2>/dev/null; then
      pid=$(sh -c 'printf "%s\n" "$PPID"') || {
        command rm -rf -- "$_AIP_SYNC_LOCK"
        _aip_error 'could not record sync-lock ownership; the incomplete lock was removed'
        return 1
      }
      host=$(command hostname 2>/dev/null) || {
        command rm -rf -- "$_AIP_SYNC_LOCK"
        _aip_error 'could not record sync-lock ownership; the incomplete lock was removed'
        return 1
      }
      timestamp=$(command date +%s) || {
        command rm -rf -- "$_AIP_SYNC_LOCK"
        _aip_error 'could not record sync-lock ownership; the incomplete lock was removed'
        return 1
      }
      _AIP_SYNC_TOKEN="$pid-$timestamp-${RANDOM-0}"
      if ! printf '%s\n' "$pid" >"$_AIP_SYNC_LOCK/pid" ||
         ! printf '%s\n' "$host" >"$_AIP_SYNC_LOCK/host" ||
         ! printf '%s\n' "$timestamp" >"$_AIP_SYNC_LOCK/timestamp" ||
         ! printf '%s\n' "$_AIP_SYNC_TOKEN" >"$_AIP_SYNC_LOCK/token"; then
        command rm -rf -- "$_AIP_SYNC_LOCK"
        _AIP_SYNC_TOKEN=
        _aip_error 'could not record sync-lock ownership; the incomplete lock was removed'
        return 1
      fi
      return 0
    fi
    _aip_remove_stale_lock "$_AIP_SYNC_LOCK" && continue
    attempt=$((attempt + 1))
    [ "$attempt" -lt "$attempts" ] && command sleep 0.1
  done
  _aip_error "sync is already running for $profile; inspect $_AIP_SYNC_LOCK"
  return 1
}

_aip_release_lock() {
  [ -n "${_AIP_SYNC_LOCK-}" ] && [ -d "$_AIP_SYNC_LOCK" ] || return 0
  [ "$(command cat "$_AIP_SYNC_LOCK/token" 2>/dev/null)" = "${_AIP_SYNC_TOKEN-}" ] || return 0
  command rm -rf -- "$_AIP_SYNC_LOCK"
}

_aip_sync_cleanup() {
  _aip_spinner_stop
  if [ -n "${_AIP_TEMP_PATHS-}" ] && [ -f "$_AIP_TEMP_PATHS" ]; then command rm -f "$_AIP_TEMP_PATHS"; fi
  if [ -n "${_AIP_GIT_OUTPUT-}" ] && [ -f "$_AIP_GIT_OUTPUT" ]; then command rm -f "$_AIP_GIT_OUTPUT"; fi
  _aip_release_lock
}

_aip_check_tracked_forbidden() {
  local root=$1 relative rel forbidden=0 profiles
  profiles=$(command mktemp "${TMPDIR:-/tmp}/aip-profiles.XXXXXX") || return
  _AIP_TEMP_PATHS=$(command mktemp "${TMPDIR:-/tmp}/aip-paths.XXXXXX") || { command rm -f "$profiles"; return; }
  _aip_git -C "$root" ls-files -z >|"$_AIP_TEMP_PATHS" || {
    command rm -f "$profiles"
    return 1
  }
  if ! _aip_validate_portable_paths_file "$_AIP_TEMP_PATHS"; then
    command rm -f "$profiles"
    command rm -f "$_AIP_TEMP_PATHS"
    _AIP_TEMP_PATHS=
    _aip_error "tracked profile contains a path that is not portable to Windows: $_AIP_PORTABLE_PATH_ERROR"
    return 1
  fi
  _aip_profile_prefixes_from_names "$_AIP_TEMP_PATHS" >|"$profiles" || {
    command rm -f "$_AIP_TEMP_PATHS"
    _AIP_TEMP_PATHS=
    command rm -f "$profiles"
    return 1
  }
  while IFS= read -r -d '' relative; do
    rel=$relative
    if _aip_under_profile "$relative" "$profiles"; then rel=${relative#*/}; fi
    if _aip_is_forbidden_path "$rel"; then
      forbidden=1
      break
    fi
  done <"$_AIP_TEMP_PATHS"
  command rm -f "$profiles"
  command rm -f "$_AIP_TEMP_PATHS"
  _AIP_TEMP_PATHS=
  if [ "$forbidden" -eq 1 ]; then
    _aip_error "forbidden credential or runtime path is tracked; inspect with 'git -C \"$root\" ls-files' and remove it with 'git rm --cached PATH'"
    return 1
  fi
}

_aip_check_untracked_skills() {
  local root=$1 name relative forbidden=0
  for name in $(_aip_list_profile_names); do
    _AIP_TEMP_PATHS=$(command mktemp "${TMPDIR:-/tmp}/aip-paths.XXXXXX") || return
    _aip_git -C "$root" ls-files --others --exclude-standard -z -- "$name/skills" >|"$_AIP_TEMP_PATHS" || {
      command rm -f "$_AIP_TEMP_PATHS"
      _AIP_TEMP_PATHS=
      return 1
    }
    if ! _aip_validate_portable_paths_file "$_AIP_TEMP_PATHS"; then
      command rm -f "$_AIP_TEMP_PATHS"
      _AIP_TEMP_PATHS=
      _aip_error "shared skills contain a path that is not portable to Windows: $_AIP_PORTABLE_PATH_ERROR"
      return 1
    fi
    while IFS= read -r -d '' relative; do
      if _aip_is_forbidden_path "${relative#"$name"/}"; then
        forbidden=1
        break
      fi
    done <"$_AIP_TEMP_PATHS"
    command rm -f "$_AIP_TEMP_PATHS"
    _AIP_TEMP_PATHS=
    if [ "$forbidden" -eq 1 ]; then
      _aip_error 'forbidden credential path exists under skills/; remove or ignore it before syncing'
      return 1
    fi
  done
}

_aip_check_skill_repositories() {
  local root=$1 name profile_path nested_git
  for name in $(_aip_list_profile_names); do
    profile_path=$(_aip_profile_path "$name")
    nested_git=$(command find "$profile_path/skills" -mindepth 1 -name .git -print -quit 2>/dev/null) || return
    if [ -n "$nested_git" ]; then
      _aip_error 'nested Git repositories under skills/ are not supported; remove the nested .git directory and sync the skill files directly'
      return 1
    fi
  done
  _AIP_TEMP_PATHS=$(command mktemp "${TMPDIR:-/tmp}/aip-paths.XXXXXX") || return
  _aip_git -C "$root" ls-files --stage >|"$_AIP_TEMP_PATHS" || return
  if command grep -q '^160000 ' "$_AIP_TEMP_PATHS"; then
    command rm -f "$_AIP_TEMP_PATHS"
    _AIP_TEMP_PATHS=
    _aip_error 'Git submodules are not supported in profiles; remove the gitlink and sync ordinary files directly'
    return 1
  fi
  command rm -f "$_AIP_TEMP_PATHS"
  _AIP_TEMP_PATHS=
}

_aip_check_tracked_links() {
  local root=$1 entries record mode relative profiles
  entries=$(command mktemp "${TMPDIR:-/tmp}/aip-index.XXXXXX") || return
  profiles=$(command mktemp "${TMPDIR:-/tmp}/aip-profiles.XXXXXX") || { command rm -f "$entries"; return; }
  _aip_git -C "$root" ls-files --stage -z >|"$entries" || { command rm -f "$entries" "$profiles"; return 1; }
  while IFS= read -r -d '' record; do
    case ${record%% *} in 100644) ;; *) continue ;; esac
    relative=${record#*$'\t'}
    case $relative in */.aip/outfit) printf '%s\n' "${relative%%/*}" >>"$profiles" ;; esac
  done <"$entries"
  # Cleanup unlinks the name; the loop keeps its already-open descriptor.
  # shellcheck disable=SC2094
  while IFS= read -r -d '' record; do
    mode=${record%% *}
    relative=${record#*$'\t'}
    if [ "$mode" = 120000 ] &&
       { ! _aip_under_profile "$relative" "$profiles" || ! _aip_is_required_profile_link "${relative#*/}"; }; then
      command rm -f "$entries" "$profiles"
      _aip_error "tracked profile contains an unsupported symbolic link: $relative"
      return 1
    fi
  done <"$entries"
  command rm -f "$entries" "$profiles"
}

_aip_require_no_linked_profiles() {
  local profile_path name entries
  [ -d "$_AIP_PROFILE_ROOT" ] || return 0
  entries=$(command mktemp "${TMPDIR:-/tmp}/aip-profiles.XXXXXX") || return 1
  command find -H "$_AIP_PROFILE_ROOT" -mindepth 1 -maxdepth 1 -type l -print0 >|"$entries" || { command rm -f "$entries"; return 1; }
  # Cleanup unlinks the name; the loop keeps its already-open descriptor.
  # shellcheck disable=SC2094
  while IFS= read -r -d '' profile_path; do
    name=${profile_path##*/}
    _aip_validate_name "$name" || continue
    { [ -d "$profile_path" ] && { [ -e "$profile_path/.aip/outfit" ] || [ -L "$profile_path/.aip/outfit" ]; }; } || continue
    command rm -f "$entries"
    _aip_error "profile '$name' path must not be a symbolic link"
    return 1
  done <"$entries"
  command rm -f "$entries"
}

_aip_stage_checkpoint() {
  local root=$1 mode=$2 name profile_path
  _aip_require_no_nested_mounts "$root" || return
  _aip_require_no_linked_profiles || return
  _aip_check_tracked_forbidden "$root" || return
  _aip_check_skill_repositories "$root" || return
  _aip_check_tracked_links "$root" || return
  _aip_check_untracked_skills "$root" || return
  for name in $(_aip_list_profile_names); do
    profile_path=$(_aip_profile_path "$name")
    _aip_ensure_skills_placeholder "$profile_path" || return
    _aip_validate_sync_layout "$profile_path" || return
  done
  _aip_git -C "$root" add -u -- . || return
  _aip_git -C "$root" add .gitignore || return
  for name in $(_aip_list_profile_names); do
    _aip_git -C "$root" add \
      "$name/.aip/outfit" "$name/.gitignore" "$name/AGENTS.md" "$name/skills" \
      "$name/claude/CLAUDE.md" "$name/claude/skills" "$name/codex/AGENTS.md" "$name/codex/instructions.md" \
      "$name/codex/skills" "$name/pi/AGENTS.md" "$name/pi/APPEND_SYSTEM.md" "$name/pi/skills" \
      "$name/opencode/AGENTS.md" "$name/opencode/skills" || return
  done
  if ! _aip_git -C "$root" diff --cached --quiet --; then
    _aip_git -C "$root" commit -q -m "aip: checkpoint ($mode)" || {
      _aip_error 'could not commit the local checkpoint; check Git identity and hooks'
      return 1
    }
    printf 'Checkpointed local profile changes.\n'
  fi
}

_aip_require_rebase_preserves_untracked() {
  local profile=$1 upstream_commit=$2 remote_paths local_paths remote_lines local_lines
  remote_paths=$(command mktemp "${TMPDIR:-/tmp}/aip-remote-paths.XXXXXX") || return
  local_paths=$(command mktemp "${TMPDIR:-/tmp}/aip-local-paths.XXXXXX") || { command rm -f "$remote_paths"; return 1; }
  remote_lines=$(command mktemp "${TMPDIR:-/tmp}/aip-remote-lines.XXXXXX") || { command rm -f "$remote_paths" "$local_paths"; return 1; }
  local_lines=$(command mktemp "${TMPDIR:-/tmp}/aip-local-lines.XXXXXX") || { command rm -f "$remote_paths" "$local_paths" "$remote_lines"; return 1; }
  if ! _aip_git -C "$profile" diff --name-only --diff-filter=ACMRT -z HEAD "$upstream_commit" >|"$remote_paths" ||
     ! _aip_git -C "$profile" ls-files --others --exclude-standard -z >|"$local_paths" ||
     ! _aip_git -C "$profile" ls-files --others --ignored --exclude-standard -z >>"$local_paths" ||
     ! command tr '\0' '\n' <"$remote_paths" >"$remote_lines" ||
     ! command tr '\0' '\n' <"$local_paths" >"$local_lines"; then
    command rm -f "$remote_paths" "$local_paths" "$remote_lines" "$local_lines"
    _aip_error 'could not inspect local untracked and ignored paths before integrating the remote profile'
    return 1
  fi
  # One C-locale pass replaces the old per-pair loop: a collision is folded
  # equality or containment in either directory direction. A path containing a
  # literal newline is split into fragments, which can only add collisions.
  if ! LC_ALL=C command awk '
    FILENAME == ARGV[1] {
      p = tolower($0)
      sub(/\/+$/, "", p)
      if (p != "") { locals[++n] = p; seen[p] = 1 }
      next
    }
    {
      r = tolower($0)
      sub(/\/+$/, "", r)
      if (r == "") next
      if (seen[r]) exit 1
      m = split(r, parts, "/")
      prefix = parts[1]
      for (k = 2; k <= m; k++) {
        if (seen[prefix]) exit 1
        prefix = prefix "/" parts[k]
      }
      for (i = 1; i <= n; i++)
        if (index(locals[i], r "/") == 1) exit 1
    }
'  "$local_lines" "$remote_lines"; then
    command rm -f "$remote_paths" "$local_paths" "$remote_lines" "$local_lines"
    _aip_error "remote integration would overwrite or replace untracked or ignored local profile state; inspect with 'git -C \"$profile\" status --ignored --untracked-files=all' and move or deliberately track the conflicting path"
    return 1
  fi
  command rm -f "$remote_paths" "$local_paths" "$remote_lines" "$local_lines"
}

_aip_spinner_start() {
  _AIP_SPIN_PID=
  case ${AIP_ANIMATION-} in
    off) return 0 ;;
    always) ;;
    *) [ -t 1 ] || return 0 ;;
  esac
  (
    while :; do
      printf '\r| syncing '; sleep 0.1
      printf '\r/ syncing '; sleep 0.1
      printf '\r- syncing '; sleep 0.1
      printf '\r\\ syncing '; sleep 0.1
    done
  ) &
  _AIP_SPIN_PID=$!
  if [ -n "${_AIP_SPIN_PIDFILE-}" ]; then printf '%s\n' "$_AIP_SPIN_PID" >"$_AIP_SPIN_PIDFILE" || :; fi
}

_aip_spinner_stop() {
  if [ -n "${_AIP_SPIN_PID-}" ]; then
    kill "$_AIP_SPIN_PID" 2>/dev/null || :
    wait "$_AIP_SPIN_PID" 2>/dev/null || :
    _AIP_SPIN_PID=
    [ -t 1 ] && printf '\r\033[K'
  fi
  if [ -n "${_AIP_SPIN_PIDFILE-}" ] && [ -e "$_AIP_SPIN_PIDFILE" ]; then command rm -f "$_AIP_SPIN_PIDFILE"; fi
}

_aip_sync() (
  local mode=${1-manual} root=$_AIP_PROFILE_ROOT upstream upstream_commit branch remote merge_ref name profile_path pre_sha cur_sha stored_sha remote_sha
  _aip_clear_git_routing
  _AIP_SYNC_LOCK=
  _AIP_SYNC_TOKEN=
  _AIP_TEMP_PATHS=
  _AIP_GIT_OUTPUT=
  _aip_require_root_repo || return
  _aip_require_git_containment "$root" || return
  _aip_acquire_lock "$root" || return
  trap '_aip_sync_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  if _aip_has_unfinished_git_operation "$root" || [ -n "$(_aip_git -C "$root" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
    _aip_error "Git conflict or unfinished operation in $root; run 'git -C \"$root\" status', then resolve and continue or abort it"
    return 1
  fi
  pre_sha=$(_aip_git -C "$root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || pre_sha=
  _aip_stage_checkpoint "$root" "$mode" || return

  if ! _aip_git -C "$root" rev-parse --verify '@{upstream}' >/dev/null 2>&1; then
    printf 'Profiles are local only (no upstream).\n'
    return 0
  fi

  upstream=$(_aip_git -C "$root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}') || return
  branch=$(_aip_git -C "$root" branch --show-current) || return
  remote=$(_aip_git -C "$root" config --get "branch.$branch.remote") || remote=
  merge_ref=$(_aip_git -C "$root" config --get "branch.$branch.merge") || merge_ref=
  [ -n "$remote" ] || { _aip_error 'configured upstream remote is invalid'; return 1; }
  case $merge_ref in refs/heads/*) ;; *) _aip_error 'configured upstream branch is invalid'; return 1 ;; esac
  _AIP_GIT_OUTPUT=$(command mktemp "$root/.git/aip-git.XXXXXX") || return
  _aip_require_git_mutation_state "$root" || return
  if ! _aip_prepare_ssh_transport "$root"; then
    _aip_error 'remote sync unavailable because the configured SSH variant cannot be made non-interactive; using the committed local profiles'
    return 0
  fi
  _aip_spinner_start
  if [ "$mode" = before ] || [ "$mode" = after ]; then
    # Staleness check for harness-triggered syncs: HEAD has not moved since
    # the pre-checkpoint SHA, it matches the last stored remote-tracking ref,
    # and ls-remote proves the remote has not moved, so no round trip is
    # needed. Every failure (no stored ref, ls-remote error) falls through
    # to the full sync below. When the checkpoint committed anything (cur
    # differs from pre), the skip condition can never hold because a push is
    # already required, so the ls-remote probe is skipped with it.
    cur_sha=$(_aip_git -C "$root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || cur_sha=
    if [ "$cur_sha" = "$pre_sha" ]; then
      stored_sha=$(_aip_git -C "$root" rev-parse --verify "refs/remotes/$remote/$branch^{commit}" 2>/dev/null) || stored_sha=
      remote_sha=$(GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_SSH_COMMAND="$_AIP_SSH_COMMAND" GIT_SSH_VARIANT="$_AIP_SSH_VARIANT" LC_ALL=C _aip_git -C "$root" ls-remote "$remote" "$merge_ref" 2>/dev/null | command awk 'NR == 1 { print $1; exit }')
      if [ -n "$remote_sha" ] && [ "$remote_sha" = "$stored_sha" ] && [ "$cur_sha" = "$stored_sha" ]; then
        _aip_spinner_stop
        printf 'Profiles up to date with %s.\n' "$upstream"
        return 0
      fi
    fi
  fi
  if ! GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_SSH_COMMAND="$_AIP_SSH_COMMAND" GIT_SSH_VARIANT="$_AIP_SSH_VARIANT" LC_ALL=C _aip_git -C "$root" fetch --quiet "$remote" >|"$_AIP_GIT_OUTPUT" 2>&1; then
    _aip_require_git_mutation_state "$root" || return
    _aip_error 'remote sync unavailable; using the committed local profiles and retrying next time'
    return 0
  fi
  upstream_commit=$(_aip_git -C "$root" rev-parse --verify "$upstream^{commit}") || return
  _aip_validate_git_tree "$root" "$upstream_commit" || return
  _aip_require_rebase_preserves_untracked "$root" "$upstream_commit" || return
  if ! LC_ALL=C _aip_git -C "$root" rebase "$upstream_commit" >|"$_AIP_GIT_OUTPUT" 2>&1; then
    if _aip_has_unfinished_git_operation "$root" || [ -n "$(_aip_git -C "$root" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
      _aip_error "Git conflict in $root; no side was chosen. Run 'git -C \"$root\" status', resolve files, then use 'git rebase --continue' or 'git rebase --abort'"
    else
      _aip_error "local Git integration failed in $root; inspect it with 'git -C \"$root\" status'"
    fi
    return 1
  fi
  for name in $(_aip_list_profile_names); do
    profile_path=$(_aip_profile_path "$name")
    _aip_validate_sync_layout "$profile_path" || return
  done
  _aip_check_tracked_forbidden "$root" || return
  _aip_check_untracked_skills "$root" || return
  _aip_require_git_mutation_state "$root" || return
  if ! GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_SSH_COMMAND="$_AIP_SSH_COMMAND" GIT_SSH_VARIANT="$_AIP_SSH_VARIANT" LC_ALL=C _aip_git -C "$root" push --quiet "$remote" "HEAD:$merge_ref" >|"$_AIP_GIT_OUTPUT" 2>&1; then
    _aip_require_git_mutation_state "$root" || return
    _aip_error 'remote sync unavailable during push; the local checkpoint is safe and will retry next time'
    return 0
  fi
  _aip_spinner_stop
  printf 'Profiles synced with %s.\n' "$upstream"
)


_aip_sync_command() {
  [ "$#" -le 1 ] || {
    _aip_error 'usage: aip sync'
    return 2
  }
  if [ "$#" -eq 1 ]; then
    _aip_error "unexpected argument '$1'; aip sync syncs every profile in the profiles repository"
    return 2
  fi
  _aip_sync manual
}

_aip_toml_string() {
  local value=${1-} printable
  printable=${value//$'\b'/}
  printable=${printable//$'\t'/}
  printable=${printable//$'\n'/}
  printable=${printable//$'\f'/}
  printable=${printable//$'\r'/}
  if LC_ALL=C printf '%s' "$printable" | command grep -q '[[:cntrl:]]'; then
    _aip_error 'Codex instructions contain a control character that TOML cannot represent safely'
    return 1
  fi
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\b'/\\b}
  value=${value//$'\t'/\\t}
  value=${value//$'\n'/\\n}
  value=${value//$'\f'/\\f}
  value=${value//$'\r'/\\r}
  printf '"%s"' "$value"
}

_aip_run_harness() (
  local explicit_supplied=$1 explicit=$2 harness=$3 profile_path real child_status instructions _AIP_CHILD_SIGNAL_STATUS=
  shift 3

  _aip_is_harness "$harness" || {
    _aip_error "unknown harness '$harness'; expected claude, codex, pi, or opencode"
    return 2
  }
  if [ "$explicit_supplied" -eq 1 ]; then _aip_resolve_profile "$explicit" || return
  else _aip_resolve_profile || return
  fi
  profile_path=$(_aip_profile_path "$_AIP_RESOLVED_NAME")
  _aip_passthrough "$harness" "$_AIP_RESOLVED_NAME"
  real=$(_aip_find_real_command "$harness") || {
    _aip_error "$harness executable was not found in PATH"
    return 127
  }
  _aip_sync before || return
  trap '_AIP_CHILD_SIGNAL_STATUS=130' INT
  trap '_AIP_CHILD_SIGNAL_STATUS=143' TERM
  trap '_AIP_CHILD_SIGNAL_STATUS=129' HUP

  case $harness in
    claude)
      CLAUDE_CONFIG_DIR=$profile_path/claude
      export CLAUDE_CONFIG_DIR
      if "$real" "$@"; then child_status=0; else child_status=$?; fi
      ;;
    codex)
      CODEX_HOME=$profile_path/codex
      export CODEX_HOME
      _aip_validate_utf8_text_file "$profile_path/codex/instructions.md" || {
        _aip_error 'Codex instructions must be valid NUL-free UTF-8'
        return 1
      }
      instructions=$(command cat "$profile_path/codex/instructions.md") || return
      while :; do
        case $instructions in
          *$'\r') instructions=${instructions%$'\r'} ;;
          *$'\n') instructions=${instructions%$'\n'} ;;
          *) break ;;
        esac
      done
      instructions=$(_aip_toml_string "$instructions") || return
      if "$real" -c "developer_instructions=$instructions" "$@"; then child_status=0; else child_status=$?; fi
      ;;
    pi)
      PI_CODING_AGENT_DIR=$profile_path/pi
      export PI_CODING_AGENT_DIR
      if "$real" "$@"; then child_status=0; else child_status=$?; fi
      ;;
    opencode)
      OPENCODE_CONFIG_DIR=$profile_path/opencode
      export OPENCODE_CONFIG_DIR
      if "$real" "$@"; then child_status=0; else child_status=$?; fi
      ;;
  esac

  trap - INT TERM HUP
  if [ -n "$_AIP_CHILD_SIGNAL_STATUS" ]; then child_status=$_AIP_CHILD_SIGNAL_STATUS; fi

  _aip_sync after || :
  return "$child_status"
)

_aip_run() {
  [ "$#" -ge 1 ] || {
    _aip_error 'usage: aip run [NAME] HARNESS [ARGS...]'
    return 2
  }
  local explicit_supplied=0 explicit='' harness
  if [ "$#" -ge 2 ] && _aip_is_harness "$1" && _aip_is_harness "$2" &&
     { [ -e "$(_aip_profile_path "$1")" ] || [ -L "$(_aip_profile_path "$1")" ]; }; then
    explicit_supplied=1
    explicit=$1
    harness=$2
    shift 2
  elif _aip_is_harness "$1"; then
    harness=$1
    shift
  else
    [ "$#" -ge 2 ] || {
      _aip_error "unknown harness '$1'; expected claude, codex, pi, or opencode"
      return 2
    }
    explicit_supplied=1
    explicit=$1
    harness=$2
    shift 2
  fi
  _aip_run_harness "$explicit_supplied" "$explicit" "$harness" "$@"
}

_aip_import_harness_root() {
  case ${1-} in
    pi) printf '%s\n' "${HOME}/.pi/agent" ;;
    claude) printf '%s\n' "${HOME}/.claude" ;;
    codex) printf '%s\n' "${HOME}/.codex" ;;
    opencode) printf '%s\n' "${HOME}/.config/opencode" ;;
    *) return 1 ;;
  esac
}

_aip_import_usage() {
  _aip_error 'usage: aip import HARNESS [FILE...] [--profile NAME[,NAME...]] [--all-profiles] [--force] [--skip-existing] [--dry-run]'
}

_aip_import_validate_rel() {
  local rel=${1-}
  [ -n "$rel" ] || return 1
  case $rel in
    /*|*'/'|.|..|*/..|../*|*/../*) return 1 ;;
  esac
  return 0
}

_aip_import_require_profile() {
  local name=$1 profile_path
  _aip_validate_name "$name" || { _aip_error "invalid profile name '$name'"; return 2; }
  profile_path=$(_aip_profile_path "$name")
  [ -d "$profile_path" ] && [ ! -L "$profile_path" ] || {
    _aip_error "profile '$name' does not exist"
    return 2
  }
}

_aip_import_write_profiles() {
  local list=$1 file=$2 name remaining
  remaining=$list
  while [ -n "$remaining" ]; do
    name=${remaining%%,*}
    case $remaining in
      *',' ) remaining='' ;;
      *','*) remaining=${remaining#*,} ;;
      *) remaining='' ;;
    esac
    _aip_import_require_profile "$name" || return 2
    printf '%s\n' "$name" >>"$file"
  done
}

_aip_import_is_managed_link() {
  local target
  [ -L "$1" ] || return 1
  target=$(command readlink "$1" 2>/dev/null) || return 1
  [ "$target" = ../AGENTS.md ] || [ "$target" = ../skills ] || return 1
  return 0
}

_aip_import_copy_one() {
  # $1 source file, $2 dest, $3 overwrite (ask|force|skip), $4 profile, $5 rel,
  # $6 dry-run, $7 harness, $8 profile path
  # sets _AIP_IMPORT_OVERWRITE on 'a'/'n'; returns 0 copied, 3 skipped, 1 error, 2 abort
  local source=$1 dest=$2 overwrite=$3 name=$4 rel=$5 dry_run=$6 harness=$7 profile_path=$8
  local overwrite_this=0 answer parent passthrough_replaced=0
  if [ "$dry_run" -eq 1 ]; then
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      printf 'copy %s -> %s/%s (exists)\n' "$rel" "$name" "$rel"
    else
      printf 'copy %s -> %s/%s\n' "$rel" "$name" "$rel"
    fi
    return 0
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if _aip_import_is_managed_link "$dest"; then
      _aip_error "refusing to overwrite the profile link $name/$rel"
      return 1
    fi
    # A pass-through link is replaceable: the imported profile-owned copy becomes the
    # profile's own version (and its .gitignore entry is dropped below so the copy
    # can be tracked again).
    if [ -L "$dest" ] && _aip_is_passthrough_link "$harness/$rel" "$profile_path"; then
      passthrough_replaced=1
    fi
    case $overwrite in
      force) overwrite_this=1 ;;
      skip) overwrite_this=0 ;;
      ask)
        while :; do
          printf 'aip: %s/%s exists: [o]verwrite [s]kip [a]ll [n]one [q]uit: ' "$name" "$rel" >&2
          IFS= read -r answer <&3 || { overwrite_this=0; break; }
          case $answer in
            o|O) overwrite_this=1; break ;;
            s|S) overwrite_this=0; break ;;
            a|A) overwrite_this=1; _AIP_IMPORT_OVERWRITE=force; break ;;
            n|N) overwrite_this=0; _AIP_IMPORT_OVERWRITE=skip; break ;;
            q|Q) return 2 ;;
          esac
        done
        ;;
    esac
    [ "$overwrite_this" -eq 1 ] || return 3
  fi
  parent=${dest%/*}
  command mkdir -p "$parent" || return 1
  [ ! -L "$dest" ] || command rm -f "$dest"
  command cp -p "$source" "$dest" || return 1
  if [ "$passthrough_replaced" -eq 1 ]; then
    _aip_gitignore_remove_passthrough_entry "$profile_path/.gitignore" "$harness/$rel" || return 1
  fi
  return 0
}

_aip_import_run_copy() {
  # $1 harness, $2 source_root, $3 dry-run, $4 filelist (NUL), $5 profilesfile (newline)
  # $6 force (0|1), $7 skip_existing (0|1)
  local harness=$1 source_root=$2 dry_run=$3 filelist=$4 profilesfile=$5 force=$6 skip_existing=$7
  local name profile_path rel dest overwrite=ask
  local copied=0 skipped=0 errors=0 aborted=0 profile_count=0
  if [ "$force" -eq 1 ]; then _AIP_IMPORT_OVERWRITE=force
  elif [ "$skip_existing" -eq 1 ]; then _AIP_IMPORT_OVERWRITE=skip
  else _AIP_IMPORT_OVERWRITE=ask
  fi
  exec 3<&0 || return 1
  while IFS= read -r name || [ -n "$name" ]; do
    [ -n "$name" ] || continue
    profile_count=$((profile_count + 1))
    profile_path=$(_aip_profile_path "$name")
    while IFS= read -r -d '' rel; do
      [ -n "$rel" ] || continue
      dest=$profile_path/$harness/$rel
      case $_AIP_IMPORT_OVERWRITE in
        force) overwrite=force ;;
        skip) overwrite=skip ;;
        *) overwrite=ask ;;
      esac
      _aip_import_copy_one "$source_root/$rel" "$dest" "$overwrite" "$name" "$rel" "$dry_run" "$harness" "$profile_path"
      case $? in
        0) copied=$((copied + 1)) ;;
        3) skipped=$((skipped + 1)) ;;
        1) errors=1 ;;
        2) aborted=1; break 2 ;;
      esac
    done <"$filelist"
  done <"$profilesfile"
  if [ "$dry_run" -eq 0 ]; then
    if [ "$aborted" -eq 1 ]; then
      _aip_error "import cancelled; $copied file(s) copied so far"
      return 1
    fi
    if [ "$copied" -gt 0 ]; then
      printf 'aip: imported %s file(s) into %s profile(s)\n' "$copied" "$profile_count"
      [ "$skipped" -eq 0 ] || printf 'aip: %s existing file(s) skipped\n' "$skipped"
    else
      printf 'aip: no files were copied\n'
    fi
  fi
  [ "$errors" -eq 0 ] || return 1
  return 0
}

_aip_import_warn_tracked() {
  local harness=$1 filelist=$2 profilesfile=$3 name rel dest first=1
  [ -d "$_AIP_PROFILE_ROOT/.git" ] || return 0
  while IFS= read -r name || [ -n "$name" ]; do
    [ -n "$name" ] || continue
    while IFS= read -r -d '' rel; do
      [ -n "$rel" ] || continue
      dest=$name/$harness/$rel
      if _aip_git -C "$_AIP_PROFILE_ROOT" check-ignore -q -- "$dest"; then :; else
        if [ "$first" -eq 1 ]; then
          _aip_error 'the next sync checkpoint may track these imported files (not covered by the profile .gitignore):'
          first=0
        fi
        printf '  %s\n' "$dest" >&2
      fi
    done <"$filelist"
  done <"$profilesfile"
  return 0
}

_aip_import_interactive() {
  # $1 harness, $2 source_root, $3 filelist (NUL), $4 profilesfile (newline)
  # $5 profiles_opt (--profile list), $6 all_profiles (0|1)
  local harness=$1 source_root=$2 filelist=$3 profilesfile=$4 profiles_opt=$5 all_profiles=$6
  local node picker output status rel name record args
  node=$(command -v node) || { _aip_error 'interactive import requires Node.js (node) on PATH'; return 1; }
  picker=${AIP_PICKER:-}
  if [ -z "$picker" ]; then
    if [ -n "$_AIP_PICKER_DIR" ]; then picker=$_AIP_PICKER_DIR/bin/aip-picker.js
    else picker=${XDG_DATA_HOME:-$HOME/.local/share}/aip/bin/aip-picker.js
    fi
  fi
  [ -f "$picker" ] || { _aip_error "the interactive picker was not found at: $picker"; return 1; }
  if [ "$all_profiles" -eq 1 ]; then
    args="--all-profiles $(tr '\n' ' ' <"$profilesfile")"
  elif [ -n "$profiles_opt" ]; then
    args="--profiles $profiles_opt"
  else
    args=$(tr '\n' ' ' <"$profilesfile")
  fi
  output=$(command mktemp "${TMPDIR:-/tmp}/aip-picker.XXXXXX") || return 1
  # shellcheck disable=SC2086
  # Records go to $output on stdout; the picker's UI and errors render on stderr,
  # which must reach the terminal (the interactive path is TTY-gated by the caller).
  node "$picker" "$harness" "$source_root" $args >"$output"
  status=$?
  [ "$status" -eq 0 ] || {
    [ "$status" -eq 130 ] && _aip_error 'import cancelled' || _aip_error 'the interactive picker failed'
    command rm -f "$output"
    return 1
  }
  : >|"$filelist"
  : >|"$profilesfile"
  while IFS= read -r -d '' record; do
    case $record in
      file)
        IFS= read -r -d '' rel || break
        if _aip_import_validate_rel "$rel" && [ -f "$source_root/$rel" ]; then
          printf '%s\0' "$rel" >>"$filelist"
        fi
        ;;
      profile)
        IFS= read -r -d '' name || break
        if _aip_import_require_profile "$name"; then
          printf '%s\n' "$name" >>"$profilesfile"
        else
          command rm -f "$output"
          return 2
        fi
        ;;
    esac
  done <"$output"
  command rm -f "$output"
  return 0
}

_aip_import() (
  _aip_clear_git_routing
  local harness='' profiles_opt='' all_profiles=0 force=0 skip_existing=0 dry_run=0
  local arg filelist profilesfile source_root valid rel
  filelist=$(command mktemp "${TMPDIR:-/tmp}/aip-import-files.XXXXXX") || return 1
  profilesfile=$(command mktemp "${TMPDIR:-/tmp}/aip-import-profiles.XXXXXX") || { command rm -f "$filelist"; return 1; }
  trap 'command rm -f "$filelist" "$profilesfile"' EXIT
  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    case $arg in
      --profile)
        [ "$#" -gt 0 ] && [ -z "$profiles_opt" ] || { _aip_import_usage; return 2; }
        profiles_opt=$1
        shift
        ;;
      --all-profiles) all_profiles=1 ;;
      --force) force=1 ;;
      --skip-existing) skip_existing=1 ;;
      --dry-run) dry_run=1 ;;
      --)
        while [ "$#" -gt 0 ]; do
          printf '%s\0' "$1" >>"$filelist"
          shift
        done
        ;;
      -*)
        _aip_error "unknown import option '$arg'"
        _aip_import_usage
        return 2
        ;;
      *)
        if [ -z "$harness" ]; then harness=$arg
        else printf '%s\0' "$arg" >>"$filelist"
        fi
        ;;
    esac
  done
  [ -n "$harness" ] || { _aip_import_usage; return 2; }
  source_root=$(_aip_import_harness_root "$harness") || {
    _aip_error "unknown harness '$harness'; expected pi, claude, codex, or opencode"
    return 2
  }
  [ -d "$source_root" ] || { _aip_error "no $harness configuration found at: $source_root"; return 1; }
  { [ "$force" -eq 1 ] && [ "$skip_existing" -eq 1 ]; } && { _aip_error '--force and --skip-existing conflict'; return 2; }
  { [ "$all_profiles" -eq 1 ] && [ -n "$profiles_opt" ]; } && { _aip_error '--profile and --all-profiles conflict'; return 2; }
  if [ ! -s "$filelist" ]; then
    if [ -t 0 ] && [ -t 1 ]; then
      if [ "$all_profiles" -eq 1 ]; then
        _aip_list_profile_names >|"$profilesfile"
      elif [ -n "$profiles_opt" ]; then
        _aip_import_write_profiles "$profiles_opt" "$profilesfile" || return
      fi
      [ -s "$profilesfile" ] || { _aip_error 'no profiles found; create a profile with aip create first'; return 1; }
      _aip_import_interactive "$harness" "$source_root" "$filelist" "$profilesfile" "$profiles_opt" "$all_profiles" || return
      [ -s "$filelist" ] || { _aip_error 'no files selected; nothing to copy'; return 1; }
    else
      _aip_error 'no files given and no terminal available; pass FILE... or run aip import in a terminal'
      _aip_import_usage
      return 2
    fi
  else
    if [ "$all_profiles" -eq 0 ] && [ -z "$profiles_opt" ]; then
      _aip_error 'no profiles selected; pass --profile NAME or --all-profiles'
      _aip_import_usage
      return 2
    fi
    valid=1
    while IFS= read -r -d '' rel; do
      [ -n "$rel" ] || continue
      _aip_import_validate_rel "$rel" || { _aip_error "invalid file path: $rel"; valid=0; break; }
      [ -f "$source_root/$rel" ] || { _aip_error "no such file in the $harness configuration: $rel"; valid=0; break; }
    done <"$filelist"
    [ "$valid" -eq 1 ] || return 1
    if [ "$all_profiles" -eq 1 ]; then
      _aip_list_profile_names >|"$profilesfile"
    else
      _aip_import_write_profiles "$profiles_opt" "$profilesfile" || return
    fi
  fi
  [ -s "$profilesfile" ] || { _aip_error 'no profiles selected; nothing to do'; return 1; }
  _aip_import_run_copy "$harness" "$source_root" "$dry_run" "$filelist" "$profilesfile" "$force" "$skip_existing" || return
  [ "$dry_run" -eq 1 ] || _aip_import_warn_tracked "$harness" "$filelist" "$profilesfile"
  return 0
)

_aip_help() {
  [ "$#" -eq 0 ] || { _aip_error 'usage: aip help'; return 2; }
  cat <<'EOF'
aip — shared AI profiles for Claude Code, Codex, Pi, and OpenCode

A profile is one directory: shared AGENTS.md instructions, shared skills/, and
per-harness launch settings. Every profile lives in a single Git repository
(the profiles repository, ~/agent-profiles by default), so one remote keeps
all of your profiles in sync across all of your machines.

Commands:
  aip create NAME [--outfit OUTFIT]  Create a new profile
  aip list                           List profiles, outfits, and selection
  aip which [NAME]                   Show the profile that would be selected
  aip default [NAME]                 Show or set the default profile
  aip use NAME                       Select NAME for this shell only
  aip local [NAME | --remove]        Set or clear the per-directory marker
  aip outfit NAME OUTFIT             Set a profile's outfit (label)
  aip clone SOURCE TARGET            Copy a profile into a new profile
  aip delete NAME [--force]          Delete a profile
  aip sync                           Checkpoint and sync every profile
  aip remote add URL                 Connect the profiles repository to a remote
  aip remote show                    Show the configured remote (if any)
  aip remote remove                  Disconnect the remote
  aip import HARNESS [FILE...]      Copy config/skills from a harness into profiles
  aip doctor [NAME]                  Diagnose the repository and profiles
  aip run [NAME] HARNESS [ARGS...]   Launch a harness with a profile
  aip update                         Update the aip npm package
  aip version                        Show the aip version
  aip help                           Show this help

Harness wrappers:
  claude, codex, pi, opencode [ARGS...] launch the named tool with the
  selected profile's settings, checkpointing the profiles repository before
  and after the run. If the remote is unreachable they warn and launch the
  committed local profile instead; a Git conflict blocks the launch until
  it is resolved.

Quick start:
  aip create work --outfit suit   create your first profile
  aip remote add <git-url>        connect a shared remote (empty remote ok)
  aip default work                choose your everyday profile
  cd my-project && claude         work with your profile

On a second machine:
  aip remote add <same-git-url>   clones every profile you already have

See the README for full documentation, including Windows setup and the
security guarantees aip enforces on syncable content.
EOF
}

_aip_remote_show() {
  local root=$_AIP_PROFILE_ROOT url
  if [ -d "$root/.git" ] && [ ! -L "$root/.git" ] && url=$(_aip_git -C "$root" remote get-url origin 2>/dev/null); then
    printf '%s\n' "$url"
    return 0
  fi
  printf 'no remote is configured\n'
  return 0
}

_aip_remote_remove() {
  local root=$_AIP_PROFILE_ROOT branch
  if { [ -d "$root/.git" ] && [ ! -L "$root/.git" ]; } && _aip_git -C "$root" remote get-url origin >/dev/null 2>&1; then
    _aip_git -C "$root" remote remove origin 2>/dev/null || {
      _aip_error 'could not remove the origin remote; inspect the profiles repository'
      return 1
    }
    branch=$(_aip_git -C "$root" branch --show-current 2>/dev/null) || branch=
    if [ -n "$branch" ]; then
      _aip_git -C "$root" branch --unset-upstream 2>/dev/null || :
    fi
    printf 'Remote removed; profiles are now local only.\n'
    return 0
  fi
  printf 'no remote is configured\n'
  return 0
}

_aip_remote_add() {
  local url=$1 root=$_AIP_PROFILE_ROOT existing_origin
  [ -n "$url" ] || { _aip_error 'usage: aip remote add URL'; return 2; }
  case $url in
    *' '*|*$'\n'*) _aip_error "invalid remote URL: $url"; return 2 ;;
  esac
  if [ -d "$root/.git" ] && [ ! -L "$root/.git" ]; then
    existing_origin=$(_aip_git -C "$root" remote get-url origin 2>/dev/null) || existing_origin=
    if [ -n "$existing_origin" ]; then
      _aip_error "origin is already configured ($existing_origin); run 'aip remote remove' first"
      return 1
    fi
    _aip_git -C "$root" remote add origin "$url" 2>/dev/null || {
      _aip_error "could not configure origin: $url"
      return 1
    }
  else
    if [ -e "$root" ] && [ ! -d "$root" ]; then
      _aip_error "profiles path exists and is not a directory: $root"
      return 1
    fi
    if [ -d "$root/.git" ]; then
      _aip_error "profiles repository metadata is missing or linked: $root/.git"
      return 1
    fi
    if [ -d "$root" ] && [ -n "$(command ls -A -- "$root" 2>/dev/null)" ]; then
      _aip_error "profiles directory already contains content: $root; use 'aip create NAME' instead of 'aip remote add'"
      return 1
    fi
    command mkdir -p -- "$root" || { _aip_error "could not create the profiles directory: $root"; return 1; }
    if ! _aip_prepare_ssh_transport "$root"; then
      _aip_error 'remote is unavailable because the configured SSH variant cannot be made non-interactive'
      return 1
    fi
    if ! GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_SSH_COMMAND="$_AIP_SSH_COMMAND" GIT_SSH_VARIANT="$_AIP_SSH_VARIANT" LC_ALL=C _aip_git clone --quiet -- "$url" "$root" 2>/dev/null; then
      _aip_error "could not clone $url into $root; the remote must be a profiles repository created by aip"
      return 1
    fi
    _aip_git -C "$root" config core.symlinks true || { _aip_error 'could not configure symbolic-link checkout'; return 1; }
    _aip_git -C "$root" config core.longpaths true 2>/dev/null || :
    if ! _aip_git -C "$root" rev-parse --verify HEAD >/dev/null 2>&1 &&
       _aip_git -C "$root" rev-parse --verify refs/remotes/origin/main >/dev/null 2>&1; then
      _aip_git -C "$root" checkout -q -B main refs/remotes/origin/main 2>/dev/null || {
        _aip_error 'could not check out the cloned profiles branch'
        return 1
      }
    fi
    printf 'Cloned profiles from %s.\n' "$url"
  fi
  local branch
  branch=$(_aip_git -C "$root" branch --show-current 2>/dev/null) || branch=
  if [ -z "$branch" ]; then
    _aip_error 'cannot attach a remote while detached from a branch'
    return 1
  fi
  if ! _aip_prepare_ssh_transport "$root"; then
    _aip_error 'remote is unavailable because the configured SSH variant cannot be made non-interactive'
    return 1
  fi
  if ! GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_SSH_COMMAND="$_AIP_SSH_COMMAND" GIT_SSH_VARIANT="$_AIP_SSH_VARIANT" LC_ALL=C _aip_git -C "$root" fetch --quiet origin 2>/dev/null; then
    _aip_error 'could not fetch origin; check that the remote is reachable and that credentials are not required interactively'
    return 1
  fi
  if _aip_git -C "$root" rev-parse --verify "refs/remotes/origin/$branch" >/dev/null 2>&1; then
    _aip_git -C "$root" branch --set-upstream-to="origin/$branch" "$branch" 2>/dev/null || {
      _aip_error "could not attach branch $branch to origin"
      return 1
    }
    _aip_sync manual
    return
  fi
  _aip_check_tracked_forbidden "$root" || return
  if ! GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_SSH_COMMAND="$_AIP_SSH_COMMAND" GIT_SSH_VARIANT="$_AIP_SSH_VARIANT" LC_ALL=C _aip_git -C "$root" push --quiet -u origin "HEAD:refs/heads/$branch" 2>/dev/null; then
    _aip_error 'could not publish the profiles repository to origin; the remote may need to be empty'
    return 1
  fi
  printf 'Profiles published to origin/%s.\n' "$branch"
}

_aip_remote() {
  local sub=${1-}
  _aip_clear_git_routing
  if [ -z "$sub" ]; then
    _aip_error 'usage: aip remote add URL | aip remote show | aip remote remove'
    return 2
  fi
  shift
  case $sub in
    add)
      [ "$#" -eq 1 ] || { _aip_error 'usage: aip remote add URL'; return 2; }
      _aip_remote_add "$1"
      ;;
    show)
      [ "$#" -eq 0 ] || { _aip_error 'usage: aip remote show'; return 2; }
      _aip_remote_show
      ;;
    remove)
      [ "$#" -eq 0 ] || { _aip_error 'usage: aip remote remove'; return 2; }
      _aip_remote_remove
      ;;
    *)
      _aip_error "unknown remote command '$sub'; usage: aip remote add URL | aip remote show | aip remote remove"
      return 2
      ;;
  esac
}

aip() {
  if [ "$#" -eq 0 ]; then
    _aip_status
    return
  fi
  local command=$1
  shift
  _aip_is_command "$command" || { _aip_error "unknown command '$command'"; return 2; }
  case $command in
    create) _aip_create "$@" ;;
    clone) _aip_clone "$@" ;;
    default) _aip_default "$@" ;;
    delete) _aip_delete "$@" ;;
    doctor) _aip_doctor "$@" ;;
    list) _aip_list "$@" ;;
    local) _aip_local "$@" ;;
    outfit) _aip_outfit "$@" ;;
    help) _aip_help "$@" ;;
    --help) _aip_help ;;
    -h) _aip_help ;;
    remote) _aip_remote "$@" ;;
    import) _aip_import "$@" ;;
    run) _aip_run "$@" ;;
    sync) _aip_sync_command "$@" ;;
    use) _aip_use "$@" ;;
    update) _aip_update "$@" ;;
    version) _aip_version "$@" ;;
    which) _aip_which "$@" ;;
  esac
}

claude() {
  _aip_run_harness 0 '' claude "$@"
}

codex() {
  _aip_run_harness 0 '' codex "$@"
}

pi() {
  _aip_run_harness 0 '' pi "$@"
}

opencode() {
  _aip_run_harness 0 '' opencode "$@"
}
