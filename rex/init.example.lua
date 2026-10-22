-- Example ~/.config/rex/init.lua. The README's install command fills in
-- this repository's path below.
package.path = "/path/to/tmux-workspaces/rex/?.lua;" .. package.path
require("tmux_workspaces").setup{
  yq = "/opt/homebrew/bin/yq",
  zoxide = "/opt/homebrew/bin/zoxide",
}
rex.bind("cmd+shift+o", "workspace")
