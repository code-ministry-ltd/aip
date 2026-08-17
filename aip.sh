# aip — AI Profile for Bash and Zsh. Source this file from your shell profile.

: "${_AIP_PROFILE_ROOT:=${HOME}/agent-profiles}"
_AIP_VERSION='0.1.0'

_aip_error() {
  printf 'aip: %s\n' "$*" >&2
}

_aip_update() {
  [ "$#" -eq 0 ] || { _aip_error 'usage: aip update'; return 2; }
  (
    _aip_clear_git_routing
    if ! command -v npx >/dev/null 2>&1; then
      _aip_error 'update requires Node.js (npx) on PATH'
      return 1
    fi
    command npx --yes @code-ministry/aip update
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
    case $(LC_ALL=C printf '%s' "$executable" | command tr '[:upper:]' '[:lower:]') in
      plink|plink.exe|putty|putty.exe) variant=plink ;;
      tortoiseplink|tortoiseplink.exe) variant=tortoiseplink ;;
      *) variant=ssh ;;
    esac
  fi
  case $(LC_ALL=C printf '%s' "$variant" | command tr '[:upper:]' '[:lower:]') in
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
    '.aip-stage.*/' \
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
    if ! _aip_is_required_profile_link "$relative"; then
      command rm -f "$entries"
      _aip_error "profile contains an unsupported symbolic link that could escape its boundary: $relative"
      return 1
    fi
  done <"$entries"
  command rm -f "$entries"
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

  _aip_error "no profile selected; run 'aip create NAME' then 'aip use NAME'"
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
  _aip_git -C "$_AIP_PROFILE_ROOT" add "$target_name" || {
    _aip_error "could not commit clone of profile '$source_name'; check Git identity and hooks"
    return 1
  }
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
  _aip_resolve_profile || return
  local profile_path outfit harness availability
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
  [ "${1-}" = create ] || [ "${1-}" = clone ] || [ "${1-}" = default ] ||
    [ "${1-}" = delete ] || [ "${1-}" = doctor ] || [ "${1-}" = list ] ||
    [ "${1-}" = local ] || [ "${1-}" = outfit ] || [ "${1-}" = run ] ||
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

_aip_is_forbidden_path() {
  local lower
  lower=$(LC_ALL=C printf '%s' "$1" | command tr '[:upper:]' '[:lower:]') || return 0
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
      case $(LC_ALL=C printf '%s' "$component" | command tr '[:upper:]' '[:lower:]') in
        .git)
          _AIP_PORTABLE_PATH_ERROR=$relative
          command rm -f "$lines" "$keys" "$sorted"
          return 1
          ;;
      esac
      case $(LC_ALL=C printf '%s' "$base" | command tr '[:upper:]' '[:lower:]') in
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
  local first=${1%%/*}
  [ "$first" != "$1" ] && command grep -qxF -- "$first" "$2"
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
  local profile=$1 upstream_commit=$2 remote_paths local_paths remote_path local_path remote_folded local_folded
  remote_paths=$(command mktemp "${TMPDIR:-/tmp}/aip-remote-paths.XXXXXX") || return
  local_paths=$(command mktemp "${TMPDIR:-/tmp}/aip-local-paths.XXXXXX") || { command rm -f "$remote_paths"; return 1; }
  if ! _aip_git -C "$profile" diff --name-only --diff-filter=ACMRT -z HEAD "$upstream_commit" >|"$remote_paths" ||
     ! _aip_git -C "$profile" ls-files --others --exclude-standard -z >|"$local_paths" ||
     ! _aip_git -C "$profile" ls-files --others --ignored --exclude-standard -z >>"$local_paths"; then
    command rm -f "$remote_paths" "$local_paths"
    _aip_error 'could not inspect local untracked and ignored paths before integrating the remote profile'
    return 1
  fi
  # Cleanup only unlinks the temporary names; both loops keep their open descriptors.
  # shellcheck disable=SC2094
  while IFS= read -r -d '' remote_path; do
    remote_path=${remote_path%/}
    remote_folded=$(LC_ALL=C printf '%s' "$remote_path" | command tr '[:upper:]' '[:lower:]') || {
      command rm -f "$remote_paths" "$local_paths"
      return 1
    }
    while IFS= read -r -d '' local_path; do
      local_path=${local_path%/}
      local_folded=$(LC_ALL=C printf '%s' "$local_path" | command tr '[:upper:]' '[:lower:]') || {
        command rm -f "$remote_paths" "$local_paths"
        return 1
      }
      if [ "$remote_folded" = "$local_folded" ] ||
         case $remote_folded in "$local_folded"/*) true ;; *) false ;; esac ||
         case $local_folded in "$remote_folded"/*) true ;; *) false ;; esac; then
        command rm -f "$remote_paths" "$local_paths"
        _aip_error "remote integration would overwrite or replace untracked or ignored local profile state; inspect with 'git -C \"$profile\" status --ignored --untracked-files=all' and move or deliberately track the conflicting path"
        return 1
      fi
    done <"$local_paths"
  done <"$remote_paths"
  command rm -f "$remote_paths" "$local_paths"
}

_aip_sync() (
  local mode=${1-manual} root=$_AIP_PROFILE_ROOT upstream upstream_commit branch remote merge_ref name profile_path
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
