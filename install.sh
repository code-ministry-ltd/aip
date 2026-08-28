#!/usr/bin/env bash
set -euo pipefail

script_directory=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source_file=$script_directory/aip.sh
install_root=${_AIP_INSTALL_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/aip}

if [[ -n ${_AIP_SHELL_PROFILE:-} ]]; then
  shell_profile=$_AIP_SHELL_PROFILE
else
  case ${SHELL##*/} in
    bash)
      if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
        if [ -e "$HOME/.bash_profile" ]; then shell_profile=$HOME/.bash_profile
        elif [ -e "$HOME/.bash_login" ]; then shell_profile=$HOME/.bash_login
        elif [ -e "$HOME/.profile" ]; then shell_profile=$HOME/.profile
        else shell_profile=$HOME/.bash_profile
        fi
      else shell_profile=$HOME/.bashrc
      fi
      ;;
    zsh) shell_profile=$HOME/.zshrc ;;
    *)
      printf 'aip: supported login shells are Bash and Zsh; set SHELL correctly and retry\n' >&2
      exit 1
      ;;
  esac
fi

installed_file=$install_root/aip.sh
package_version=$(sed -n "s/^_AIP_VERSION='\(.*\)'$/\1/p" "$source_file" | head -n 1)
[ -n "$package_version" ] || { printf 'aip: cannot read the package version from %s\n' "$source_file" >&2; exit 1; }
previous_version=''
if [ -f "$install_root/VERSION" ]; then
  previous_version=$(head -n 1 "$install_root/VERSION" 2>/dev/null || true)
fi
printf 'aip will install: %s\n' "$installed_file"
printf 'aip will update:  %s\n' "$shell_profile"

mkdir -p "$install_root" "$(dirname -- "$shell_profile")"
cp "$source_file" "$installed_file"
chmod 0644 "$installed_file"
touch "$shell_profile"

escaped_source=${installed_file//\'/\'\\\'\'}
source_line=". '$escaped_source'"
if grep -Fqx '# >>> aip >>>' "$shell_profile"; then
  if ! grep -Fqx "$source_line" "$shell_profile" || ! grep -Fqx '# <<< aip <<<' "$shell_profile"; then
    printf 'aip: an existing aip profile block is not recognised; remove it manually and retry\n' >&2
    exit 1
  fi
else
  {
    if [[ -s $shell_profile ]]; then printf '\n'; fi
    printf '%s\n' '# >>> aip >>>' "$source_line" '# <<< aip <<<'
  } >>"$shell_profile"
fi

printf '%s\n' "$package_version" >"$install_root/VERSION"

# --- aip profile + management skill -------------------------------------------
# Creates the 'aip' profile (skeleton committed via aip create) and
# (re)installs the management skill, marker-managed. Never commits, syncs, or
# pushes: the skill files land untracked and the next checkpoint or 'aip sync'
# commits them. Skipped with a warning when Git or the identity is missing.
setup_aip_profile_and_skill() {
  local profile_root skill_src skill_dest marker
  if ! command git --version >/dev/null 2>&1; then
    printf 'aip: warning: Git was not found, so the aip profile and management skill were not set up. Install Git and re-run the installer.\n' >&2
    return 0
  fi
  if [ -z "$(command git config --get user.name 2>/dev/null)" ] || [ -z "$(command git config --get user.email 2>/dev/null)" ]; then
    printf 'aip: warning: Git has no user.name or user.email, so the aip profile and management skill were not set up. Configure both (git config --global user.name / user.email) and re-run the installer.\n' >&2
    return 0
  fi
  profile_root=${_AIP_PROFILE_ROOT:-$HOME/agent-profiles}
  skill_src=$script_directory/skills/aip
  skill_dest=$profile_root/aip/skills/aip
  marker=$skill_dest/.aip-managed
  if [ ! -d "$profile_root/aip" ]; then
    (
      export _AIP_PROFILE_ROOT=$profile_root
      . "$installed_file"
      _AIP_CREATE_SKIP_SKILL_SELECTION=1 aip create aip
    ) || {
      printf 'aip: warning: could not create the aip profile; run: aip create aip\n' >&2
      return 0
    }
  fi
  if [ -f "$marker" ]; then
    # Managed skill: replace the directory contents from the package (user
    # edits to a managed skill are overwritten — documented behaviour).
    command rm -rf -- "$skill_dest" || return 0
  elif [ -e "$skill_dest" ] || [ -L "$skill_dest" ]; then
    printf 'aip: note: %s exists without the .aip-managed marker; leaving it untouched.\n' "$skill_dest"
    return 0
  fi
  [ -d "$skill_src" ] || {
    printf 'aip: warning: the aip management skill is missing from the package at %s\n' "$skill_src" >&2
    return 0
  }
  command mkdir -p -- "$skill_dest" || return 0
  command cp -R -- "$skill_src/." "$skill_dest/" || return 0
  printf 'aip %s — installed by the aip installer; re-run the installer or aip update to refresh\n' "$package_version" >"$marker"
  printf 'Set up the aip profile with the aip management skill (untracked until your next aip sync). Launch a harness with it: aip manage pi\n'
}
setup_aip_profile_and_skill

# Retire legacy primary-config links immediately after replacing the script, so
# the first `aip update` from an older installation completes the migration.
(
  export _AIP_PROFILE_ROOT="${_AIP_PROFILE_ROOT:-$HOME/agent-profiles}"
  . "$installed_file"
  _aip_migrate_legacy_primary_config_links
) || :

if [ -n "$previous_version" ] && [ "$previous_version" != "$package_version" ]; then
  printf 'Updated aip from %s to %s. Restart your shell or run: %s\n' "$previous_version" "$package_version" "$source_line"
elif [ -n "$previous_version" ]; then
  printf 'aip %s is already installed. Restart your shell or run: %s\n' "$package_version" "$source_line"
else
  printf 'Installed aip %s. Restart your shell or run: %s\n' "$package_version" "$source_line"
fi
