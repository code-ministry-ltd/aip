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

printf 'Installed aip. Restart your shell or run: %s\n' "$source_line"
