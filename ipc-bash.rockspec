
package = 'ipc-bash'
version = '0.0.1-1'
noarch = true
source = {
  url = "git://github.com/huakim/lua-ipc-bash.git",
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
  'posix',
  'subprocess',
  'file-util-tempdir',
  'lua-path',
  'luafilesystem',
 }
