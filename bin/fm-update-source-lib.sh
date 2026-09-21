# shellcheck shell=bash
# Resolve the canonical source used by /updatefirstmate.
#
# The optional gitignored config/update-source file contains exactly one Git
# clone URL and one trailing newline. When present, that URL is fetched directly;
# no remote name is trusted as an alias for it. When absent, updates follow the
# canonical kunchenguid repository. A configured source that is malformed,
# unsafe, or unreachable is a hard update skip, never a reason to fall back.
#
# Usage: . bin/fm-update-source-lib.sh; fm_update_source_resolve <config-dir>
# Sets:
#   FM_UPDATE_SOURCE_MODE=url|invalid
#   FM_UPDATE_SOURCE_URL=<resolved URL, empty when invalid>
#   FM_UPDATE_SOURCE_ERROR=<diagnostic, empty on success>

# shellcheck source=bin/fm-project-origin-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-project-origin-lib.sh"

FM_DEFAULT_UPDATE_SOURCE_URL=https://github.com/kunchenguid/firstmate.git
FM_UPDATE_SOURCE_MODE=
FM_UPDATE_SOURCE_URL=
FM_UPDATE_SOURCE_ERROR=

fm_update_source_resolve() { # <config-dir>
  local config_dir=$1 path value
  path="$config_dir/update-source"
  FM_UPDATE_SOURCE_MODE=invalid
  FM_UPDATE_SOURCE_URL=
  FM_UPDATE_SOURCE_ERROR=

  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    FM_UPDATE_SOURCE_MODE=url
    FM_UPDATE_SOURCE_URL=$FM_DEFAULT_UPDATE_SOURCE_URL
    return 0
  fi
  if [ ! -f "$path" ] || [ -L "$path" ]; then
    FM_UPDATE_SOURCE_ERROR="config/update-source must be a regular non-symlink file"
    return 1
  fi
  if ! value=$(perl -0777 -ne 'if (/\A([^\r\n]+)\n\z/) { print $1; exit 0 } exit 1' -- "$path"); then
    FM_UPDATE_SOURCE_ERROR="config/update-source must contain one URL followed by one newline"
    return 1
  fi
  if ! fm_project_origin_safe "$value"; then
    FM_UPDATE_SOURCE_ERROR="config/update-source is not an accepted Git URL"
    return 1
  fi
  FM_UPDATE_SOURCE_MODE=url
  FM_UPDATE_SOURCE_URL=$value
}
