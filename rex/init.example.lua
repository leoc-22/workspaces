-- Example ~/.config/rex/init.lua. The README's install command fills in
-- this repository's path below.
package.path = "/path/to/workspaces/rex/?.lua;" .. package.path
require("workspaces").setup{
  yq = "/opt/homebrew/bin/yq",
  zoxide = "/opt/homebrew/bin/zoxide",
  -- shell = "/opt/homebrew/bin/fish", -- leave unset to use your login shell
}
rex.bind("cmd+shift+o", "workspace")
