#!/usr/bin/env bash
# Tracked shell entrypoint for local and fm-on extension binding commands.
set -eu
set -o pipefail

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/fm-remote-endpoint-lib.sh
. "$SCRIPT_DIR/fm-remote-endpoint-lib.sh"
fm_remote_endpoint_command_options "$@" || exit 2
shift "$FM_REMOTE_COMMAND_OPTION_COUNT"
fm_remote_endpoint_command_guard || exit 1
if [ "${1:-}" = remote-bind ]; then
  [ "$#" -ge 4 ] || { printf 'usage: %s remote-bind <secondmate-id> <package-root> <bind-options...>\n' "$0" >&2; exit 2; }
  route=$2
  package_root=$3
  shift 3
  "$SCRIPT_DIR/fm-extension.mjs" pack-transfer "$package_root" \
    | "$SCRIPT_DIR/fm-on.sh" --stdin "$route" fm-extension.sh receive-transfer-bind "$@"
  exit $?
fi
exec "$SCRIPT_DIR/fm-extension.mjs" "$@"
