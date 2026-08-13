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
  [ -d "$profile_path/.git" ] || {
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
  local profile_path=$1 outfit=$2
  mkdir -p "$profile_path/.aip" "$profile_path/skills" "$profile_path/claude" "$profile_path/codex" "$profile_path/pi" "$profile_path/opencode" || return
  printf '%s\n' "$outfit" >"$profile_path/.aip/outfit" || return
  printf '%s\n' '# Common profile instructions' >"$profile_path/AGENTS.md" || return
  printf '%s\n' '@../AGENTS.md' '' '# Claude Code instructions' >"$profile_path/claude/CLAUDE.md" || return
  printf '%s\n' '# Codex instructions' >"$profile_path/codex/instructions.md" || return
  printf '%s\n' '# Pi instructions' >"$profile_path/pi/APPEND_SYSTEM.md" || return
  printf '%s\n' \
    '# aip-managed credential and runtime exclusions' \
    '.env' '.env.*' '!.env.example' '*.pem' '*.key' '*.p12' '*.pfx' \
    'claude/.credentials.json' 'claude/history.jsonl' 'claude/projects/' 'claude/session-env/' 'claude/shell-snapshots/' 'claude/statsig/' 'claude/todos/' 'claude/debug/' 'claude/cache/' 'claude/logs/' 'claude/file-history/' \
    'codex/auth.json' 'codex/history.jsonl' 'codex/sessions/' 'codex/archived_sessions/' 'codex/log/' 'codex/logs/' 'codex/cache/' 'codex/*.db' 'codex/*.db-*' 'codex/*.sqlite' 'codex/*.sqlite-*' \
    'pi/auth.json' 'pi/sessions/' 'pi/logs/' 'pi/cache/' \
    'opencode/auth.json' 'opencode/sessions/' 'opencode/logs/' 'opencode/cache/' \
    >"$profile_path/.gitignore" || return
  ln -s ../skills "$profile_path/claude/skills" || return
  ln -s ../AGENTS.md "$profile_path/codex/AGENTS.md" || return
  ln -s ../skills "$profile_path/codex/skills" || return
  ln -s ../AGENTS.md "$profile_path/pi/AGENTS.md" || return
  ln -s ../skills "$profile_path/pi/skills" || return
  ln -s ../AGENTS.md "$profile_path/opencode/AGENTS.md" || return
  ln -s ../skills "$profile_path/opencode/skills" || return
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
  _aip_sync_profile "$source_path" clone || return
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
  local name=${1-} force=0 profile_path risks= remote_configured=0 default_name=
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
  [ ! -L "$profile_path" ] || {
    _aip_error 'profile path must not be a symbolic link'
    return 1
  }
  [ "${AIP_PROFILE-}" != "$name" ] || {
    _aip_error "cannot delete session profile '$name'; select another profile first"
    return 1
  }
  [ "$(cd "$_AIP_PROFILE_ROOT" && pwd -P)" = "$(cd "${profile_path%/*}" && pwd -P)" ] || {
    _aip_error 'refusing to delete a profile outside the profile root'
    return 1
  }

  [ -z "$(git -C "$profile_path" status --porcelain 2>/dev/null)" ] || risks='uncommitted changes'
  _aip_has_unfinished_git_operation "$profile_path" && risks="${risks:+$risks, }unfinished Git operation"
  if git -C "$profile_path" rev-parse --verify '@{upstream}' >/dev/null 2>&1; then
    [ -z "$(git -C "$profile_path" rev-list '@{upstream}..HEAD')" ] || risks="${risks:+$risks, }unpushed commits"
  else
    risks="${risks:+$risks, }unpushed commits (no upstream)"
  fi
  [ -z "$(git -C "$profile_path" remote)" ] || remote_configured=1

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
  rm -rf -- "$profile_path" || return
  if [ "$default_name" = "$name" ]; then rm -f "$_AIP_PROFILE_ROOT/.default" || return; fi
  printf 'Deleted %s; ' "$profile_path"
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
  local profile_path link pair expected errors=0 harness
  profile_path=$(_aip_profile_path "$_AIP_RESOLVED_NAME")
  if [ -L "$profile_path" ]; then printf 'ERROR: profile path must not be a symbolic link\n'; errors=1; fi
  command -v git >/dev/null 2>&1 || { printf 'ERROR: Git was not found\n'; errors=1; }
  git var GIT_AUTHOR_IDENT >/dev/null 2>&1 || { printf 'ERROR: configure Git user.name and user.email\n'; errors=1; }
  git -C "$profile_path" status --porcelain >/dev/null 2>&1 || { printf 'ERROR: profile Git repository is unreadable\n'; errors=1; }

  for pair in 'claude/skills:../skills' 'codex/AGENTS.md:../AGENTS.md' 'codex/skills:../skills' 'pi/AGENTS.md:../AGENTS.md' 'pi/skills:../skills' 'opencode/AGENTS.md:../AGENTS.md' 'opencode/skills:../skills'; do
    link=${pair%%:*}
    expected=${pair#*:}
    if [ ! -L "$profile_path/$link" ] || [ "$(readlink "$profile_path/$link" 2>/dev/null)" != "$expected" ]; then
      printf 'ERROR: %s should link to %s\n' "$link" "$expected"
      errors=1
    fi
  done
  for link in .aip/outfit .gitignore AGENTS.md claude/CLAUDE.md codex/instructions.md pi/APPEND_SYSTEM.md; do
    if [ ! -f "$profile_path/$link" ]; then printf 'ERROR: required file is missing: %s\n' "$link"; errors=1; fi
  done
  _AIP_TEMP_PATHS=
  if ! _aip_check_tracked_forbidden "$profile_path"; then
    printf 'ERROR: remove forbidden tracked content before using this profile\n'
    errors=1
  fi
  if [ -d "$profile_path/.git/aip-sync.lock" ]; then
    local lock_pid= lock_host= current_host=
    lock_pid=$(cat "$profile_path/.git/aip-sync.lock/pid" 2>/dev/null) || lock_pid=
    lock_host=$(cat "$profile_path/.git/aip-sync.lock/host" 2>/dev/null) || lock_host=
    current_host=$(hostname 2>/dev/null) || current_host=
    case $lock_pid in
      ''|*[!0-9]*) printf 'WARN: sync lock owner is unknown; inspect %s/.git/aip-sync.lock\n' "$profile_path" ;;
      *)
        if [ "$lock_host" = "$current_host" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
          printf 'WARN: stale sync lock found; the next sync will remove it, or inspect %s/.git/aip-sync.lock\n' "$profile_path"
        else
          printf 'WARN: sync lock is owned by a live or remote process; inspect %s/.git/aip-sync.lock\n' "$profile_path"
        fi
        ;;
    esac
  fi
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
  local profile_path name outfit tags default_name= project_name= found=0
  default_name=$(_aip_read_name_file "$_AIP_PROFILE_ROOT/.default" 2>/dev/null) || default_name=
  if _aip_find_project_marker 2>/dev/null; then project_name=$_AIP_PROJECT_NAME; fi
  for profile_path in "$_AIP_PROFILE_ROOT"/*; do
    [ -d "$profile_path/.git" ] || continue
    name=${profile_path##*/}
    _aip_validate_name "$name" || continue
    outfit=$(_aip_read_outfit "$profile_path/.aip/outfit") || outfit='invalid outfit'
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
  local profile_path=$1 state upstream
  if [ -n "$(git -C "$profile_path" status --porcelain 2>/dev/null)" ]; then state=changes; else state=clean; fi
  if git -C "$profile_path" rev-parse --verify '@{upstream}' >/dev/null 2>&1; then
    upstream=$(git -C "$profile_path" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null) || upstream=upstream
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
  local profile_path outfit harness availability
  profile_path=$(_aip_profile_path "$_AIP_RESOLVED_NAME")
  outfit=$(_aip_read_outfit "$profile_path/.aip/outfit") || outfit='invalid outfit'
  printf '🐵 %s — %s\n' "$_AIP_RESOLVED_NAME" "$outfit"
  printf 'Selected by: %s\nPath: %s\n' "$_AIP_RESOLVED_SOURCE" "$profile_path"
  printf 'Git: %s' "$(_aip_git_summary "$profile_path")"
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

_aip_is_forbidden_path() {
  case $1 in
    .env.example|*/.env.example) return 1 ;;
    .env|.env.*|*/.env|*/.env.*|*.pem|*/*.pem|*.key|*/*.key|*.p12|*/*.p12|*.pfx|*/*.pfx) return 0 ;;
    claude/.credentials.json|claude/history.jsonl|claude/projects|claude/projects/*|claude/session-env|claude/session-env/*|claude/shell-snapshots|claude/shell-snapshots/*|claude/statsig|claude/statsig/*|claude/todos|claude/todos/*|claude/debug|claude/debug/*|claude/cache|claude/cache/*|claude/logs|claude/logs/*|claude/file-history|claude/file-history/*) return 0 ;;
    codex/auth.json|codex/history.jsonl|codex/sessions|codex/sessions/*|codex/archived_sessions|codex/archived_sessions/*|codex/log|codex/log/*|codex/logs|codex/logs/*|codex/cache|codex/cache/*|codex/*.db|codex/*.db-*|codex/*.sqlite|codex/*.sqlite-*) return 0 ;;
    pi/auth.json|pi/sessions|pi/sessions/*|pi/logs|pi/logs/*|pi/cache|pi/cache/*) return 0 ;;
    opencode/auth.json|opencode/sessions|opencode/sessions/*|opencode/logs|opencode/logs/*|opencode/cache|opencode/cache/*) return 0 ;;
    claude/node_modules/*|codex/node_modules/*|pi/node_modules/*|opencode/node_modules/*) return 0 ;;
    *) return 1 ;;
  esac
}

_aip_validate_sync_layout() {
  local profile_path=$1 pair link expected file
  for pair in 'claude/skills:../skills' 'codex/AGENTS.md:../AGENTS.md' 'codex/skills:../skills' 'pi/AGENTS.md:../AGENTS.md' 'pi/skills:../skills' 'opencode/AGENTS.md:../AGENTS.md' 'opencode/skills:../skills'; do
    link=${pair%%:*}
    expected=${pair#*:}
    [ -L "$profile_path/$link" ] && [ "$(readlink "$profile_path/$link" 2>/dev/null)" = "$expected" ] || {
      _aip_error "required profile file or link is missing or invalid: $link"
      return 1
    }
  done
  for file in .aip/outfit .gitignore AGENTS.md claude/CLAUDE.md codex/instructions.md pi/APPEND_SYSTEM.md; do
    [ -f "$profile_path/$file" ] || {
      _aip_error "required profile file or link is missing or invalid: $file"
      return 1
    }
  done
}

_aip_remove_stale_lock() {
  local lock=$1 pid host current_host
  [ -f "$lock/pid" ] && [ -f "$lock/host" ] || return 1
  pid=$(cat "$lock/pid" 2>/dev/null) || return 1
  host=$(cat "$lock/host" 2>/dev/null) || return 1
  current_host=$(hostname 2>/dev/null) || return 1
  case $pid in ''|*[!0-9]*) return 1 ;; esac
  [ "$host" = "$current_host" ] || return 1
  kill -0 "$pid" 2>/dev/null && return 1
  rm -rf -- "$lock"
}

_aip_acquire_lock() {
  local profile=$1 attempts=${_AIP_LOCK_ATTEMPTS-100} attempt=0 pid host timestamp
  case $attempts in ''|*[!0-9]*) attempts=100 ;; esac
  [ "$attempts" -gt 0 ] || attempts=1
  _AIP_SYNC_LOCK=$profile/.git/aip-sync.lock
  while [ "$attempt" -lt "$attempts" ]; do
    if mkdir "$_AIP_SYNC_LOCK" 2>/dev/null; then
      sh -c 'printf "%s\n" "$PPID"' >"$_AIP_SYNC_LOCK/pid" || return 1
      pid=$(cat "$_AIP_SYNC_LOCK/pid") || return 1
      host=$(hostname 2>/dev/null) || return 1
      timestamp=$(date +%s) || return 1
      _AIP_SYNC_TOKEN="$pid-$timestamp-${RANDOM-0}"
      printf '%s\n' "$host" >"$_AIP_SYNC_LOCK/host" || return 1
      printf '%s\n' "$timestamp" >"$_AIP_SYNC_LOCK/timestamp" || return 1
      printf '%s\n' "$_AIP_SYNC_TOKEN" >"$_AIP_SYNC_LOCK/token" || return 1
      return 0
    fi
    _aip_remove_stale_lock "$_AIP_SYNC_LOCK" && continue
    attempt=$((attempt + 1))
    [ "$attempt" -lt "$attempts" ] && sleep 0.1
  done
  _aip_error "sync is already running for $profile; inspect $_AIP_SYNC_LOCK"
  return 1
}

_aip_release_lock() {
  [ -n "${_AIP_SYNC_LOCK-}" ] && [ -d "$_AIP_SYNC_LOCK" ] || return 0
  [ "$(cat "$_AIP_SYNC_LOCK/token" 2>/dev/null)" = "${_AIP_SYNC_TOKEN-}" ] || return 0
  rm -rf -- "$_AIP_SYNC_LOCK"
}

_aip_sync_cleanup() {
  if [ -n "${_AIP_TEMP_PATHS-}" ] && [ -f "$_AIP_TEMP_PATHS" ]; then rm -f "$_AIP_TEMP_PATHS"; fi
  if [ -n "${_AIP_GIT_OUTPUT-}" ] && [ -f "$_AIP_GIT_OUTPUT" ]; then rm -f "$_AIP_GIT_OUTPUT"; fi
  _aip_release_lock
}

_aip_check_tracked_forbidden() {
  local profile=$1 relative
  _AIP_TEMP_PATHS=$(mktemp "${TMPDIR:-/tmp}/aip-paths.XXXXXX") || return
  git -C "$profile" ls-files -z >"$_AIP_TEMP_PATHS" || return
  while IFS= read -r -d '' relative; do
    if _aip_is_forbidden_path "$relative"; then
      rm -f "$_AIP_TEMP_PATHS"
      _AIP_TEMP_PATHS=
      _aip_error "forbidden credential or runtime path is tracked; inspect with 'git -C \"$profile\" ls-files' and remove it with 'git rm --cached PATH'"
      return 1
    fi
  done <"$_AIP_TEMP_PATHS"
  rm -f "$_AIP_TEMP_PATHS"
  _AIP_TEMP_PATHS=
}

_aip_check_untracked_skills() {
  local profile=$1 relative
  _AIP_TEMP_PATHS=$(mktemp "${TMPDIR:-/tmp}/aip-paths.XXXXXX") || return
  git -C "$profile" ls-files --others --exclude-standard -z -- skills >"$_AIP_TEMP_PATHS" || return
  while IFS= read -r -d '' relative; do
    if _aip_is_forbidden_path "$relative"; then
      rm -f "$_AIP_TEMP_PATHS"
      _AIP_TEMP_PATHS=
      _aip_error 'forbidden credential path exists under skills/; remove or ignore it before syncing'
      return 1
    fi
  done <"$_AIP_TEMP_PATHS"
  rm -f "$_AIP_TEMP_PATHS"
  _AIP_TEMP_PATHS=
}

_aip_stage_checkpoint() {
  local profile=$1 mode=$2
  _aip_check_tracked_forbidden "$profile" || return
  _aip_check_untracked_skills "$profile" || return
  git -C "$profile" add -u -- . || return
  git -C "$profile" add -- .aip/outfit .gitignore AGENTS.md skills claude/CLAUDE.md claude/skills codex/AGENTS.md codex/instructions.md codex/skills pi/AGENTS.md pi/APPEND_SYSTEM.md pi/skills opencode/AGENTS.md opencode/skills || return
  if ! git -C "$profile" diff --cached --quiet --; then
    git -C "$profile" commit -q -m "aip: checkpoint ($mode)" || {
      _aip_error 'could not commit the local checkpoint; check Git identity and hooks'
      return 1
    }
    printf 'Checkpointed local profile changes.\n'
  fi
}

_aip_sync_profile() (
  local profile=$1 mode=${2-manual} upstream branch remote
  _AIP_SYNC_LOCK=
  _AIP_SYNC_TOKEN=
  _AIP_TEMP_PATHS=
  _AIP_GIT_OUTPUT=
  _aip_validate_sync_layout "$profile" || return
  _aip_acquire_lock "$profile" || return
  trap '_aip_sync_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  if _aip_has_unfinished_git_operation "$profile" || [ -n "$(git -C "$profile" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
    _aip_error "Git conflict or unfinished operation in $profile; run 'git -C \"$profile\" status', then resolve and continue or abort it"
    return 1
  fi
  _aip_stage_checkpoint "$profile" "$mode" || return

  if ! git -C "$profile" rev-parse --verify '@{upstream}' >/dev/null 2>&1; then
    printf 'Profile is local only (no upstream).\n'
    return 0
  fi

  upstream=$(git -C "$profile" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}') || return
  branch=$(git -C "$profile" branch --show-current) || return
  remote=$(git -C "$profile" config --get "branch.$branch.remote") || remote=
  _AIP_GIT_OUTPUT=$(mktemp "$profile/.git/aip-git.XXXXXX") || return
  if [ -z "$remote" ] || ! GIT_TERMINAL_PROMPT=0 LC_ALL=C git -C "$profile" fetch --quiet "$remote" >"$_AIP_GIT_OUTPUT" 2>&1; then
    _aip_error 'remote sync unavailable; using the committed local profile and retrying next time'
    return 0
  fi
  if ! LC_ALL=C git -C "$profile" rebase "$upstream" >"$_AIP_GIT_OUTPUT" 2>&1; then
    if _aip_has_unfinished_git_operation "$profile" || [ -n "$(git -C "$profile" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
      _aip_error "Git conflict in $profile; no side was chosen. Run 'git -C \"$profile\" status', resolve files, then use 'git rebase --continue' or 'git rebase --abort'"
    else
      _aip_error "local Git integration failed in $profile; inspect it with 'git -C \"$profile\" status'"
    fi
    return 1
  fi
  if ! GIT_TERMINAL_PROMPT=0 LC_ALL=C git -C "$profile" push --quiet >"$_AIP_GIT_OUTPUT" 2>&1; then
    _aip_error 'remote sync unavailable during push; the local checkpoint is safe and will retry next time'
    return 0
  fi
  printf 'Profile synced with %s.\n' "$upstream"
)

_aip_sync_command() {
  [ "$#" -le 1 ] || {
    _aip_error 'usage: aip sync [NAME]'
    return 2
  }
  _aip_resolve_profile "${1-}" || return
  _aip_sync_profile "$(_aip_profile_path "$_AIP_RESOLVED_NAME")" manual
}

_aip_run_harness() (
  local explicit=$1 harness=$2 profile_path real child_status instructions _AIP_CHILD_SIGNAL_STATUS=
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
  trap '_AIP_CHILD_SIGNAL_STATUS=130' INT
  trap '_AIP_CHILD_SIGNAL_STATUS=143' TERM
  trap '_AIP_CHILD_SIGNAL_STATUS=129' HUP

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

  trap - INT TERM HUP
  if [ -n "$_AIP_CHILD_SIGNAL_STATUS" ]; then child_status=$_AIP_CHILD_SIGNAL_STATUS; fi

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
    sync) _aip_sync_command "$@" ;;
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
