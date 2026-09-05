# aip — AI Profile for Bash and Zsh. Source this file from your shell profile.

: "${_AIP_PROFILE_ROOT:=${HOME}/agent-profiles}"
_AIP_VERSION='0.8.1'
if [ -z "${_AIP_RUNTIME_ROOT-}" ]; then
  if [ -n "${BASH_VERSION-}" ]; then
    _AIP_RUNTIME_SOURCE=${BASH_SOURCE[0]}
  elif [ -n "${ZSH_VERSION-}" ]; then
    _AIP_RUNTIME_SOURCE=$(eval 'printf %s "${(%):-%x}"')
  else
    _AIP_RUNTIME_SOURCE=$0
  fi
  _AIP_RUNTIME_ROOT=$(CDPATH='' cd -- "$(dirname -- "$_AIP_RUNTIME_SOURCE")" && pwd -P)
fi
: "${_AIP_STATUS_EXTENSION:=$_AIP_RUNTIME_ROOT/extensions/aip-status.ts}"

_aip_error() {
  printf 'aip: %s\n' "$*" >&2
}

_aip_warn() {
  printf 'aip: warning: %s\n' "$*" >&2
}

_aip_update() {
  [ "$#" -eq 0 ] || { _aip_error 'usage: aip update'; return 2; }
  (
    _aip_clear_git_routing
    _aip_migrate_legacy_primary_config_links
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
    { [ -e "$profile_path/.gitignore" ] || [ -L "$profile_path/.gitignore" ]; } || continue
    printf '%s\n' "$name"
  done <"$entries"
  command rm -f "$entries"
}

_aip_list_doctor_profile_names() {
  # Doctor includes malformed profile directories so it can describe every
  # recoverable layout/link defect rather than hiding entries without .gitignore.
  local profile_path name entries
  [ -d "$_AIP_PROFILE_ROOT" ] || return 0
  entries=$(command mktemp "${TMPDIR:-/tmp}/aip-profiles.XXXXXX") || return 1
  command find -H "$_AIP_PROFILE_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 >|"$entries" || { command rm -f "$entries"; return 1; }
  while IFS= read -r -d '' profile_path; do
    [ ! -L "$profile_path" ] || continue
    name=${profile_path##*/}
    _aip_validate_name "$name" || continue
    printf '%s\n' "$name"
  done <"$entries" | LC_ALL=C command sort
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
       ! _aip_git -C "$root" config --replace-all core.symlinks true ||
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
  printf '%s\n' "$value" | LC_ALL=C command grep -Eq '^[a-z0-9]([a-z0-9_-]{0,62}[a-z0-9])?$' || return 1
  case $value in con|prn|aux|nul|com[1-9]|lpt[1-9]) return 1 ;; esac
}

_aip_delete_confirm_accepts() {
  case ${1-} in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

_aip_has_disallowed_control() {
  # Reject U+0000–U+001F, U+007F, U+0080–U+009F by decoded UTF-8 codepoint.
  # Continuation bytes such as 0x85 inside emoji must not match.
  printf '%s' "$1" | LC_ALL=C command od -An -t u1 -v | command awk '
    {
      for (i = 1; i <= NF; i++) {
        b = $i + 0
        if (need == 0) {
          if (b <= 127) { cp = b; need = 0 }
          else if (b >= 194 && b <= 223) { cp = b - 192; need = 1 }
          else if (b >= 224 && b <= 239) { cp = b - 224; need = 2 }
          else if (b >= 240 && b <= 244) { cp = b - 240; need = 3 }
          else { invalid = 1 }
        } else {
          if (b < 128 || b > 191) { invalid = 1 }
          else { cp = cp * 64 + (b - 128); need-- }
        }
        if (need == 0) {
          if (cp <= 31 || cp == 127 || (cp >= 128 && cp <= 159)) invalid = 1
        }
      }
    }
    END { if (invalid) exit 0; exit 1 }
  '
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


_aip_is_required_profile_link() {
  case ${1-} in
    claude/skills|codex/AGENTS.md|codex/skills|pi/AGENTS.md|pi/skills|opencode/AGENTS.md|opencode/skills) return 0 ;;
    *) return 1 ;;
  esac
}

_aip_required_link_target() {
  # $1 = a full tracked/remote relative path (e.g. work/claude/skills). Prints the
  # exact target aip creates for its fixed required profile links, requiring a
  # profile prefix, so root-level lookalikes are rejected. Returns 1 for any path
  # aip does not link.
  local path=${1-} rel
  [ "$path" = "${path%%/*}" ] && return 1
  rel=${path#*/}
  case $rel in
    claude/skills|codex/skills|pi/skills|opencode/skills) printf '%s\n' '../skills' ;;
    codex/AGENTS.md|pi/AGENTS.md|opencode/AGENTS.md) printf '%s\n' '../AGENTS.md' ;;
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
    # node_modules is machine-local and forbidden from ever being tracked
    # (see _aip_is_forbidden_path); the links npm creates inside it are
    # npm's, not the profile's, so they are exempt from this check.
    case $relative in
      node_modules|node_modules/*|*/node_modules|*/node_modules/*) continue ;;
    esac
    if ! _aip_is_required_profile_link "$relative" && ! _aip_is_passthrough_link "$relative" "$profile"; then
      if _aip_is_legacy_primary_config_link "$relative" "$profile"; then
        _aip_warn "legacy primary-config link $relative is tolerated until migration; run 'aip update' to make it profile-owned"
        continue
      fi
      command rm -f "$entries"
      _aip_error "profile contains an unsupported symbolic link that could escape its boundary: $relative"
      return 1
    fi
  done <"$entries"
  command rm -f "$entries"
}

_aip_doctor_check_live_profile_links() {
  # Doctor reports every invalid live link; sync keeps the fail-fast checker above.
  local profile=$1 name=$2 entries link_path relative errors=0
  entries=$(command mktemp "${TMPDIR:-/tmp}/aip-links.XXXXXX") || return 1
  command find "$profile" -path "$profile/.git" -prune -o -type l -print0 >|"$entries" || { command rm -f "$entries"; return 1; }
  while IFS= read -r -d '' link_path; do
    relative=${link_path#"$profile"/}
    case $relative in
      node_modules|node_modules/*|*/node_modules|*/node_modules/*) continue ;;
    esac
    if ! _aip_is_required_profile_link "$relative" && ! _aip_is_passthrough_link "$relative" "$profile"; then
      if _aip_is_legacy_primary_config_link "$relative" "$profile"; then
        _aip_warn "legacy primary-config link $relative is tolerated until migration; run 'aip update' to make it profile-owned"
      else
        printf 'ERROR: profile contains an unsupported symbolic link that could escape its boundary: %s/%s\n' "$name" "$relative"
        _aip_doctor_record_action remove "$name" "$relative" ''
        errors=1
      fi
    fi
  done <"$entries"
  command rm -f "$entries"
  [ "$errors" -eq 0 ]
}

_aip_primary_config_rels() {
  # Primary configs are profile-owned, portable content—not machine-local fallback.
  printf '%s\n' pi/settings.json claude/settings.json codex/config.toml opencode/opencode.json
}

_aip_materialize_primary_configs() {
  # $1 staged profile. Copies each existing source config byte-for-byte.
  local profile_path=$1 rel harness file source
  while IFS= read -r rel; do
    harness=${rel%%/*}
    file=${rel#*/}
    source=$(_aip_import_harness_root "$harness")/$file || return 1
    [ -f "$source" ] || continue
    command cp -- "$source" "$profile_path/$rel" || return 1
  done < <(_aip_primary_config_rels)
}

_aip_note_untracked_primary_configs() {
  # $1 profile name, $2 profile path. Copied primary configs require an
  # explicit review-and-add decision; checkpointing never makes it for users.
  local name=$1 profile_path=$2 rel
  while IFS= read -r rel; do
    [ -f "$profile_path/$rel" ] && [ ! -L "$profile_path/$rel" ] || continue
    printf 'aip: note: %s/%s is local and untracked; inspect it, then explicitly add it: git -C "%s" add -- %s/%s\n' "$name" "$rel" "$_AIP_PROFILE_ROOT" "$name" "$rel"
  done < <(_aip_primary_config_rels)
}

_aip_is_legacy_primary_config_link() {
  # Historical primary-config links are recognised independently of today's
  # pass-through allowlist, so update can safely retire them.
  local relative=$1 profile=$2 harness rel root expected raw canonical resolved_root
  _aip_primary_config_rels | command grep -Fxq "$relative" || return 1
  harness=${relative%%/*}; rel=${relative#*/}
  root=$(_aip_import_harness_root "$harness") || return 1
  resolved_root=$(_aip_resolve_path "$root") || resolved_root=$root
  expected=$(_aip_relative_path "$profile/$harness" "$root/$rel")
  raw=$(command readlink "$profile/$relative" 2>/dev/null) || return 1
  [ "$raw" = "$expected" ] && return 0
  canonical=$(_aip_resolve_path "$profile/$relative") || return 1
  case $canonical in "$resolved_root/$rel") return 0 ;; *) return 1 ;; esac
}

_aip_migrate_legacy_primary_config_links() (
  _aip_clear_git_routing
  local root name profile rel harness file source destination gitignore temporary tracked
  root=${_AIP_PROFILE_ROOT-}
  [ -n "$root" ] && [ -d "$root/.git" ] || return 0
  for name in $(_aip_list_profile_names); do
    profile=$(_aip_profile_path "$name")
    gitignore=$profile/.gitignore
    while IFS= read -r rel; do
      destination=$profile/$rel
      [ -L "$destination" ] || continue
      _aip_is_legacy_primary_config_link "$rel" "$profile" || continue
      harness=${rel%%/*}; file=${rel#*/}
      source=$(_aip_import_harness_root "$harness")/$file || continue
      if [ -f "$source" ]; then
        # Copy to a sibling temporary file first so a failed copy never destroys
        # the link; the rename over the link is atomic.
        temporary=$(command mktemp "$destination.XXXXXX") || { _aip_warn "could not migrate $name/$rel"; continue; }
        tracked=0
        _aip_git -C "$root" ls-files --error-unmatch -- "$name/$rel" >/dev/null 2>&1 && tracked=1
        if command cp -- "$source" "$temporary" &&
           command mv -f -- "$temporary" "$destination" &&
           _aip_gitignore_remove_passthrough_entry "$gitignore" "$rel"; then
          if [ "$tracked" -eq 1 ]; then
            if _aip_git -C "$root" rm --cached -q -- "$name/$rel"; then
              printf 'aip: removed %s/%s from Git; inspect the local replacement before explicitly adding it to share\n' "$name" "$rel"
            else
              _aip_warn "could not untrack migrated config $name/$rel"
            fi
          else
            printf 'aip: left %s/%s untracked; inspect it before explicitly adding it to share\n' "$name" "$rel"
          fi
        else
          command rm -f -- "$temporary"
          _aip_warn "could not migrate $name/$rel"
        fi
      else
        # A legacy link is normally untracked (the pass-through block ignored it),
        # so there is nothing to stage for its removal unless it was force-tracked.
        tracked=0
        _aip_git -C "$root" ls-files --error-unmatch -- "$name/$rel" >/dev/null 2>&1 && tracked=1
        if command rm -f -- "$destination" &&
           _aip_gitignore_remove_passthrough_entry "$gitignore" "$rel"; then
          if [ "$tracked" -eq 1 ] && _aip_git -C "$root" add -u -- "$name/$rel"; then
            printf 'aip: staged deletion of %s/%s (the global config is absent)\n' "$name" "$rel"
          else
            printf 'aip: removed legacy link %s/%s (the global config is absent)\n' "$name" "$rel"
          fi
        else
          _aip_warn "could not remove legacy link $name/$rel"
        fi
      fi
    done < <(_aip_primary_config_rels)
  done
)

_aip_passthrough_rels() {
  # The per-harness pass-through allowlist: machine-local configuration inputs that
  # every profile falls back to unless it defines the path itself. Names are matched
  # without a trailing slash; each maps to the same relative path under the harness
  # default root. Only these paths may ever be linked by pass-through maintenance.
  case ${1-} in
    pi) printf '%s\n' models.json auth.json themes prompts extensions npm ;;
    claude) printf '%s\n' settings.local.json .credentials.json agents commands context-mode output-styles workflows keybindings.json plugins ;;
    codex) printf '%s\n' auth.json plugins ;;
    opencode) printf '%s\n' auth.json tui.json agent command plugins ;;
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

_aip_path_is_under() {
  # $1 root, $2 candidate. Both must be absolute. Lexical only — no filesystem access.
  local root candidate
  root=$(_aip_normalize_path "$1") || return 1
  candidate=$(_aip_normalize_path "$2") || return 1
  case $candidate in
    "$root"|"$root"/*) return 0 ;;
    *) return 1 ;;
  esac
}

_aip_redact_url() {
  # Display-only: strip URL userinfo (user@ or user:pass@). scp-style git@host: is left alone.
  local url=$1
  case $url in
    *://*@*)
      printf '%s\n' "$url" | command sed -E 's#(://)[^/]*@#\1#'
      ;;
    *)
      printf '%s\n' "$url"
      ;;
  esac
}

_aip_resolve_path() {
  # Portable canonical resolution (macOS has no readlink -f): follows the final
  # symlink chain (bounded, so loops cannot hang) then normalises lexically. Broken
  # links resolve to their lexical target, which is exactly what the pass-through
  # boundary needs to accept or reject them.
  local source_path=$1 link depth=0
  case $source_path in /*) ;; *) source_path=$PWD/$source_path ;; esac
  while [ -L "$source_path" ] && [ "$depth" -lt 40 ]; do
    link=$(command readlink "$source_path") || return 1
    case $link in
      /*) source_path=$link ;;
      *) source_path=${source_path%/*}/$link ;;
    esac
    depth=$((depth + 1))
  done
  _aip_normalize_path "$source_path"
}


_aip_create_skills_tree_root() {
  printf '%s\n' "${_AIP_CREATE_SKILLS_TREE_ROOT-$PWD}"
}

_aip_create_skills_global_root() {
  printf '%s\n' "${_AIP_CREATE_SKILLS_GLOBAL_ROOT-${HOME}/.pi/agent/skills}"
}

_aip_create_skills_agents_root() {
  printf '%s\n' "${_AIP_CREATE_SKILLS_AGENTS_ROOT-${HOME}/.agents/skills}"
}

_aip_canonical_directory() (
  [ -d "$1" ] || exit 1
  builtin cd "$1" 2>/dev/null && builtin pwd -P
)

_aip_create_skill_is_within() {
  # _aip_path_is_under deliberately treats '/' as a special case here: every
  # absolute candidate is under it, whereas the ordinary prefix matcher needs a
  # non-root slash suffix.
  [ "$1" = / ] && return 0
  _aip_path_is_under "$1" "$2"
}

_aip_add_create_skill_candidate() {
  # $1 canonical allowed root, $2 candidate directory, $3 tab-separated list file.
  local root=$1 candidate=$2 entries=$3 name canonical
  [ -d "$candidate" ] && [ -f "$candidate/SKILL.md" ] || return 0
  name=${candidate##*/}
  case $name in ''|*$'\n'*|*$'\r'*|*$'\t'*) return 0 ;; esac
  canonical=$(_aip_canonical_directory "$candidate") || return 0
  _aip_create_skill_is_within "$root" "$canonical" || return 0
  printf '%s\t%s\n' "$name" "$canonical" >>"$entries"
}

_aip_list_create_skills() {
  # Prints name<TAB>canonical-source, with global skills taking precedence. Skills
  # from the current tree are recognised only at a Pi profile's pi/skills/NAME path.
  local tree global agents tree_root global_root roots global_entries tree_entries all_entries skill_root child
  tree=$(_aip_create_skills_tree_root) || return 1
  global=$(_aip_create_skills_global_root) || return 1
  agents=$(_aip_create_skills_agents_root) || return 1
  global_entries=$(command mktemp "${TMPDIR:-/tmp}/aip-create-global-skills.XXXXXX") || return 1
  tree_entries=$(command mktemp "${TMPDIR:-/tmp}/aip-create-tree-skills.XXXXXX") || { command rm -f "$global_entries"; return 1; }
  all_entries=$(command mktemp "${TMPDIR:-/tmp}/aip-create-skills.XXXXXX") || { command rm -f "$global_entries" "$tree_entries"; return 1; }
  : >|"$global_entries"
  : >|"$tree_entries"

  if global_root=$(_aip_canonical_directory "$global"); then
    while IFS= read -r child; do
      _aip_add_create_skill_candidate "$global_root" "$child" "$global_entries"
    done < <(command find -H "$global_root" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -print 2>/dev/null)
  fi

  if global_root=$(_aip_canonical_directory "$agents"); then
    while IFS= read -r child; do
      _aip_add_create_skill_candidate "$global_root" "$child" "$global_entries"
    done < <(command find -H "$global_root" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -print 2>/dev/null)
  fi

  if tree_root=$(_aip_canonical_directory "$tree"); then
    roots=$(command mktemp "${TMPDIR:-/tmp}/aip-create-skill-roots.XXXXXX") || { command rm -f "$global_entries" "$tree_entries" "$all_entries"; return 1; }
    command find -H "$tree_root" -path '*/pi/skills' \( -type d -o -type l \) -print >|"$roots" 2>/dev/null || :
    while IFS= read -r skill_root; do
      skill_root=$(_aip_canonical_directory "$skill_root") || continue
      _aip_create_skill_is_within "$tree_root" "$skill_root" || continue
      while IFS= read -r child; do
        _aip_add_create_skill_candidate "$tree_root" "$child" "$tree_entries"
      done < <(command find -H "$skill_root" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -print 2>/dev/null)
    done <"$roots"
    command rm -f "$roots"
  fi

  LC_ALL=C command sort "$global_entries" >|"$all_entries"
  LC_ALL=C command sort "$tree_entries" >>"$all_entries"
  command awk -F '\t' 'NF == 2 && !seen[$1]++ { print }' "$all_entries" | LC_ALL=C command sort
  command rm -f "$global_entries" "$tree_entries" "$all_entries"
}

_aip_render_create_skill_menu() {
  local skills name source number=1
  skills=$(_aip_list_create_skills) || return 1
  [ -n "$skills" ] || return 1
  printf '%s\n' 'Available Pi skills:'
  while IFS="$(printf '\t')" read -r name source; do
    [ -n "$name" ] || continue
    printf '%s. %s\n' "$number" "$name"
    number=$((number + 1))
  done <<EOF
$skills
EOF
}

_aip_parse_create_skill_selection() {
  # $1 menu size, $2 user input. Prints unique selected menu indices, one per line.
  local count=$1 input=$2 token selected=''
  if ! printf '%s\n' "$input" | LC_ALL=C command grep -Eq '^[0-9,[:space:]]*$'; then
    _aip_error 'invalid skill selection; enter menu numbers separated by commas or spaces'
    return 1
  fi
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    if ! [ "$token" -ge 1 ] 2>/dev/null || ! [ "$token" -le "$count" ] 2>/dev/null; then
      _aip_error 'invalid skill selection; enter menu numbers separated by commas or spaces'
      return 1
    fi
    case " $selected " in *" $token "*) continue ;; esac
    selected=${selected:+$selected }$token
    printf '%s\n' "$token"
  done <<EOF
$(printf '%s' "$input" | command tr ',[:space:]' '\n')
EOF
}

_aip_prompt_create_skill_selection() {
  # Prints selected menu indices only. Automation has no terminal stdin, so it
  # deliberately gets the existing no-skills creation behaviour without blocking.
  local skills name source count=0 input selected
  [ "${_AIP_CREATE_SKIP_SKILL_SELECTION-}" = 1 ] && return 0
  [ -t 0 ] || return 0
  skills=$(_aip_list_create_skills) || return 1
  [ -n "$skills" ] || return 0
  while IFS="$(printf '\t')" read -r name source; do
    [ -n "$name" ] && count=$((count + 1))
  done <<EOF
$skills
EOF
  _aip_render_create_skill_menu >&2 || return 1
  while :; do
    printf '%s' 'Select skills by number (comma or space separated; Enter for none): ' >&2
    if ! IFS= read -r input; then
      return 0
    fi
    selected=$(_aip_parse_create_skill_selection "$count" "$input") && {
      [ -n "$selected" ] && printf '%s\n' "$selected"
      return 0
    }
  done
}

_aip_create_skill_source_is_allowed() {
  # Prints the current canonical source only when it is still below a discovery root.
  local source=$1 canonical root
  canonical=$(_aip_canonical_directory "$source") || return 1
  [ -f "$canonical/SKILL.md" ] || return 1
  for root in "$(_aip_create_skills_global_root)" "$(_aip_create_skills_agents_root)" "$(_aip_create_skills_tree_root)"; do
    root=$(_aip_canonical_directory "$root") || continue
    if _aip_create_skill_is_within "$root" "$canonical"; then
      printf '%s\n' "$canonical"
      return 0
    fi
  done
  return 1
}

_aip_copy_selected_create_skills() {
  # $1 staged profile directory, $2 newline-separated selected menu indices.
  local profile_path=$1 selections=$2 skills source name destination links index
  skills=$(command mktemp "${TMPDIR:-/tmp}/aip-create-skills.XXXXXX") || return 1
  _aip_list_create_skills >|"$skills" || { command rm -f "$skills"; return 1; }
  while IFS= read -r index; do
    case $index in ''|*[!0-9]*) command rm -f "$skills"; return 1 ;; esac
    source=$(command awk -F '\t' -v number="$index" 'NR == number { print $2; exit }' "$skills")
    name=$(command awk -F '\t' -v number="$index" 'NR == number { print $1; exit }' "$skills")
    if [ -z "$source" ] || [ -z "$name" ]; then
      command rm -f "$skills"
      _aip_error "selected skill number is no longer available: $index"
      return 1
    fi
    source=$(_aip_create_skill_source_is_allowed "$source") || {
      command rm -f "$skills"
      _aip_error "selected skill source is no longer within an allowed root: $name"
      return 1
    }
    links=$(command find -H "$source" -type l -print -quit 2>/dev/null) || {
      command rm -f "$skills"
      return 1
    }
    if [ -n "$links" ]; then
      command rm -f "$skills"
      _aip_error "selected skill contains a symbolic link and cannot be copied safely: $name"
      return 1
    fi
    destination=$profile_path/skills/$name
    if [ -e "$destination" ] || [ -L "$destination" ]; then
      command rm -f "$skills"
      _aip_error "selected skill destination already exists: $name"
      return 1
    fi
    command cp -R "$source" "$destination" || { command rm -f "$skills"; return 1; }
  done <"$selections"
  command rm -f "$skills"
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

_aip_sync_packages() (
  # Sync a profile's pi package list (the "packages" array of pi/settings.json)
  # with the machine-wide global settings. Node performs the JSON splice so
  # unrelated lines of the settings file stay byte-identical.
  # Modes: bulk (default) copies the global array when absent and reports a diff
  # otherwise; --replace adopts the global list; --add SPEC / --remove PKG are
  # surgical. Stage-only: edits the file, no Git write.
  _aip_clear_git_routing
  local name='' mode=bulk spec='' pkg='' have_name=0
  [ "$#" -le 5 ] || { _aip_error 'usage: aip sync-packages [NAME] [--add SPEC | --remove PKG | --replace]'; return 2; }
  while [ "$#" -gt 0 ]; do
    case $1 in
      --add)
        [ "$#" -ge 2 ] || { _aip_error '--add requires a package spec'; return 2; }
        [ "$mode" = bulk ] || { _aip_error 'combine at most one of --add, --remove, --replace'; return 2; }
        mode=add; spec=$2; shift 2 ;;
      --remove)
        [ "$#" -ge 2 ] || { _aip_error '--remove requires a package name'; return 2; }
        [ "$mode" = bulk ] || { _aip_error 'combine at most one of --add, --remove, --replace'; return 2; }
        mode=remove; pkg=$2; shift 2 ;;
      --replace)
        [ "$mode" = bulk ] || { _aip_error 'combine at most one of --add, --remove, --replace'; return 2; }
        mode=replace; shift ;;
      -*) _aip_error "unknown option '$1'"; return 2 ;;
      *)
        [ "$have_name" -eq 0 ] || { _aip_error "unexpected argument '$1'"; return 2; }
        have_name=1; name=$1; shift ;;
    esac
  done
  _aip_resolve_profile "$name" || return
  name=$_AIP_RESOLVED_NAME
  command -v node >/dev/null 2>&1 || { _aip_error 'sync-packages requires Node.js on PATH'; return 1; }
  local profile_settings global_settings jsfile rc
  profile_settings=$(_aip_profile_path "$name")/pi/settings.json
  if [ -L "$profile_settings" ]; then
    _aip_error "$name/pi/settings.json is a pass-through link; give the profile its own settings file first (copy the global one), then retry"
    return 1
  fi
  [ -f "$profile_settings" ] || { _aip_error "$name has no pi/settings.json"; return 1; }
  global_settings=$(_aip_import_harness_root pi)/settings.json
  # The node script goes to a temp file, not a $(cat <<EOF) heredoc: bash 3.2
  # (macOS /bin/bash) misparses parenthesised heredoc bodies inside $( ), which
  # corrupts the whole file's parse.
  jsfile=$(command mktemp) || return
  cat > "$jsfile" <<'JS'
const fs = require("fs");
// node script: argv is [node, script, mode, profile, global, spec, pkg]
const mode = process.argv[2];
const profilePath = process.argv[3];
const globalPath = process.argv[4];
const spec = process.argv[5];
const pkg = process.argv[6];

const profileText = fs.readFileSync(profilePath, "utf8");
const globalText = fs.existsSync(globalPath) ? fs.readFileSync(globalPath, "utf8") : null;

function skipString(text, i) {
  let j = i + 1;
  while (j < text.length) {
    if (text[j] === "\\") j += 2;
    else if (text[j] === '"') return j + 1;
    j++;
  }
  return j;
}

function findPackages(text) {
  // { arrStart, arrEnd, indent } of the top-level "packages" array member, or null
  let depth = 0;
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    if (c === '"') {
      const end = skipString(text, i);
      if (depth === 1 && text.slice(i + 1, end - 1) === "packages") {
        let k = end;
        while (k < text.length && /\s/.test(text[k])) k++;
        if (text[k] === ":") {
          k++;
          while (k < text.length && /\s/.test(text[k])) k++;
          if (text[k] !== "[") {
            // a top-level "packages" member that is not an array: refuse to
            // touch the file rather than insert a duplicate member
            return { nonArray: true };
          }
          {
            let d = 0;
            let m = k;
            while (m < text.length) {
              const ch = text[m];
              if (ch === '"') m = skipString(text, m);
              else if (ch === "[") d++;
              else if (ch === "]") { d--; if (d === 0) break; }
              m++;
            }
            const lineStart = text.lastIndexOf("\n", i) + 1;
            return { arrStart: k, arrEnd: m, indent: text.slice(lineStart, i) };
          }
        }
      }
      i = end;
    } else {
      if (c === "{" || c === "[") depth++;
      else if (c === "}" || c === "]") depth--;
      i++;
    }
  }
  return null;
}

function parseEntries(text, arrStart, arrEnd) {
  const inner = text.slice(arrStart + 1, arrEnd);
  const entries = [];
  let i = 0;
  while (i < inner.length) {
    while (i < inner.length && /[\s,]/.test(inner[i])) i++;
    if (i >= inner.length) break;
    let end;
    if (inner[i] === '"') end = skipString(inner, i);
    else if (inner[i] === "{") {
      let d = 0;
      let m = i;
      while (m < inner.length) {
        const ch = inner[m];
        if (ch === '"') m = skipString(inner, m);
        else if (ch === "{") d++;
        else if (ch === "}") { d--; if (d === 0) break; }
        m++;
      }
      end = m + 1;
    } else {
      let m = i;
      while (m < inner.length && !/[\s,]/.test(inner[m])) m++;
      end = m;
    }
    entries.push(inner.slice(i, end));
    i = end;
  }
  return entries;
}

function renderArray(entries, indent) {
  if (entries.length === 0) return "[]";
  const child = indent + "  ";
  return "[\n" + entries.map((e) => child + e).join(",\n") + "\n" + indent + "]";
}

function insertMember(text, entries, indent) {
  // splice a new top-level "packages" member just before the root object's close
  let depth = 0;
  let closeIdx = -1;
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    if (c === '"') { i = skipString(text, i); continue; }
    if (c === "{") depth++;
    else if (c === "}") { depth--; if (depth === 0) { closeIdx = i; break; } }
    i++;
  }
  if (closeIdx === -1) return null;
  const pre = text.slice(0, closeIdx).replace(/\s+$/, "");
  const suffix = text.slice(closeIdx);
  const comma = pre.endsWith("{") ? "" : ",";
  return pre + comma + "\n" + indent + '"packages": ' + renderArray(entries, indent) + "\n" + suffix;
}

function entryName(entry) {
  let value;
  try { value = JSON.parse(entry); } catch (e) { return entry; }
  if (typeof value === "object" && value !== null) value = value.source ?? entry;
  if (typeof value === "string" && value.startsWith("npm:")) return value.slice(4);
  return typeof value === "string" ? value : entry;
}

const globalMember = globalText ? findPackages(globalText) : null;
if (globalMember && globalMember.nonArray) {
  console.error("the global settings' \"packages\" member is not an array; fix it by hand");
  process.exit(2);
}
const globalEntries = globalMember && !globalMember.nonArray ? parseEntries(globalText, globalMember.arrStart, globalMember.arrEnd) : null;
const profileMember = findPackages(profileText);
if (profileMember && profileMember.nonArray) {
  console.error("the profile settings' \"packages\" member is not an array; fix it by hand");
  process.exit(2);
}
const profileEntries = profileMember && !profileMember.nonArray ? parseEntries(profileText, profileMember.arrStart, profileMember.arrEnd) : null;

function spliceIntoProfile(entries) {
  if (profileMember) {
    return profileText.slice(0, profileMember.arrStart) + renderArray(entries, profileMember.indent) + profileText.slice(profileMember.arrEnd + 1);
  }
  const inserted = insertMember(profileText, entries, "  ");
  if (inserted === null) {
    console.error("could not locate the end of the settings object");
    process.exit(2);
  }
  return inserted;
}

function writeProfile(newText) { fs.writeFileSync(profilePath, newText); }

if (mode === "bulk" || mode === "replace") {
  if (!globalEntries) {
    if (mode === "replace") { console.error("the global pi settings define no packages to replace with"); process.exit(2); }
    console.log("global pi settings define no packages; nothing to copy");
    process.exit(0);
  }
  if (profileEntries === null) {
    writeProfile(spliceIntoProfile(globalEntries));
    console.log(`copied ${globalEntries.length} package(s) from global settings`);
    process.exit(0);
  }
  if (profileEntries.length === globalEntries.length && profileEntries.every((e, i) => e === globalEntries[i])) {
    console.log("package list already matches global settings");
    process.exit(0);
  }
  console.log("package list differs from global settings:");
  for (const e of profileEntries.filter((e) => !globalEntries.includes(e))) console.log(`  - ${e} (profile only)`);
  for (const e of globalEntries.filter((e) => !profileEntries.includes(e))) console.log(`  + ${e} (global only)`);
  if (mode === "replace") {
    writeProfile(spliceIntoProfile(globalEntries));
    console.log(`replaced the profile package list with the global ${globalEntries.length} package(s)`);
    process.exit(0);
  }
  console.log("re-run with --replace to adopt the global list");
  process.exit(1);
}

if (mode === "add") {
  // a bare spec (npm:foo) is JSON-stringified; a quoted or object entry is kept verbatim
  let entry = spec;
  try {
    const parsed = JSON.parse(spec);
    if (typeof parsed === "string") entry = JSON.stringify(parsed);
  } catch (e) {
    entry = JSON.stringify(spec);
  }
  if (profileEntries === null) {
    writeProfile(spliceIntoProfile([entry]));
    console.log(`added ${entry}`);
    process.exit(0);
  }
  if (profileEntries.includes(entry)) { console.log(`${entry} is already present`); process.exit(0); }
  writeProfile(spliceIntoProfile([...profileEntries, entry]));
  console.log(`added ${entry}`);
  process.exit(0);
}

if (mode === "remove") {
  if (profileEntries === null) { console.log("profile has no packages; nothing to remove"); process.exit(0); }
  const idx = profileEntries.findIndex((e) => e === pkg || entryName(e) === pkg);
  if (idx === -1) { console.log(`${pkg} is not in the profile package list`); process.exit(0); }
  const removed = profileEntries[idx];
  writeProfile(spliceIntoProfile(profileEntries.filter((_, i) => i !== idx)));
  console.log(`removed ${removed}`);
  process.exit(0);
}

console.error(`unknown mode ${mode}`);
process.exit(2);
JS
  node "$jsfile" "$mode" "$profile_settings" "$global_settings" "$spec" "$pkg"
  rc=$?
  command rm -f "$jsfile"
  return $rc
)

_aip_is_trivial_json_file() {
  # $1 file: true when it holds only an empty value (no bytes, or an empty JSON
  # object/array up to whitespace) — a stub that never carries user content.
  local content
  content=$(command cat -- "$1" 2>/dev/null) || return 1
  content=${content//[[:space:]]/}
  [ "$content" = "" ] || [ "$content" = "{}" ] || [ "$content" = "[]" ]
}

_aip_passthrough() {
  # $1 harness, $2 profile name. Ensures the profile's pass-through links for one
  # harness match the machine-local default root: creates missing links (never
  # overwriting a real path with content, except trivial stub files which are
  # repaired in place; skipping paths already tracked in Git), removes
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
  #    directory with content shadows the link; a path already tracked in Git is
  #    exempt (the profile owns it and keeps syncing it). A trivial real file (an
  #    empty stub) is replaced by the link so it never shadows the machine-wide
  #    default for good.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    dest=$profile_path/$harness/$rel
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      if [ ! -L "$dest" ] && [ -f "$dest" ] && _aip_is_trivial_json_file "$dest" &&
         [ -e "$root/$rel" ] &&
         ! _aip_git -C "$_AIP_PROFILE_ROOT" ls-files --error-unmatch -- "$name/$harness/$rel" >/dev/null 2>&1; then
        if command rm -f "$dest" 2>/dev/null; then
          expected=$(_aip_relative_path "$profile_path/$harness" "$root/$rel")
          if command ln -s "$expected" "$dest" 2>/dev/null; then
            _aip_warn "replaced trivial $name/$harness/$rel with its pass-through link (it held only an empty value)"
          else
            _aip_warn "could not re-create pass-through link $name/$harness/$rel after removing its trivial file"
          fi
        else
          _aip_warn "could not remove trivial file $name/$harness/$rel; kept it"
        fi
      fi
      continue  # remaining existing paths shadow the link (profile precedence)
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
  local profile_path=$1
  command mkdir -p "$profile_path/skills" "$profile_path/claude" "$profile_path/codex" "$profile_path/pi" "$profile_path/opencode" || return
  command chmod 700 "$profile_path" || return
  : >"$profile_path/skills/.gitkeep" || return
  printf '%s\n' '# Common profile instructions' >"$profile_path/AGENTS.md" || return
  printf '%s\n' '@../AGENTS.md' '' '# Claude Code instructions' >"$profile_path/claude/CLAUDE.md" || return
  printf '%s\n' '# Codex instructions' >"$profile_path/codex/instructions.md" || return
  printf '%s\n' '# Pi instructions' >"$profile_path/pi/APPEND_SYSTEM.md" || return
  _aip_materialize_primary_configs "$profile_path" || return
  printf '%s\n' \
    '# aip-managed credential and runtime exclusions' \
    '.env' '.env.*' '!.env.example' '*.pem' '*.key' '*.p12' '*.pfx' \
    '.netrc' '.npmrc' '.pypirc' 'id_rsa' 'id_dsa' 'id_ecdsa' 'id_ed25519' 'node_modules/' \
    '**/.credentials.json' '**/auth.json' \
    'claude/.credentials.json' 'claude/history.jsonl' 'claude/projects/' 'claude/session-env/' 'claude/shell-snapshots/' 'claude/statsig/' 'claude/todos/' 'claude/debug/' 'claude/cache/' 'claude/logs/' 'claude/file-history/' \
    'codex/auth.json' 'codex/history.jsonl' 'codex/sessions/' 'codex/archived_sessions/' 'codex/log/' 'codex/logs/' 'codex/cache/' 'codex/*.db' 'codex/*.db-*' 'codex/*.sqlite' 'codex/*.sqlite-*' \
    'pi/auth.json' 'pi/sessions/' 'pi/logs/' 'pi/cache/' 'pi/models-store.json' \
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
  local name=${1-} destination stage temporary selection_file
  [ -n "$name" ] || {
    _aip_error 'usage: aip create NAME'
    return 2
  }
  shift
  [ "$#" -eq 0 ] || {
    _aip_error 'usage: aip create NAME'
    return 2
  }
  _aip_validate_name "$name" || {
    _aip_error "invalid profile name '$name'"
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
     ! _aip_write_profile_files "$temporary" ||
     ! selection_file=$(command mktemp "$stage/.aip-create-selection.XXXXXX") ||
     ! _aip_prompt_create_skill_selection >"$selection_file" ||
     ! _aip_copy_selected_create_skills "$temporary" "$selection_file" ||
     ! command rm -f "$selection_file" ||
     ! _aip_publish_profile_directory "$temporary" "$destination"; then
    command rm -rf "$stage"
    _aip_error "could not create profile '$name'"
    return 1
  fi
  command rmdir "$stage" || return
  _aip_passthrough_profile "$name"
  # Add only the profile's owned paths, never the whole directory: pass-through
  # links exist on disk at this point (machine-local, untracked by design) and a
  # broad add would track any that reconciliation failed to ignore.
  _aip_git -C "$_AIP_PROFILE_ROOT" add \
    .gitignore \
    "$name/.gitignore" "$name/AGENTS.md" "$name/skills" \
    "$name/claude/CLAUDE.md" "$name/claude/skills" "$name/codex/AGENTS.md" "$name/codex/instructions.md" \
    "$name/codex/skills" "$name/pi/AGENTS.md" "$name/pi/APPEND_SYSTEM.md" "$name/pi/skills" \
    "$name/opencode/AGENTS.md" "$name/opencode/skills" || {
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
  _aip_note_untracked_primary_configs "$name" "$destination"
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
  # A broad add must not track pass-through links (machine-local, untracked by
  # design); unstage any that reconciliation failed to ignore.
  local clone_harness clone_rel clone_dest
  for clone_harness in pi claude codex opencode; do
    while IFS= read -r clone_rel; do
      [ -n "$clone_rel" ] || continue
      clone_dest="$target_path/$clone_harness/$clone_rel"
      if [ -L "$clone_dest" ] && _aip_is_passthrough_link "$clone_harness/$clone_rel" "$target_path" &&
         _aip_git -C "$_AIP_PROFILE_ROOT" ls-files --error-unmatch -- "$target_name/$clone_harness/$clone_rel" >/dev/null 2>&1; then
        _aip_git -C "$_AIP_PROFILE_ROOT" rm -q --cached -- "$target_name/$clone_harness/$clone_rel" || {
          _aip_error "could not commit clone of profile '$source_name'; check Git identity and hooks"
          return 1
        }
      fi
    done < <(_aip_passthrough_rels "$clone_harness")
  done
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
    _aip_delete_confirm_accepts "$answer" || { _aip_error 'deletion cancelled'; return 1; }
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
  # Reports pass-through links and warns (never fails) on broken ones, plus a
  # shadowing real pi/npm dir and untracked portable primary configs.
  local profile_path=$1 name=$2 harness root rel dest pi_root npm_dir config
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
  pi_root=$(_aip_import_harness_root pi) || return 0
  if [ -d "$pi_root/npm" ]; then
    npm_dir=$profile_path/pi/npm
    if [ -d "$npm_dir" ] && [ ! -L "$npm_dir" ]; then
      printf 'WARN: %s/pi/npm is a local directory shadowing the machine-wide pi npm dir; inspect it, then remove it so the pass-through link can form (pi re-installs missing packages on next launch)\n' "$name"
    fi
  fi
  while IFS= read -r rel; do
    config=$profile_path/$rel
    if [ -f "$config" ] && [ ! -L "$config" ] &&
       ! _aip_git -C "$_AIP_PROFILE_ROOT" ls-files --error-unmatch -- "$name/$rel" >/dev/null 2>&1; then
      printf 'WARN: %s/%s is not shared (untracked); inspect it, then explicitly add it: git -C "%s" add -- %s/%s\n' "$name" "$rel" "$_AIP_PROFILE_ROOT" "$name" "$rel"
    fi
  done < <(_aip_primary_config_rels)
}

_aip_doctor_profile_layout() {
  local profile_path=$1 name=$2 pair link expected directory errors=0
  for directory in skills claude codex pi opencode; do
    if [ ! -d "$profile_path/$directory" ] || [ -L "$profile_path/$directory" ]; then
      printf 'ERROR: required directory is missing or linked: %s/%s\n' "$name" "$directory"
      errors=1
    fi
  done
  for pair in 'claude/skills:../skills' 'codex/AGENTS.md:../AGENTS.md' 'codex/skills:../skills' 'pi/AGENTS.md:../AGENTS.md' 'pi/skills:../skills' 'opencode/AGENTS.md:../AGENTS.md' 'opencode/skills:../skills'; do
    link=${pair%%:*}
    expected=${pair#*:}
    if [ ! -L "$profile_path/$link" ] || [ "$(command readlink "$profile_path/$link" 2>/dev/null)" != "$expected" ]; then
      printf 'ERROR: %s/%s should link to %s\n' "$name" "$link" "$expected"
      printf "FIX: ln -sfn '%s' '%s/%s'\n" "$expected" "$profile_path" "$link"
      if [ ! -e "$profile_path/$link" ] || [ -L "$profile_path/$link" ]; then
        _aip_doctor_record_action required "$name" "$link" "$expected"
      fi
      errors=1
    fi
  done
  _aip_doctor_check_live_profile_links "$profile_path" "$name" || errors=1
  for link in .gitignore AGENTS.md skills/.gitkeep claude/CLAUDE.md codex/instructions.md pi/APPEND_SYSTEM.md; do
    if [ ! -f "$profile_path/$link" ] || [ -L "$profile_path/$link" ]; then
      printf 'ERROR: required file is missing or linked: %s/%s\n' "$name" "$link"
      errors=1
    fi
  done
  [ "$errors" -eq 0 ] || return 1
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
  _AIP_DOCTOR_ACTIONS=$(command mktemp "${TMPDIR:-/tmp}/aip-doctor-actions.XXXXXX") || return 1
  trap 'command rm -f "${_AIP_DOCTOR_ACTIONS-}"' EXIT
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

  for name in $(_aip_list_doctor_profile_names) "$_AIP_RESOLVED_NAME"; do
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
    if ! _aip_doctor_check_tracked_links "$root"; then
      printf 'ERROR: tracked profile link validation failed; see the diagnostic above\n'
      errors=1
    fi
    if _aip_has_unfinished_git_operation "$root" ||
       [ -n "$(_aip_git -C "$root" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
      printf "ERROR: Git conflict or unfinished operation; run 'git -C \"%s\" status', resolve files, then use 'git rebase --continue' or 'git rebase --abort'\n" "$root"
      errors=1
    fi
  fi
  if [ -s "$_AIP_DOCTOR_ACTIONS" ]; then
    if [ -t 0 ] || [ "${_AIP_DOCTOR_FORCE_INTERACTIVE-}" = 1 ]; then
      while :; do
        printf 'Repair these link issues? [Y/n] '
        IFS= read -r answer || answer=n
        case $answer in
          ''|y|Y|yes|YES|Yes)
            if _aip_doctor_apply_actions "$root" "$_AIP_DOCTOR_ACTIONS"; then
              printf 'Repaired link issues; changes are staged for the next normal sync.\n'
              _aip_doctor "$@"
              return
            else
              errors=1
            fi
            break
            ;;
          n|N|no|NO|No) printf 'Link repair declined.\n'; break ;;
          *) printf 'Please enter y/yes or n/no.\n' ;;
        esac
      done
    else
      printf 'ERROR: link issues need repair; rerun aip doctor from a terminal to confirm.\n'
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
  local profile_path name tags default_name='' project_name='' found=0 entries
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
    { [ -e "$profile_path/.gitignore" ] || [ -L "$profile_path/.gitignore" ]; } || continue
    tags=
    [ "${AIP_PROFILE-}" = "$name" ] && tags="$tags [session]"
    [ "$project_name" = "$name" ] && tags="$tags [project]"
    [ "$default_name" = "$name" ] && tags="$tags [default]"
    printf '%s%s\n' "$name" "$tags"
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
  local profile_path harness availability
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
  printf '🐵 %s\n' "$_AIP_RESOLVED_NAME"
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
    [ "${1-}" = --version ] || [ "${1-}" = -v ] ||
    [ "${1-}" = skills ] ||
    [ "${1-}" = create ] || [ "${1-}" = clone ] || [ "${1-}" = default ] ||
    [ "${1-}" = delete ] || [ "${1-}" = doctor ] || [ "${1-}" = list ] ||
    [ "${1-}" = local ] || [ "${1-}" = manage ] || [ "${1-}" = remote ] || [ "${1-}" = uninstall ] ||
    [ "${1-}" = import ] || [ "${1-}" = run ] ||
    [ "${1-}" = sync ] || [ "${1-}" = sync-packages ] || [ "${1-}" = use ] || [ "${1-}" = update ] ||
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
    .credentials.json|*/.credentials.json|auth.json|*/auth.json) return 0 ;;
    claude/.credentials.json|claude/history.jsonl|claude/projects|claude/projects/*|claude/session-env|claude/session-env/*|claude/shell-snapshots|claude/shell-snapshots/*|claude/statsig|claude/statsig/*|claude/todos|claude/todos/*|claude/debug|claude/debug/*|claude/cache|claude/cache/*|claude/logs|claude/logs/*|claude/file-history|claude/file-history/*) return 0 ;;
    codex/auth.json|codex/history.jsonl|codex/sessions|codex/sessions/*|codex/archived_sessions|codex/archived_sessions/*|codex/log|codex/log/*|codex/logs|codex/logs/*|codex/cache|codex/cache/*|codex/*.db|codex/*.db-*|codex/*.sqlite|codex/*.sqlite-*) return 0 ;;
    pi/auth.json|pi/sessions|pi/sessions/*|pi/logs|pi/logs/*|pi/cache|pi/cache/*|pi/models-store.json) return 0 ;;
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
  local profile_path=$1 pair link expected file directory first_line
  { [ -d "$profile_path" ] && [ ! -L "$profile_path" ]; } || {
    _aip_error 'profile path is missing or linked'
    return 1
  }
  for directory in skills claude codex pi opencode; do
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
  for file in .gitignore AGENTS.md skills/.gitkeep claude/CLAUDE.md codex/instructions.md pi/APPEND_SYSTEM.md; do
    { [ -f "$profile_path/$file" ] && [ ! -L "$profile_path/$file" ]; } || {
      _aip_error "required profile file or link is missing or invalid: $file"
      return 1
    }
  done
  for file in .gitignore AGENTS.md skills/.gitkeep claude/CLAUDE.md codex/instructions.md pi/APPEND_SYSTEM.md; do
    _aip_validate_utf8_text_file "$profile_path/$file" || {
      _aip_error "required profile text is not valid NUL-free UTF-8: $file"
      return 1
    }
  done
  [ ! -s "$profile_path/skills/.gitkeep" ] || {
    _aip_error 'skills/.gitkeep placeholder must be empty'
    return 1
  }
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
      */.gitignore) printf '%s\n' "${relative%%/*}" ;;
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
  local root=$1 tree=$2 relative rel pair link expected entry mode target file first_line text_temp forbidden=0 profiles p
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
    case $relative in */.gitignore) printf '%s\n' "${relative%%/*}" >>"$profiles" ;; esac
  done <"$_AIP_TEMP_PATHS"
  if command grep -q '^160000 ' "$_AIP_TEMP_PATHS"; then
    command rm -f "$profiles"
    command rm -f "$_AIP_TEMP_PATHS"
    _AIP_TEMP_PATHS=
    _aip_error 'remote profile contains an unsupported Git submodule'
    return 1
  fi
  # Marker-free, like the local tracked-link check: a remote 120000 entry is
  # accepted only when it is a profile-prefixed required link whose stored
  # target is exactly the target aip creates.
  # Cleanup unlinks the name; the loop keeps its already-open descriptor.
  # shellcheck disable=SC2094
  while IFS= read -r entry; do
    mode=${entry%% *}
    [ "$mode" = 120000 ] || continue
    relative=${entry#*$'\t'}
    if ! expected=$(_aip_required_link_target "$relative"); then
      command rm -f "$profiles"
      command rm -f "$_AIP_TEMP_PATHS"
      _AIP_TEMP_PATHS=
      _aip_error "remote profile contains an unsupported symbolic link: $relative"
      return 1
    fi
    if ! target=$(_aip_git -C "$root" show "$tree:$relative" 2>/dev/null); then
      command rm -f "$profiles"
      command rm -f "$_AIP_TEMP_PATHS"
      _AIP_TEMP_PATHS=
      _aip_error "could not read the stored target of remote link: $relative"
      return 1
    fi
    if [ "$target" != "$expected" ]; then
      command rm -f "$profiles"
      command rm -f "$_AIP_TEMP_PATHS"
      _AIP_TEMP_PATHS=
      _aip_error "remote profile link has an unexpected target: $relative"
      return 1
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
    for file in .gitignore AGENTS.md skills/.gitkeep claude/CLAUDE.md codex/instructions.md pi/APPEND_SYSTEM.md; do
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
    for file in .gitignore AGENTS.md skills/.gitkeep claude/CLAUDE.md codex/instructions.md pi/APPEND_SYSTEM.md; do
      if ! _aip_git -C "$root" show "$tree:$p/$file" >|"$text_temp" 2>/dev/null || ! _aip_validate_utf8_text_file "$text_temp"; then
        command rm -f "$text_temp" "$profiles"
        _aip_error "remote required profile text is not valid NUL-free UTF-8: $p/$file"
        return 1
      fi
    done
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
  # Every tracked symbolic link must be one of aip's fixed required profile links
  # (profile prefix plus one of seven paths) whose stored target is exactly the
  # target aip creates. The rule is marker-free on purpose: it must hold even when
  # a profile's tracked .gitignore is missing (a half-present profile must never
  # brick every launch), and the target check closes the hole where a required
  # link name with a hostile target passed on its name alone.
  local root=$1 entries record mode rest hash relative expected target
  entries=$(command mktemp "${TMPDIR:-/tmp}/aip-index.XXXXXX") || return
  _aip_git -C "$root" ls-files --stage -z >|"$entries" || { command rm -f "$entries"; return 1; }
  # Cleanup unlinks the name; the loop keeps its already-open descriptor.
  # shellcheck disable=SC2094
  while IFS= read -r -d '' record; do
    mode=${record%% *}
    [ "$mode" = 120000 ] || continue
    relative=${record#*$'\t'}
    if ! expected=$(_aip_required_link_target "$relative"); then
      command rm -f "$entries"
      _aip_error "tracked profile contains an unsupported symbolic link: $relative"
      return 1
    fi
    rest=${record#* }
    hash=${rest%% *}
    if ! target=$(_aip_git -C "$root" cat-file blob "$hash" 2>/dev/null); then
      command rm -f "$entries"
      _aip_error "could not read the stored target of tracked link: $relative"
      return 1
    fi
    if [ "$target" != "$expected" ]; then
      command rm -f "$entries"
      _aip_error "tracked profile link has an unexpected target: $relative"
      return 1
    fi
  done <"$entries"
  command rm -f "$entries"
}

_aip_doctor_check_tracked_links() {
  # Doctor reports every invalid tracked link; sync keeps the fail-fast checker above.
  local root=$1 entries record mode rest hash relative expected target errors=0
  entries=$(command mktemp "${TMPDIR:-/tmp}/aip-index.XXXXXX") || return 1
  _aip_git -C "$root" ls-files --stage -z >|"$entries" || { command rm -f "$entries"; return 1; }
  while IFS= read -r -d '' record; do
    mode=${record%% *}
    [ "$mode" = 120000 ] || continue
    relative=${record#*$'\t'}
    if ! expected=$(_aip_required_link_target "$relative"); then
      printf 'ERROR: tracked profile contains an unsupported symbolic link: %s\n' "$relative"
      case $relative in
        */*)
          if _aip_is_passthrough_link "${relative#*/}" "$root/${relative%%/*}"; then
            _aip_doctor_record_action untrack "${relative%%/*}" "${relative#*/}" ''
          else
            _aip_doctor_record_action remove "${relative%%/*}" "${relative#*/}" ''
          fi
          ;;
      esac
      errors=1
      continue
    fi
    rest=${record#* }
    hash=${rest%% *}
    if ! target=$(_aip_git -C "$root" cat-file blob "$hash" 2>/dev/null); then
      printf 'ERROR: could not read the stored target of tracked link: %s\n' "$relative"
      errors=1
      continue
    fi
    if [ "$target" != "$expected" ]; then
      printf 'ERROR: tracked profile link has an unexpected target: %s\n' "$relative"
      _aip_doctor_record_action required "${relative%%/*}" "${relative#*/}" "$expected"
      errors=1
    fi
  done <"$entries"
  command rm -f "$entries"
  [ "$errors" -eq 0 ]
}

_aip_doctor_record_action() {
  # $1 kind, $2 profile name, $3 profile-relative path, $4 expected target.
  local kind=$1 name=$2 rel=$3 target=$4 line
  [ -n "${_AIP_DOCTOR_ACTIONS-}" ] || return 0
  line=$(printf '%s\t%s\t%s\t%s' "$kind" "$name" "$rel" "$target")
  command grep -Fqx "$line" "$_AIP_DOCTOR_ACTIONS" 2>/dev/null || printf '%s\n' "$line" >>"$_AIP_DOCTOR_ACTIONS"
}

_aip_doctor_restore_passthrough_ignore() {
  local profile=$1 rel=$2 current entries entry found=0
  current=$(_aip_gitignore_passthrough_entries "$profile/.gitignore")
  entries=$(command mktemp "${TMPDIR:-/tmp}/aip-passthrough-entries.XXXXXX") || return 1
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ "$entry" = "$rel" ] && found=1
    printf '%s\n' "$entry" >>"$entries"
  done <<EOF
$current
EOF
  [ "$found" -eq 1 ] || printf '%s\n' "$rel" >>"$entries"
  LC_ALL=C command sort -u "$entries" >"$entries.sorted" && command mv "$entries.sorted" "$entries" || { command rm -f "$entries" "$entries.sorted"; return 1; }
  _aip_gitignore_set_passthrough_block "$profile/.gitignore" "$entries" || { command rm -f "$entries"; return 1; }
  command rm -f "$entries"
}

_aip_doctor_has_action() {
  # $1 actions file, $2 kind, $3 profile, $4 profile-relative path.
  local actions=$1 wanted_kind=$2 wanted_name=$3 wanted_rel=$4 kind name rel target
  while IFS="$(printf '\t')" read -r kind name rel target; do
    [ "$kind" = "$wanted_kind" ] && [ "$name" = "$wanted_name" ] && [ "$rel" = "$wanted_rel" ] && return 0
  done <"$actions"
  return 1
}

_aip_doctor_apply_actions() {
  local root=$1 actions=$2 kind name rel target profile path errors=0 canonical parent parent_rel desired
  _aip_git -C "$root" status --porcelain >/dev/null 2>&1 || {
    printf 'ERROR: refusing doctor repair because the profiles repository is unreadable\n'
    return 1
  }

  # Validate the complete plan before applying its first mutation.
  while IFS="$(printf '\t')" read -r kind name rel target; do
    [ -n "$kind" ] || continue
    profile=$root/$name
    path=$profile/$rel
    case $kind in required|untrack|remove) ;; *) printf 'ERROR: refusing invalid doctor repair action\n'; errors=1; continue ;; esac
    if ! _aip_validate_name "$name" >/dev/null 2>&1 || [ -z "$rel" ] ||
       [ ! -d "$profile" ] || [ -L "$profile" ] ||
       ! _aip_path_is_under "$root" "$profile" || ! _aip_path_is_under "$profile" "$path"; then
      printf 'ERROR: refusing doctor repair outside a profile: %s/%s\n' "$name" "$rel"
      errors=1
      continue
    fi
    case $kind in
      required)
        if [ -e "$path" ] && [ ! -L "$path" ]; then
          printf 'ERROR: doctor will not replace ordinary path: %s/%s\n' "$name" "$rel"
          errors=1
        fi
        canonical=$(_aip_required_link_target "$name/$rel" 2>/dev/null) || canonical=
        if [ -z "$canonical" ] || [ "$target" != "$canonical" ]; then
          printf 'ERROR: refusing non-canonical required link repair: %s/%s\n' "$name" "$rel"
          errors=1
        fi
        parent=${path%/*}
        while [ "$parent" != "$profile" ] && _aip_path_is_under "$profile" "$parent"; do
          if [ -L "$parent" ]; then
            parent_rel=${parent#"$profile"/}
            _aip_doctor_has_action "$actions" remove "$name" "$parent_rel" || {
              printf 'ERROR: refusing required link repair through an unsafe parent: %s/%s\n' "$name" "$parent_rel"
              errors=1
            }
            break
          fi
          if [ -e "$parent" ] && [ ! -d "$parent" ]; then
            printf 'ERROR: refusing required link repair through an unsafe parent: %s/%s\n' "$name" "${parent#"$profile"/}"
            errors=1
            break
          fi
          parent=${parent%/*}
        done
        ;;
      untrack)
        if [ ! -L "$path" ] || ! _aip_is_passthrough_link "$rel" "$profile"; then
          printf 'ERROR: refusing to untrack an invalid pass-through link: %s/%s\n' "$name" "$rel"
          errors=1
        fi
        ;;
    esac
  done <"$actions"
  [ "$errors" -eq 0 ] || return 1

  # Remove unsafe ancestors first, then preserve pass-throughs, then rebuild
  # required links. This lets malformed profiles converge without traversing a
  # link target.
  for desired in remove untrack required; do
    while IFS="$(printf '\t')" read -r kind name rel target; do
      [ "$kind" = "$desired" ] || continue
      profile=$root/$name
      path=$profile/$rel
      case $kind in
        remove)
          if [ -L "$path" ]; then command rm -f "$path" || { printf 'ERROR: could not remove unsupported link: %s/%s\n' "$name" "$rel"; errors=1; continue; }; fi
          _aip_git -C "$root" update-index --force-remove -- "$name/$rel" || { printf 'ERROR: could not stage removed link: %s/%s\n' "$name" "$rel"; errors=1; }
          ;;
        untrack)
          _aip_doctor_restore_passthrough_ignore "$profile" "$rel" &&
            _aip_git -C "$root" rm --cached -q -- "$name/$rel" &&
            _aip_git -C "$root" add -- "$name/.gitignore" || { printf 'ERROR: could not untrack pass-through link: %s/%s\n' "$name" "$rel"; errors=1; }
          ;;
        required)
          command mkdir -p "${path%/*}" && command rm -f "$path" && command ln -s "$target" "$path" &&
            _aip_git -C "$root" add -- "$name/$rel" || { printf 'ERROR: could not restore required link: %s/%s\n' "$name" "$rel"; errors=1; }
          ;;
      esac
    done <"$actions"
    [ "$errors" -eq 0 ] || return 1
  done
  [ "$errors" -eq 0 ]
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
    { [ -d "$profile_path" ] && { [ -e "$profile_path/.gitignore" ] || [ -L "$profile_path/.gitignore" ]; }; } || continue
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
      "$name/.gitignore" "$name/AGENTS.md" "$name/skills" \
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
  if _aip_has_disallowed_control "$printable"; then
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

_aip_install_pi_status_extension() {
  # Pi discovers extensions from its normal machine-local extensions directory.
  # Install aip's small status extension there so the wrapper never has to add
  # command-line arguments before (or after) the user's arguments. This keeps
  # every Pi subcommand and option intact while retaining the existing
  # pass-through link for profiles that use the machine-local extension store.
  local source=$_AIP_STATUS_EXTENSION root target temporary
  [ -f "$source" ] || {
    _aip_warn "bundled Pi status extension was not found: $source"
    return 0
  }
  root=$(_aip_import_harness_root pi) || return 0
  if [ ! -d "$root/extensions" ] && ! command mkdir -p -- "$root/extensions" 2>/dev/null; then
    _aip_warn "could not create Pi's machine-local extension directory: $root/extensions"
    return 0
  fi
  target=$root/extensions/aip-status.ts
  if [ -L "$target" ]; then
    _aip_warn "Pi's machine-local status extension path is a symbolic link; leaving it untouched: $target"
    return 0
  fi
  if [ -e "$target" ] && [ ! -f "$target" ]; then
    _aip_warn "Pi's machine-local status extension path is not a regular file; leaving it untouched: $target"
    return 0
  fi
  if [ -e "$target" ] && ! command cmp -s -- "$source" "$target"; then
    _aip_warn "Pi's machine-local status extension already exists and differs; leaving it untouched: $target"
    return 0
  fi
  [ -f "$target" ] && return 0
  temporary=$(command mktemp "$root/extensions/.aip-status.ts.XXXXXX") || {
    _aip_warn "could not stage Pi's machine-local status extension: $target"
    return 0
  }
  if command cp -- "$source" "$temporary" && command mv -f -- "$temporary" "$target"; then
    :
  else
    command rm -f -- "$temporary"
    _aip_warn "could not install Pi's machine-local status extension: $target"
  fi
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
  if [ "$harness" = pi ]; then
    _aip_install_pi_status_extension
  fi
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
      AIP_ACTIVE_PROFILE=$_AIP_RESOLVED_NAME
      export PI_CODING_AGENT_DIR AIP_ACTIVE_PROFILE
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

_aip_manage() (
  local harness=${1-}
  [ -n "$harness" ] || { _aip_error 'usage: aip manage HARNESS [ARGS...]'; return 2; }
  _aip_is_harness "$harness" || {
    _aip_error "unknown harness '$harness'; expected claude, codex, pi, or opencode"
    return 2
  }
  shift
  if [ ! -d "$(_aip_profile_path aip)" ]; then
    _aip_error "the 'aip' profile does not exist; run 'aip create aip' first (the aip installer creates it)"
    return 1
  fi
  AIP_PROFILE=aip
  export AIP_PROFILE
  _aip_run_harness 0 '' "$harness" "$@"
)

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
  _aip_error 'usage: aip import HARNESS FILE... --profile NAME[,NAME...] | --all-profiles [--force] [--skip-existing] [--dry-run]'
}

_aip_import_blocked_by_passthrough_dir() {
  # $1 dest, $2 profile_path, $3 harness, $4 rel. Returns 0 when a prefix of dest
  # (not dest itself) is a pass-through directory link. Managed skills/AGENTS.md
  # links are not pass-through and are left alone.
  local dest=$1 profile_path=$2 harness=$3 rel=$4
  local remaining=$rel prefix='' part candidate
  remaining=$rel
  while :; do
    case $remaining in
      */*) part=${remaining%%/*}; remaining=${remaining#*/} ;;
      *) break ;;
    esac
    if [ -n "$prefix" ]; then prefix=$prefix/$part; else prefix=$part; fi
    candidate=$profile_path/$harness/$prefix
    if [ -L "$candidate" ] && [ -d "$candidate" ]; then
      _aip_import_is_managed_link "$candidate" && continue
      if _aip_is_passthrough_link "$harness/$prefix" "$profile_path"; then
        return 0
      fi
    fi
  done
  return 1
}

_aip_import_validate_rel() {
  local rel=${1-}
  [ -n "$rel" ] || return 1
  case $rel in
    *\\*) return 1 ;;
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
      if ! _aip_path_is_under "$profile_path" "$dest"; then
        _aip_error "invalid file path: $rel"
        return 1
      fi
      if _aip_import_blocked_by_passthrough_dir "$dest" "$profile_path" "$harness" "$rel"; then
        _aip_error "refusing to import through a pass-through directory: $name/$rel"
        return 1
      fi
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
  [ -s "$filelist" ] || {
    _aip_error 'no files given'
    _aip_import_usage
    return 2
  }
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
    _aip_list_profile_names | command grep -vx aip >|"$profilesfile" || :
    if [ ! -s "$profilesfile" ]; then
      if [ -n "$(_aip_list_profile_names)" ]; then
        _aip_error 'no user profiles found; --all-profiles skips the aip management profile'
        return 1
      fi
      _aip_error 'no profiles selected; nothing to do'
      return 1
    fi
  else
    _aip_import_write_profiles "$profiles_opt" "$profilesfile" || return
    [ -s "$profilesfile" ] || { _aip_error 'no profiles selected; nothing to do'; return 1; }
  fi
  _aip_import_run_copy "$harness" "$source_root" "$dry_run" "$filelist" "$profilesfile" "$force" "$skip_existing" || return
  [ "$dry_run" -eq 1 ] || _aip_import_warn_tracked "$harness" "$filelist" "$profilesfile"
  return 0
)

_aip_skills_usage() {
  _aip_error 'usage: aip skills add|update|remove …'
}

_aip_skills() {
  local sub=${1-}
  [ "$#" -gt 0 ] && shift
  case $sub in
    add) _aip_add "$@" ;;
    update) _aip_skills_update "$@" ;;
    remove) _aip_skills_remove "$@" ;;
    *) _aip_skills_usage; return 2 ;;
  esac
}

_aip_write_skill_source() {
  # $1 dest skill dir, $2 original source token, $3 clone URL, $4 in-repo path (may be empty).
  local dest=$1
  {
    printf 'source=%s\n' "$2"
    printf 'url=%s\n' "$3"
    printf 'path=%s\n' "$4"
  } >|"$dest/.aip-source" || {
    _aip_error "could not write provenance for ${dest##*/}"
    return 1
  }
}

_aip_read_skill_source() {
  # $1 dest skill dir. Sets _AIP_SKILL_SOURCE, _AIP_SKILL_URL, _AIP_SKILL_PATH.
  local file=$1/.aip-source source_line url_line path_line lines
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  lines=$(LC_ALL=C command grep -c '^' "$file") || return 1
  [ "$lines" -eq 3 ] || return 1
  source_line=$(command tr -d '\r' <"$file" | command sed -n '1p') || return 1
  url_line=$(command tr -d '\r' <"$file" | command sed -n '2p') || return 1
  path_line=$(command tr -d '\r' <"$file" | command sed -n '3p') || return 1
  case $source_line in source=*) ;; *) return 1 ;; esac
  case $url_line in url=*) ;; *) return 1 ;; esac
  case $path_line in path=*) ;; *) return 1 ;; esac
  _AIP_SKILL_SOURCE=${source_line#source=}
  _AIP_SKILL_URL=${url_line#url=}
  _AIP_SKILL_PATH=${path_line#path=}
  [ -n "$_AIP_SKILL_URL" ] || return 1
}

_aip_skills_update_usage() {
  _aip_error 'usage: aip skills update PROFILE NAME... | aip skills update --all-profiles NAME... | aip skills update PROFILE --all | aip skills update --all-profiles --all'
}

_aip_skills_update_one() (
  # $1 profile, $2 name. Sidecar-keyed: missing dest or sidecar is an error.
  local pname=$1 name=$2 dest url source_path source dir skill_dir staging
  dest=$(_aip_profile_path "$pname")/skills/$name
  if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
    _aip_error "skill '$name' is not installed in profile $pname"
    return 1
  fi
  if ! _aip_read_skill_source "$dest"; then
    _aip_error "skill '$name' in profile $pname has no recorded source; reinstall it with aip skills add"
    return 1
  fi
  source=$_AIP_SKILL_SOURCE
  url=$_AIP_SKILL_URL
  source_path=$_AIP_SKILL_PATH
  dir=$(command mktemp "${TMPDIR:-/tmp}/aip-add.XXXXXX") || { _aip_error 'could not create a temporary directory'; return 1; }
  command rm -f -- "$dir"
  trap 'command rm -rf -- "$dir"; [ -n "${staging-}" ] && command rm -rf -- "$staging"' EXIT
  if ! _aip_add_clone "$url" "$dir"; then
    return 1
  fi
  if ! _aip_add_resolve_skill "$dir" "$source_path"; then
    return 1
  fi
  skill_dir=$_AIP_ADD_SKILL_DIR
  staging=$(command mktemp "${TMPDIR:-/tmp}/aip-upd.XXXXXX") || { _aip_error 'could not create a temporary directory'; return 1; }
  command rm -f -- "$staging"
  if ! _aip_add_copy_skill "$skill_dir" "$staging" "$name"; then
    return 1
  fi
  if ! _aip_write_skill_source "$staging" "$source" "$url" "$source_path"; then
    return 1
  fi
  if ! command rm -rf -- "$dest"; then
    _aip_error "could not remove the existing skill $name"
    return 1
  fi
  if ! command mv -- "$staging" "$dest"; then
    _aip_error "could not replace the skill $name"
    return 1
  fi
  staging=
  printf 'updated %s in %s\n' "$name" "$pname"
)

_aip_skills_update_all() {
  # $1 profile. Update every sidecar-backed skill dir; note dirs without a sidecar.
  local pname=$1 skills dest name
  skills=$(_aip_profile_path "$pname")/skills
  [ -d "$skills" ] || return 0
  command find "$skills" -mindepth 1 -maxdepth 1 ! -name '.git' -print | LC_ALL=C command sort |
  while IFS= read -r dest; do
    [ -n "$dest" ] || continue
    [ -d "$dest" ] || continue
    name=${dest##*/}
    if [ -e "$dest/.aip-source" ] || [ -L "$dest/.aip-source" ]; then
      if _aip_read_skill_source "$dest"; then
        _aip_skills_update_one "$pname" "$name" || return 1
      else
        _aip_error "skill '$name' in profile $pname has no recorded source; reinstall it with aip skills add"
        return 1
      fi
    else
      printf 'skipped %s in %s (no recorded source)\n' "$name" "$pname"
    fi
  done
}

_aip_skills_update() (
  _aip_clear_git_routing
  local profile='' all_profiles=0 all=0
  local arg namesfile profilesfile name pname dest found
  namesfile=$(command mktemp "${TMPDIR:-/tmp}/aip-upd-names.XXXXXX") || return 1
  profilesfile=$(command mktemp "${TMPDIR:-/tmp}/aip-upd-profiles.XXXXXX") || { command rm -f "$namesfile"; return 1; }
  trap 'command rm -f "$namesfile" "$profilesfile"' EXIT
  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    case $arg in
      --all-profiles) all_profiles=1 ;;
      --all) all=1 ;;
      --)
        while [ "$#" -gt 0 ]; do
          printf '%s\n' "$1" >>"$namesfile"
          shift
        done
        ;;
      -*)
        _aip_error "unknown update option '$arg'"
        _aip_skills_update_usage
        return 2
        ;;
      *)
        if [ -z "$profile" ] && [ "$all_profiles" -eq 0 ]; then profile=$arg
        else printf '%s\n' "$arg" >>"$namesfile"
        fi
        ;;
    esac
  done
  if [ -z "$profile" ] && [ "$all_profiles" -eq 0 ]; then
    _aip_error 'no profile selected; pass a PROFILE or --all-profiles'
    _aip_skills_update_usage
    return 2
  fi
  { [ "$all_profiles" -eq 1 ] && [ -n "$profile" ]; } && { _aip_error '--all-profiles conflicts with the PROFILE argument'; _aip_skills_update_usage; return 2; }
  { [ "$all" -eq 1 ] && [ -s "$namesfile" ]; } && { _aip_error '--all conflicts with NAME arguments'; _aip_skills_update_usage; return 2; }
  if [ "$all" -eq 0 ] && [ ! -s "$namesfile" ]; then
    _aip_skills_update_usage
    return 2
  fi
  if [ "$all_profiles" -eq 1 ]; then
    _aip_list_profile_names | command grep -vx aip >|"$profilesfile" || :
    if [ ! -s "$profilesfile" ]; then
      if [ -n "$(_aip_list_profile_names)" ]; then
        _aip_error 'no user profiles found; --all-profiles skips the aip management profile'
        return 1
      fi
      _aip_error 'no profiles found; create a profile with aip create first'
      return 1
    fi
  else
    _aip_import_require_profile "$profile" || return
    printf '%s\n' "$profile" >|"$profilesfile"
  fi
  if [ "$all" -eq 1 ]; then
    while IFS= read -r pname; do
      [ -n "$pname" ] || continue
      _aip_skills_update_all "$pname" || return 1
    done <"$profilesfile"
    return 0
  fi
  while IFS= read -r name || [ -n "$name" ]; do
    _aip_validate_name "$name" || { _aip_error "invalid skill name '$name'; use lowercase letters, digits, hyphens or underscores"; return 1; }
    if [ "$all_profiles" -eq 1 ]; then
      found=0
      while IFS= read -r pname; do
        [ -n "$pname" ] || continue
        dest=$(_aip_profile_path "$pname")/skills/$name
        if [ -e "$dest/.aip-source" ] || [ -L "$dest/.aip-source" ]; then
          if _aip_read_skill_source "$dest"; then
            _aip_skills_update_one "$pname" "$name" || return 1
            found=1
          else
            _aip_error "skill '$name' in profile $pname has no recorded source; reinstall it with aip skills add"
            return 1
          fi
        elif [ -e "$dest" ] || [ -L "$dest" ]; then
          printf 'skipped %s in %s (no recorded source)\n' "$name" "$pname"
        fi
      done <"$profilesfile"
      [ "$found" -eq 1 ] || { _aip_error "skill '$name' has no recorded source in any target profile"; return 1; }
    else
      _aip_skills_update_one "$profile" "$name" || return 1
    fi
  done <"$namesfile"
  return 0
)

_aip_skills_remove_usage() {
  _aip_error 'usage: aip skills remove PROFILE NAME... | aip skills remove --all-profiles NAME...'
}

_aip_skills_remove_one() {
  # $1 profile, $2 name. Directory-keyed: dest must exist.
  local pname=$1 name=$2 dest skills
  skills=$(_aip_profile_path "$pname")/skills
  dest=$skills/$name
  if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
    _aip_error "skill '$name' is not installed in profile $pname"
    return 1
  fi
  if ! _aip_path_is_under "$skills" "$dest"; then
    _aip_error "invalid skill name '$name'"
    return 1
  fi
  command rm -rf -- "$dest" || { _aip_error "could not remove the skill $name"; return 1; }
  printf 'removed %s from %s\n' "$name" "$pname"
}

_aip_skills_remove() (
  _aip_clear_git_routing
  local profile='' all_profiles=0
  local arg namesfile profilesfile name pname dest found
  namesfile=$(command mktemp "${TMPDIR:-/tmp}/aip-rm-names.XXXXXX") || return 1
  profilesfile=$(command mktemp "${TMPDIR:-/tmp}/aip-rm-profiles.XXXXXX") || { command rm -f "$namesfile"; return 1; }
  trap 'command rm -f "$namesfile" "$profilesfile"' EXIT
  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    case $arg in
      --all-profiles) all_profiles=1 ;;
      --)
        while [ "$#" -gt 0 ]; do
          printf '%s\n' "$1" >>"$namesfile"
          shift
        done
        ;;
      -*)
        _aip_error "unknown remove option '$arg'"
        _aip_skills_remove_usage
        return 2
        ;;
      *)
        if [ -z "$profile" ] && [ "$all_profiles" -eq 0 ]; then profile=$arg
        else printf '%s\n' "$arg" >>"$namesfile"
        fi
        ;;
    esac
  done
  if [ -z "$profile" ] && [ "$all_profiles" -eq 0 ]; then
    _aip_error 'no profile selected; pass a PROFILE or --all-profiles'
    _aip_skills_remove_usage
    return 2
  fi
  [ -s "$namesfile" ] || { _aip_skills_remove_usage; return 2; }
  { [ "$all_profiles" -eq 1 ] && [ -n "$profile" ]; } && { _aip_error '--all-profiles conflicts with the PROFILE argument'; _aip_skills_remove_usage; return 2; }
  if [ "$all_profiles" -eq 1 ]; then
    _aip_list_profile_names | command grep -vx aip >|"$profilesfile" || :
    if [ ! -s "$profilesfile" ]; then
      if [ -n "$(_aip_list_profile_names)" ]; then
        _aip_error 'no user profiles found; --all-profiles skips the aip management profile'
        return 1
      fi
      _aip_error 'no profiles found; create a profile with aip create first'
      return 1
    fi
  else
    _aip_import_require_profile "$profile" || return
    printf '%s\n' "$profile" >|"$profilesfile"
  fi
  while IFS= read -r name || [ -n "$name" ]; do
    _aip_validate_name "$name" || { _aip_error "invalid skill name '$name'; use lowercase letters, digits, hyphens or underscores"; return 1; }
    if [ "$all_profiles" -eq 1 ]; then
      found=0
      while IFS= read -r pname; do
        [ -n "$pname" ] || continue
        dest=$(_aip_profile_path "$pname")/skills/$name
        if [ -e "$dest" ] || [ -L "$dest" ]; then
          _aip_skills_remove_one "$pname" "$name" || return 1
          found=1
        fi
      done <"$profilesfile"
      [ "$found" -eq 1 ] || { _aip_error "skill '$name' is not installed in any target profile"; return 1; }
    else
      _aip_skills_remove_one "$profile" "$name" || return 1
    fi
  done <"$namesfile"
  return 0
)

_aip_add_usage() {
  _aip_error 'usage: aip skills add PROFILE SOURCE... | aip skills add --all-profiles SOURCE... [--force] [--skip-existing]'
}

_aip_add_parse_source() {
  # $1 source. Sets _AIP_ADD_URL, _AIP_ADD_PATH ('' = repository root), _AIP_ADD_NAME.
  # Returns 0 ok, 2 usage error (message printed), 1 invalid in-repo path.
  local source=$1 url source_path name rest second
  case $source in
    ''|*$'\n'*|*"*"*|*'\\'*|*' '*|*$'\t'*)
      _aip_error "invalid source: $(_aip_redact_url "$source")"
      return 2
      ;;
    /*|'~/'*|'./'*|'../'*)
      _aip_error "unsupported source: $source; plain local paths need a file:// URL, or use owner/repo[/path] or a git URL"
      return 2
      ;;
  esac
  if [[ $source == *'://'* ]]; then
    url=${source%%#*}
    source_path=''
    case $source in *'#'*) source_path=${source#*#} ;; esac
    case $url in
      https://*|ssh://*|file://*) ;;
      *) _aip_error "unsupported source URL: $(_aip_redact_url "$source"); expected https://, ssh://, git@, or file://"; return 2 ;;
    esac
  elif [[ $source == *'@'* ]]; then
    # scp-style ssh: user@host:owner/repo[.git]
    url=${source%%#*}
    source_path=''
    case $source in *'#'*) source_path=${source#*#} ;; esac
  else
    # GitHub shorthand: owner/repo[/sub/source_path]
    case $source in
      */*) ;;
      *) _aip_error "unsupported source: $source; plain local paths need a file:// URL, or use owner/repo[/path] or a git URL"; return 2 ;;
    esac
    rest=${source#*/}
    second=${rest%%/*}
    source_path=''
    case $rest in */*) source_path=${rest#*/} ;; esac
    url="https://github.com/${source%%/*}/$second.git"
  fi
  case $source_path in
    ''|'/') source_path='' ;;
  esac
  local p seg
  p=$source_path
  while [ -n "$p" ]; do
    seg=${p%%/*}
    case $seg in
      ''|.|..|/*) _aip_error "invalid source path: $source_path"; return 1 ;;
    esac
    case $p in */*) p=${p#*/} ;; *) p='' ;; esac
  done
  if [ -n "$source_path" ]; then
    name=${source_path##*/}
  else
    name=${url##*/}
    name=${name##*:}
    case $name in *.git) name=${name%.git} ;; esac
  fi
  [ -n "$name" ] || { _aip_error "unsupported source: $(_aip_redact_url "$source"); cannot determine the skill name"; return 2; }
  _AIP_ADD_URL=$url
  _AIP_ADD_PATH=$source_path
  _AIP_ADD_NAME=$name
  return 0
}

_aip_add_clone() {
  # $1 url, $2 directory (must not exist yet). core.symlinks=true at clone
  # time so Windows materializes tracked symlinks for the path-walk reject.
  local url=$1 dir=$2
  if ! _aip_prepare_ssh_transport "$dir"; then
    _aip_error 'source is unavailable because the configured SSH variant cannot be made non-interactive'
    return 1
  fi
  if ! GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_SSH_COMMAND="$_AIP_SSH_COMMAND" GIT_SSH_VARIANT="$_AIP_SSH_VARIANT" LC_ALL=C _aip_git clone -c core.symlinks=true --quiet --depth 1 -- "$url" "$dir" 2>/dev/null; then
    _aip_error "could not clone $(_aip_redact_url "$url"); the source repository is unreachable or requires interactive credentials"
    return 1
  fi
  return 0
}

_aip_add_resolve_skill() {
  # $1 cloned root, $2 in-repo path ('' = root). Sets _AIP_ADD_SKILL_DIR.
  local root=$1 source_path=$2 prefix='' seg dir=$1
  if [ -n "$source_path" ]; then
    local p=$source_path
    while [ -n "$p" ]; do
      seg=${p%%/*}
      case $seg in
        ''|.|..|/*) _aip_error "invalid source path: $source_path"; return 1 ;;
      esac
      if [ ! -e "$root/$prefix$seg" ] || [ -L "$root/$prefix$seg" ]; then
        if [ -e "$root/$prefix$seg" ] && [ -L "$root/$prefix$seg" ]; then
          _aip_error "source path follows a symlink: $source_path"
        else
          _aip_error "no such path in the source repository: $source_path"
        fi
        return 1
      fi
      [ -d "$root/$prefix$seg" ] || { _aip_error "no such path in the source repository: $source_path"; return 1; }
      prefix=$prefix$seg/
      case $p in */*) p=${p#*/} ;; *) p='' ;; esac
    done
    dir="$root/$prefix"
  fi
  if ! _aip_path_is_under "$root" "$dir"; then
    _aip_error "invalid source path: ${source_path:-$_AIP_ADD_NAME}"
    return 1
  fi
  [ -f "$dir/SKILL.md" ] || { _aip_error "no SKILL.md in the source path: ${source_path:-$_AIP_ADD_NAME}"; return 1; }
  _AIP_ADD_SKILL_DIR=$dir
  return 0
}

_aip_add_install_skill() {
  # $1 skill dir, $2 name, $3 profile name, $4 force (0|1), $5 skip_existing (0|1)
  # returns 0 installed, 3 skipped, 1 error (message printed)
  local src=$1 name=$2 pname=$3 force=$4 skip_existing=$5
  local dest skills profile_path
  profile_path=$(_aip_profile_path "$pname")
  skills=$profile_path/skills
  dest=$skills/$name
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    if [ "$skip_existing" -eq 1 ]; then
      printf 'skipped %s in %s (already present)\n' "$name" "$pname"
      return 3
    fi
    if [ "$force" -eq 1 ]; then
      command rm -rf -- "$dest" || { _aip_error "could not remove the existing skill $name"; return 1; }
    else
      _aip_error "skill '$name' already exists in profile $pname; pass --force to replace it or --skip-existing to keep it"
      return 1
    fi
  fi
  command mkdir -p -- "$skills" || { _aip_error "could not create $skills"; return 1; }
  if ! _aip_path_is_under "$skills" "$dest"; then
    _aip_error "invalid source path: $name"
    return 1
  fi
  _aip_add_copy_skill "$src" "$dest" "$name" || return 1
  return 0
}

_aip_add_copy_skill() {
  # $1 source skill dir, $2 dest (must not exist), $3 display name.
  # Walk the source first: any symlink fails (dest absent). Then copy excluding .git.
  local src=$1 dest=$2 name=$3 found entry
  # zsh's NOMATCH option errors on the empty hidden-file glob below; scope the
  # portable no-match behaviour to this function without changing caller options.
  if [ -n "${ZSH_VERSION-}" ]; then setopt localoptions nonomatch; fi
  found=$(command find "$src" \( -name .git -type d -prune \) -o -type l -print) || return 1
  if [ -n "$found" ]; then
    _aip_error "skill '$name' contains a nested symlink; dest is not created"
    return 1
  fi
  command mkdir -p -- "$dest" || { _aip_error "could not copy the skill $name"; return 1; }
  for entry in "$src"/.* "$src"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    case ${entry##*/} in
      .|..) continue ;;
      .git) continue ;;
    esac
    if ! command cp -Rp -- "$entry" "$dest/"; then
      command rm -rf -- "$dest"
      _aip_error "could not copy the skill $name"
      return 1
    fi
  done
  return 0
}

_aip_add() (
  _aip_clear_git_routing
  local profile='' all_profiles=0 force=0 skip_existing=0
  local arg sourcesfile installedfile profilesfile src name url source_path pname rc
  sourcesfile=$(command mktemp "${TMPDIR:-/tmp}/aip-add-sources.XXXXXX") || return 1
  installedfile=$(command mktemp "${TMPDIR:-/tmp}/aip-add-installed.XXXXXX") || { command rm -f "$sourcesfile"; return 1; }
  profilesfile=$(command mktemp "${TMPDIR:-/tmp}/aip-add-profiles.XXXXXX") || { command rm -f "$sourcesfile" "$installedfile"; return 1; }
  trap 'command rm -f "$sourcesfile" "$installedfile" "$profilesfile"' EXIT
  while [ "$#" -gt 0 ]; do
    arg=$1
    shift
    case $arg in
      --all-profiles) all_profiles=1 ;;
      --force) force=1 ;;
      --skip-existing) skip_existing=1 ;;
      --)
        while [ "$#" -gt 0 ]; do
          printf '%s\n' "$1" >>"$sourcesfile"
          shift
        done
        ;;
      -*)
        _aip_error "unknown add option '$arg'"
        _aip_add_usage
        return 2
        ;;
      *)
        if [ -z "$profile" ] && [ "$all_profiles" -eq 0 ]; then profile=$arg
        else printf '%s\n' "$arg" >>"$sourcesfile"
        fi
        ;;
    esac
  done
  if [ -z "$profile" ] && [ "$all_profiles" -eq 0 ]; then
    _aip_error 'no profile selected; pass a PROFILE or --all-profiles'
    _aip_add_usage
    return 2
  fi
  [ -s "$sourcesfile" ] || { _aip_error 'no source given'; _aip_add_usage; return 2; }
  { [ "$force" -eq 1 ] && [ "$skip_existing" -eq 1 ]; } && { _aip_error '--force and --skip-existing conflict'; return 2; }
  { [ "$all_profiles" -eq 1 ] && [ -n "$profile" ]; } && { _aip_error '--all-profiles conflicts with the PROFILE argument'; return 2; }
  if [ "$all_profiles" -eq 1 ]; then
    _aip_list_profile_names | command grep -vx aip >|"$profilesfile" || :
    if [ ! -s "$profilesfile" ]; then
      if [ -n "$(_aip_list_profile_names)" ]; then
        _aip_error 'no user profiles found; --all-profiles skips the aip management profile'
        return 1
      fi
      _aip_error 'no profiles found; create a profile with aip create first'
      return 1
    fi
  else
    _aip_import_require_profile "$profile" || return
    printf '%s\n' "$profile" >|"$profilesfile"
  fi
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    _aip_add_parse_source "$src" || return
    url=$_AIP_ADD_URL
    source_path=$_AIP_ADD_PATH
    name=$_AIP_ADD_NAME
    _aip_validate_name "$name" || { _aip_error "invalid skill name '$name'; use lowercase letters, digits, hyphens or underscores"; return 1; }
    if [ -n "$(command grep -Fx -- "$name" "$installedfile" 2>/dev/null)" ]; then
      _aip_error "duplicate skill name in this call: $name"
      return 1
    fi
    local dir
    dir=$(command mktemp "${TMPDIR:-/tmp}/aip-add.XXXXXX") || { _aip_error 'could not create a temporary directory'; return 1; }
    command rm -f -- "$dir"
    _aip_add_clone "$url" "$dir" || { command rm -rf -- "$dir"; return 1; }
    _aip_add_resolve_skill "$dir" "$source_path" || { command rm -rf -- "$dir"; return 1; }
    local skill_dir dest install_rc rc=0
    skill_dir=$_AIP_ADD_SKILL_DIR
    while IFS= read -r pname; do
      [ -n "$pname" ] || continue
      install_rc=0
      _aip_add_install_skill "$skill_dir" "$name" "$pname" "$force" "$skip_existing" || install_rc=$?
      case $install_rc in
        0)
          dest=$(_aip_profile_path "$pname")/skills/$name
          if ! _aip_write_skill_source "$dest" "$src" "$url" "$source_path"; then
            rc=1
            break
          fi
          printf 'added %s to %s\n' "$name" "$pname"
          ;;
        3) ;;
        *) rc=1; break ;;
      esac
    done <"$profilesfile"
    command rm -rf -- "$dir"
    [ "$rc" -eq 0 ] || return 1
    printf '%s\n' "$name" >>"$installedfile"
  done <"$sourcesfile"
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
  aip create NAME                    Create a new profile
  aip list                           List profiles and selection
  aip which [NAME]                   Show the profile that would be selected
  aip default [NAME]                 Show or set the default profile
  aip use NAME                       Select NAME for this shell only
  aip local [NAME | --remove]        Set or clear the per-directory marker
  aip clone SOURCE TARGET            Copy a profile into a new profile
  aip delete NAME [--force]          Delete a profile
  aip manage HARNESS [ARGS...]       Launch a harness with the aip profile
  aip sync                           Checkpoint and sync every profile
  aip sync-packages [NAME] [--add SPEC | --remove PKG | --replace]   Sync a profile's pi package list with the global settings
  aip remote add URL                 Connect the profiles repository to a remote
  aip remote show                    Show the configured remote (if any)
  aip remote remove                  Disconnect the remote
  aip skills add|update|remove       Install, refresh, or remove skills
  aip import HARNESS FILE... --profile NAME[,NAME...] | --all-profiles
                                     Copy config from a harness into profiles
  aip doctor [NAME]                  Diagnose profiles and offer safe link repairs
  aip run [NAME] HARNESS [ARGS...]   Launch a harness with a profile
  aip update                         Migrate legacy configs and update the aip npm package
  aip uninstall [--force]            Remove the aip installation (not your profiles)
  aip version                        Show the aip version
  aip help                           Show this help

Pi skills: when stdin is a terminal, `aip create NAME` lists eligible skills
from Pi profiles below the current directory and `~/.pi/agent/skills`. Enter
numbers separated by commas or spaces (or press Enter for none); selections are
copied into the new profile's shared `skills/` directory.

Primary configs are copied when present but remain untracked. Inspect each one
before deliberately sharing it with Git; `aip sync` never adds it for you.

Doctor lists every profile-link defect before one `Repair these link issues?
[Y/n]` prompt; Enter means yes. Accepted link-only repairs are staged, and the
next normal launch checkpoints them. Non-interactive doctor runs never repair,
and unrelated Git, environment, and harness findings remain report-only.

Harness wrappers:
  claude, codex, pi, opencode [ARGS...] launch the named tool with the
  selected profile's settings, checkpointing the profiles repository before
  and after the run. If the remote is unreachable they warn and launch the
  committed local profile instead; a Git conflict blocks the launch until
  it is resolved.

Quick start:
  aip create work                 create your first profile
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
    printf '%s\n' "$(_aip_redact_url "$url")"
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
    *' '*|*$'\n'*) _aip_error "invalid remote URL: $(_aip_redact_url "$url")"; return 2 ;;
  esac
  if [ -d "$root/.git" ] && [ ! -L "$root/.git" ]; then
    existing_origin=$(_aip_git -C "$root" remote get-url origin 2>/dev/null) || existing_origin=
    if [ -n "$existing_origin" ]; then
      _aip_error "origin is already configured ($(_aip_redact_url "$existing_origin")); run 'aip remote remove' first"
      return 1
    fi
    _aip_git -C "$root" remote add origin "$url" 2>/dev/null || {
      _aip_error "could not configure origin: $(_aip_redact_url "$url")"
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
    if ! GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_SSH_COMMAND="$_AIP_SSH_COMMAND" GIT_SSH_VARIANT="$_AIP_SSH_VARIANT" LC_ALL=C _aip_git clone -c core.symlinks=true --quiet -- "$url" "$root" 2>/dev/null; then
      _aip_error "could not clone $(_aip_redact_url "$url") into $root; the remote must be a profiles repository created by aip"
      return 1
    fi
    _aip_git -C "$root" config --replace-all core.symlinks true || { _aip_error 'could not configure symbolic-link checkout'; return 1; }
    _aip_git -C "$root" config core.longpaths true 2>/dev/null || :
    if ! _aip_git -C "$root" rev-parse --verify HEAD >/dev/null 2>&1 &&
       _aip_git -C "$root" rev-parse --verify refs/remotes/origin/main >/dev/null 2>&1; then
      _aip_git -C "$root" checkout -q -B main refs/remotes/origin/main 2>/dev/null || {
        _aip_error 'could not check out the cloned profiles branch'
        return 1
      }
    fi
    printf 'Cloned profiles from %s.\n' "$(_aip_redact_url "$url")"
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
    skills) _aip_skills "$@" ;;
    create) _aip_create "$@" ;;
    manage) _aip_manage "$@" ;;
    clone) _aip_clone "$@" ;;
    default) _aip_default "$@" ;;
    delete) _aip_delete "$@" ;;
    doctor) _aip_doctor "$@" ;;
    list) _aip_list "$@" ;;
    local) _aip_local "$@" ;;
    help) _aip_help "$@" ;;
    --help) _aip_help ;;
    -h) _aip_help ;;
    --version) _aip_version "$@" ;;
    -v) _aip_version "$@" ;;
    remote) _aip_remote "$@" ;;
    import) _aip_import "$@" ;;
    run) _aip_run "$@" ;;
    sync) _aip_sync_command "$@" ;;
    sync-packages) _aip_sync_packages "$@" ;;
    use) _aip_use "$@" ;;
    uninstall) _aip_uninstall "$@" ;;
    update) _aip_update "$@" ;;
    version) _aip_version "$@" ;;
    which) _aip_which "$@" ;;
  esac
}

_aip_shell_profile_path() {
  # The shell profile the installer marks, resolved the same way install.sh does.
  if [ -n "${_AIP_SHELL_PROFILE-}" ]; then
    printf '%s\n' "$_AIP_SHELL_PROFILE"
    return 0
  fi
  case ${SHELL##*/} in
    bash)
      if [ "$(command uname -s 2>/dev/null)" = Darwin ]; then
        for candidate in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
          [ -e "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
        done
        printf '%s\n' "$HOME/.bash_profile"
      else
        printf '%s\n' "$HOME/.bashrc"
      fi
      return 0
      ;;
    zsh)
      printf '%s\n' "$HOME/.zshrc"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_aip_uninstall() {
  local force=0
  if [ "${1-}" = --force ] && [ "$#" -eq 1 ]; then force=1; shift; fi
  [ "$#" -eq 0 ] || {
    _aip_error 'usage: aip uninstall [--force]'
    return 2
  }
  local install_root shell_profile has_root=0 has_block=0 temporary answer
  install_root=${_AIP_INSTALL_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/aip}
  if ! shell_profile=$(_aip_shell_profile_path); then
    _aip_error 'supported login shells are Bash and Zsh; set SHELL correctly and retry'
    return 1
  fi
  { [ -d "$install_root" ] && {
      [ -f "$install_root/aip.sh" ] || [ -f "$install_root/aip.ps1" ] || [ -f "$install_root/VERSION" ]
    }; } && has_root=1
  if [ -f "$shell_profile" ] && command grep -Fqx '# >>> aip >>>' "$shell_profile"; then has_block=1; fi
  if [ "$has_root" -eq 0 ] && [ "$has_block" -eq 0 ]; then
    printf 'Nothing to uninstall (no aip install at %s and no aip block in %s).\n' "$install_root" "$shell_profile"
    return 0
  fi
  local prompt
  if [ "$has_root" -eq 1 ] && [ "$has_block" -eq 1 ]; then
    prompt='Remove the aip installation root and the shell profile block? [y/N] '
  elif [ "$has_root" -eq 1 ]; then
    prompt='Remove the aip installation root? [y/N] '
  else
    prompt='Remove the aip block from your shell profile? [y/N] '
  fi
  if [ "$force" -ne 1 ]; then
    if [ ! -t 0 ]; then
      _aip_error 'uninstall requires confirmation; rerun with --force'
      return 1
    fi
    printf '%s' "$prompt"
    IFS= read -r answer || return 1
    _aip_delete_confirm_accepts "$answer" || { _aip_error 'uninstall cancelled'; return 1; }
  fi
  if [ "$has_block" -eq 1 ]; then
    temporary=$(command mktemp "${shell_profile}.XXXXXX") || return 1
    # Drops the marked block and the blank separator line the installer adds
    # before it; every other line is preserved verbatim.
    if ! command awk '
      in_block { if ($0 == "# <<< aip <<<") in_block = 0; next }
      $0 == "# >>> aip >>>" { if (have && held == "") have = 0; in_block = 1; next }
      { if (have) print held; held = $0; have = 1 }
      END { if (have) print held }
    ' "$shell_profile" >"$temporary"; then
      command rm -f "$temporary"
      _aip_error "could not update the shell profile: $shell_profile"
      return 1
    fi
    if ! command cat "$temporary" >"$shell_profile"; then
      command rm -f "$temporary"
      _aip_error "could not update the shell profile: $shell_profile"
      return 1
    fi
    command rm -f "$temporary"
  fi
  if [ "$has_root" -eq 1 ]; then
    if ! command rm -rf -- "$install_root"; then
      _aip_error "could not remove the install root: $install_root"
      return 1
    fi
  fi
  printf 'Uninstalled aip. Your profiles repository at %s and your harness configuration are untouched; restart your shell to finish.\n' "$_AIP_PROFILE_ROOT"
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
