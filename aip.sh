# aip — AI Profile for Bash and Zsh. Source this file from your shell profile.

: "${_AIP_PROFILE_ROOT:=${HOME}/agent-profiles}"

_aip_error() {
  printf 'aip: %s\n' "$*" >&2
}

_aip_validate_name() {
  case ${1-} in
    ''|*[!a-z0-9_-]*|-*|_*|*-|*_) return 1 ;;
  esac
  [ "${#1}" -le 64 ] || return 1
  case $1 in
    *..*) return 1 ;;
  esac
}

_aip_validate_outfit() {
  [ -n "${1-}" ] && [ "${#1}" -le 64 ] || return 1
  case $1 in
    *[[:cntrl:]]*) return 1 ;;
  esac
}

_aip_profile_path() {
  printf '%s/%s\n' "$_AIP_PROFILE_ROOT" "$1"
}

_aip_read_name_file() {
  [ -f "$1" ] || return 1
  local first extra
  {
    IFS= read -r first || [ -n "$first" ] || return 1
    if IFS= read -r extra; then
      return 1
    fi
  } <"$1"
  first=${first%"$(printf '\r')"}
  _aip_validate_name "$first" || return 1
  printf '%s\n' "$first"
}

_aip_read_outfit() {
  local outfit
  outfit=$(cat "$1" 2>/dev/null) || return 1
  _aip_validate_outfit "$outfit" || return 1
  printf '%s\n' "$outfit"
}

_aip_find_project_marker() {
  local dir=$PWD parent
  while :; do
    if [ -e "$dir/.aip-profile" ]; then
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
  local name=$1 path
  _aip_validate_name "$name" || {
    _aip_error "invalid profile name '$name'"
    return 2
  }
  path=$(_aip_profile_path "$name")
  [ -d "$path" ] || {
    _aip_error "profile '$name' does not exist"
    return 2
  }
  [ -d "$path/.git" ] || {
    _aip_error "profile '$name' is not a Git repository; run 'aip doctor $name'"
    return 2
  }
}

_aip_resolve_profile() {
  local explicit=${1-} name

  if [ -n "$explicit" ]; then
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

  if [ -e "$_AIP_PROFILE_ROOT/.default" ]; then
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
  local path=$1 outfit=$2
  mkdir -p "$path/.aip" "$path/skills" "$path/claude" "$path/codex" "$path/pi" "$path/opencode" || return
  printf '%s\n' "$outfit" >"$path/.aip/outfit" || return
  printf '%s\n' '# Common profile instructions' >"$path/AGENTS.md" || return
  printf '%s\n' '@../AGENTS.md' '' '# Claude Code instructions' >"$path/claude/CLAUDE.md" || return
  printf '%s\n' '# Codex instructions' >"$path/codex/instructions.md" || return
  printf '%s\n' '# Pi instructions' >"$path/pi/APPEND_SYSTEM.md" || return
  printf '%s\n' '# aip-managed runtime exclusions' '.aip/sync.lock/' >"$path/.gitignore" || return
  ln -s ../skills "$path/claude/skills" || return
  ln -s ../AGENTS.md "$path/codex/AGENTS.md" || return
  ln -s ../skills "$path/codex/skills" || return
  ln -s ../AGENTS.md "$path/pi/AGENTS.md" || return
  ln -s ../skills "$path/pi/skills" || return
  ln -s ../AGENTS.md "$path/opencode/AGENTS.md" || return
  ln -s ../skills "$path/opencode/skills" || return
}

_aip_create() {
  local name=${1-} outfit=plain destination temporary
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
  command -v git >/dev/null 2>&1 || {
    _aip_error 'Git is required'
    return 1
  }
  git var GIT_AUTHOR_IDENT >/dev/null 2>&1 || {
    _aip_error "Git identity is not configured; set user.name and user.email"
    return 1
  }

  mkdir -p "$_AIP_PROFILE_ROOT" || return
  destination=$(_aip_profile_path "$name")
  [ ! -e "$destination" ] || {
    _aip_error "destination already exists: $destination"
    return 1
  }
  temporary=$(mktemp -d "$_AIP_PROFILE_ROOT/.aip-$name.XXXXXX") || return
  if ! _aip_write_profile_files "$temporary" "$outfit" ||
     ! git -C "$temporary" init -q -b main ||
     ! git -C "$temporary" add .aip/outfit .gitignore AGENTS.md skills claude/CLAUDE.md claude/skills codex/AGENTS.md codex/instructions.md codex/skills pi/AGENTS.md pi/APPEND_SYSTEM.md pi/skills opencode/AGENTS.md opencode/skills ||
     ! git -C "$temporary" commit -q -m 'aip: create profile' ||
     ! mv "$temporary" "$destination"; then
    rm -rf "$temporary"
    _aip_error "could not create profile '$name'"
    return 1
  fi
  printf "Created profile '%s' at %s\n" "$name" "$destination"
}

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
  _aip_resolve_profile "${1-}" || return
  _aip_profile_path "$_AIP_RESOLVED_NAME"
}

_aip_write_marker() {
  local destination=$1 name=$2 temporary
  temporary=$(mktemp "${destination}.XXXXXX") || return
  if ! printf '%s\n' "$name" >"$temporary" || ! mv "$temporary" "$destination"; then
    rm -f "$temporary"
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
  mkdir -p "$_AIP_PROFILE_ROOT" || return
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
    [ -e "$PWD/.aip-profile" ] || {
      _aip_error 'no profile marker exists in the current directory'
      return 1
    }
    rm -f "$PWD/.aip-profile" || return
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
  _aip_validate_outfit "$2" || {
    _aip_error 'outfit must be one printable, non-empty line of at most 64 characters'
    return 2
  }
  printf '%s\n' "$2" >"$(_aip_profile_path "$1")/.aip/outfit" || return
  printf "Profile '%s' now wears %s\n" "$1" "$2"
}

_aip_clone() {
  [ "$#" -eq 2 ] || {
    _aip_error 'usage: aip clone SOURCE TARGET'
    return 2
  }
  local source_name=$1 target_name=$2 source_path target_path temporary
  _aip_require_profile "$source_name" || return
  [ ! -L "$(_aip_profile_path "$source_name")" ] || {
    _aip_error 'source profile path must not be a symbolic link'
    return 1
  }
  _aip_validate_name "$target_name" || {
    _aip_error "invalid profile name '$target_name'"
    return 2
  }
  git var GIT_AUTHOR_IDENT >/dev/null 2>&1 || {
    _aip_error 'Git identity is not configured; set user.name and user.email'
    return 1
  }
  source_path=$(_aip_profile_path "$source_name")
  target_path=$(_aip_profile_path "$target_name")
  [ ! -e "$target_path" ] || {
    _aip_error "destination already exists: $target_path"
    return 1
  }
  temporary=$(mktemp -d "$_AIP_PROFILE_ROOT/.aip-$target_name.XXXXXX") || return
  rmdir "$temporary" || return
  if ! git clone --no-hardlinks -q "$source_path" "$temporary" ||
     ! rm -rf "$temporary/.git" ||
     ! git -C "$temporary" init -q -b main ||
     ! git -C "$temporary" add -A ||
     ! git -C "$temporary" commit -q -m "aip: clone $source_name" ||
     ! mv "$temporary" "$target_path"; then
    rm -rf "$temporary"
    _aip_error "could not clone profile '$source_name'"
    return 1
  fi
  printf "Cloned profile '%s' to '%s' at %s\n" "$source_name" "$target_name" "$target_path"
}

_aip_has_unfinished_git_operation() {
  local git_dir=$1/.git
  [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ] ||
    [ -f "$git_dir/MERGE_HEAD" ] || [ -f "$git_dir/CHERRY_PICK_HEAD" ] ||
    [ -f "$git_dir/REVERT_HEAD" ] || [ -f "$git_dir/BISECT_START" ]
}

_aip_delete() {
  local name=${1-} force=0 path risks= remote_configured=0 default_name=
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
  path=$(_aip_profile_path "$name")
  [ ! -L "$path" ] || {
    _aip_error 'profile path must not be a symbolic link'
    return 1
  }
  [ "${AIP_PROFILE-}" != "$name" ] || {
    _aip_error "cannot delete session profile '$name'; select another profile first"
    return 1
  }
  [ "$(cd "$_AIP_PROFILE_ROOT" && pwd -P)" = "$(cd "${path%/*}" && pwd -P)" ] || {
    _aip_error 'refusing to delete a profile outside the profile root'
    return 1
  }

  [ -z "$(git -C "$path" status --porcelain 2>/dev/null)" ] || risks='uncommitted changes'
  _aip_has_unfinished_git_operation "$path" && risks="${risks:+$risks, }unfinished Git operation"
  if git -C "$path" rev-parse --verify '@{upstream}' >/dev/null 2>&1; then
    [ -z "$(git -C "$path" rev-list '@{upstream}..HEAD')" ] || risks="${risks:+$risks, }unpushed commits"
  else
    risks="${risks:+$risks, }unpushed commits (no upstream)"
  fi
  [ -z "$(git -C "$path" remote)" ] || remote_configured=1

  if [ "$force" -ne 1 ]; then
    if [ ! -t 0 ]; then
      _aip_error "deletion requires confirmation${risks:+ ($risks)}; rerun with --force"
      return 1
    fi
    printf "Delete profile '%s' at %s%s? [y/N] " "$name" "$path" "${risks:+ ($risks)}" >&2
    local answer
    IFS= read -r answer || return 1
    case $answer in y|Y|yes|YES) ;; *) _aip_error 'deletion cancelled'; return 1 ;; esac
  fi

  default_name=$(_aip_read_name_file "$_AIP_PROFILE_ROOT/.default" 2>/dev/null) || default_name=
  rm -rf -- "$path" || return
  if [ "$default_name" = "$name" ]; then rm -f "$_AIP_PROFILE_ROOT/.default" || return; fi
  printf 'Deleted %s; ' "$path"
  if [ "$remote_configured" -eq 1 ]; then
    printf 'recoverable from its configured Git remote.\n'
  else
    printf 'no configured remote is available for recovery.\n'
  fi
}

_aip_doctor() {
  [ "$#" -le 1 ] || {
    _aip_error 'usage: aip doctor [NAME]'
    return 2
  }
  _aip_resolve_profile "${1-}" || return
  local path link pair expected errors=0 harness
  path=$(_aip_profile_path "$_AIP_RESOLVED_NAME")
  if [ -L "$path" ]; then printf 'ERROR: profile path must not be a symbolic link\n'; errors=1; fi
  command -v git >/dev/null 2>&1 || { printf 'ERROR: Git was not found\n'; errors=1; }
  git var GIT_AUTHOR_IDENT >/dev/null 2>&1 || { printf 'ERROR: configure Git user.name and user.email\n'; errors=1; }
  git -C "$path" status --porcelain >/dev/null 2>&1 || { printf 'ERROR: profile Git repository is unreadable\n'; errors=1; }

  for pair in 'claude/skills:../skills' 'codex/AGENTS.md:../AGENTS.md' 'codex/skills:../skills' 'pi/AGENTS.md:../AGENTS.md' 'pi/skills:../skills' 'opencode/AGENTS.md:../AGENTS.md' 'opencode/skills:../skills'; do
    link=${pair%%:*}
    expected=${pair#*:}
    if [ ! -L "$path/$link" ] || [ "$(readlink "$path/$link" 2>/dev/null)" != "$expected" ]; then
      printf 'ERROR: %s should link to %s\n' "$link" "$expected"
      errors=1
    fi
  done
  for link in .aip/outfit .gitignore AGENTS.md claude/CLAUDE.md codex/instructions.md pi/APPEND_SYSTEM.md; do
    if [ ! -f "$path/$link" ]; then printf 'ERROR: required file is missing: %s\n' "$link"; errors=1; fi
  done
  if [ "$errors" -eq 0 ]; then printf 'OK: profile layout and links\n'; fi

  for harness in claude codex pi opencode; do
    if _aip_find_real_command "$harness" >/dev/null 2>&1; then
      printf 'OK: %s executable found\n' "$harness"
    else
      printf 'WARN: %s executable was not found; install it before using this wrapper\n' "$harness"
    fi
  done
  [ "$errors" -eq 0 ]
}

_aip_list() {
  [ "$#" -eq 0 ] || {
    _aip_error 'usage: aip list'
    return 2
  }
  local path name outfit tags default_name= project_name= found=0
  default_name=$(_aip_read_name_file "$_AIP_PROFILE_ROOT/.default" 2>/dev/null) || default_name=
  if _aip_find_project_marker 2>/dev/null; then project_name=$_AIP_PROJECT_NAME; fi
  for path in "$_AIP_PROFILE_ROOT"/*; do
    [ -d "$path/.git" ] || continue
    name=${path##*/}
    _aip_validate_name "$name" || continue
    outfit=$(_aip_read_outfit "$path/.aip/outfit") || outfit='invalid outfit'
    tags=
    [ "${AIP_PROFILE-}" = "$name" ] && tags="$tags [session]"
    [ "$project_name" = "$name" ] && tags="$tags [project]"
    [ "$default_name" = "$name" ] && tags="$tags [default]"
    printf '%s — %s%s\n' "$name" "$outfit" "$tags"
    found=1
  done
  [ "$found" -eq 1 ] || printf 'No profiles. Create one with: aip create NAME\n'
}

_aip_git_summary() {
  local path=$1 state upstream
  if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then state=changes; else state=clean; fi
  if git -C "$path" rev-parse --verify '@{upstream}' >/dev/null 2>&1; then
    upstream=$(git -C "$path" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null) || upstream=upstream
  else
    upstream='local only'
  fi
  printf '%s, %s\n' "$state" "$upstream"
}

_aip_status() {
  [ "$#" -eq 0 ] || {
    _aip_error "unknown option '$1'"
    return 2
  }
  _aip_resolve_profile '' || return
  local path outfit harness availability
  path=$(_aip_profile_path "$_AIP_RESOLVED_NAME")
  outfit=$(_aip_read_outfit "$path/.aip/outfit") || outfit='invalid outfit'
  printf '🐵 %s — %s\n' "$_AIP_RESOLVED_NAME" "$outfit"
  printf 'Selected by: %s\nPath: %s\n' "$_AIP_RESOLVED_SOURCE" "$path"
  printf 'Git: %s' "$(_aip_git_summary "$path")"
  printf 'Harnesses:'
  for harness in claude codex pi opencode; do
    if _aip_find_real_command "$harness" >/dev/null 2>&1; then availability=available; else availability=missing; fi
    printf ' %s=%s' "$harness" "$availability"
  done
  printf '\n'
}

_aip_is_harness() {
  case ${1-} in
    claude|codex|pi|opencode) return 0 ;;
    *) return 1 ;;
  esac
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

_aip_sync_profile() {
  # The local/remote Git lifecycle is added as its own tested slice.
  return 0
}

_aip_run_harness() (
  local explicit=$1 harness=$2 profile_path real child_status instructions
  shift 2

  _aip_is_harness "$harness" || {
    _aip_error "unknown harness '$harness'; expected claude, codex, pi, or opencode"
    return 2
  }
  _aip_resolve_profile "$explicit" || return
  profile_path=$(_aip_profile_path "$_AIP_RESOLVED_NAME")
  real=$(_aip_find_real_command "$harness") || {
    _aip_error "$harness executable was not found in PATH"
    return 127
  }
  _aip_sync_profile "$profile_path" before || return

  case $harness in
    claude)
      CLAUDE_CONFIG_DIR=$profile_path/claude
      export CLAUDE_CONFIG_DIR
      "$real" "$@"
      child_status=$?
      ;;
    codex)
      CODEX_HOME=$profile_path/codex
      export CODEX_HOME
      instructions=$(cat "$profile_path/codex/instructions.md") || return
      "$real" -c "developer_instructions=$instructions" "$@"
      child_status=$?
      ;;
    pi)
      PI_CODING_AGENT_DIR=$profile_path/pi
      export PI_CODING_AGENT_DIR
      "$real" "$@"
      child_status=$?
      ;;
    opencode)
      OPENCODE_CONFIG_DIR=$profile_path/opencode
      export OPENCODE_CONFIG_DIR
      "$real" "$@"
      child_status=$?
      ;;
  esac

  _aip_sync_profile "$profile_path" after || :
  return "$child_status"
)

_aip_run() {
  [ "$#" -ge 1 ] || {
    _aip_error 'usage: aip run [NAME] HARNESS [ARGS...]'
    return 2
  }
  local explicit= harness
  if _aip_is_harness "$1"; then
    harness=$1
    shift
  else
    [ "$#" -ge 2 ] || {
      _aip_error "unknown harness '$1'; expected claude, codex, pi, or opencode"
      return 2
    }
    explicit=$1
    harness=$2
    shift 2
  fi
  _aip_run_harness "$explicit" "$harness" "$@"
}

aip() {
  if [ "$#" -eq 0 ]; then
    _aip_status
    return
  fi
  local command=$1
  shift
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
    use) _aip_use "$@" ;;
    which) _aip_which "$@" ;;
    *) _aip_error "unknown command '$command'"; return 2 ;;
  esac
}

claude() {
  _aip_run_harness '' claude "$@"
}

codex() {
  _aip_run_harness '' codex "$@"
}

pi() {
  _aip_run_harness '' pi "$@"
}

opencode() {
  _aip_run_harness '' opencode "$@"
}
