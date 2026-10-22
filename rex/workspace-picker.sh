#!/bin/sh
# Picks a directory under each root with fzf and opens it with the workspace
# action. The workspace_picker action runs this in a floating pane.
#
# Usage: workspace-picker.sh <client-id> <root>...

client="$1"
shift

pick="$(
  for root in "$@"; do
    find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null
  done | sort | sed "s|^$HOME/|~/|" | fzf --prompt='workspace> ' --reverse --border=none
)" || exit 0

if ! rex ${client:+-C "$client"} do workspace dir="$pick"; then
  printf '\nPress Return to close.'
  read -r _
fi
