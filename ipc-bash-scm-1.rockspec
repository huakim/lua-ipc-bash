
package = 'ipc-bash'
version = 'scm-1'

source = {
  url = "git://github.com/huakim/lua-ipc-bash",
 }
description = {
  detailed = "  ",
  homepage = "https://github.com/huakim/lua-ipc-bash",
  license = "LGPL",
  summary = "Inter process communications between shell session and lua script",
 }
build = {
  modules = {
   ["ipc.bash"] = "ipc/bash.lua",
  },
  type = "builtin",
 }
dependencies = {
  "lua >= 5.1",
  'luaposix',
  'subprocess',
  'file-util-tempdir',
  'lua-path',
  'luafilesystem',
 }
