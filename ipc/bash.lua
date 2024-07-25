#!/usr/bin/lua
local posix = require 'posix'
local subprocess = require 'subprocess'
local posix_wait = require 'posix.sys.wait'
local tempdir = require 'file.util.tempdir'
local path = require 'path'
local lfs = require 'lfs'

--local file = io.open('ipc_bash.sh', 'r')
--CONST_BASH_PROGRAM = file:read("*a")
--file:close()
local charset = (function ()
    local ret = {'_'}
    local b = string.byte('a')
    local g = string.byte('A')
    local d = string.byte('0')
    for i = 0,25 do
        ret[#ret+1] = string.char(b+i)
        ret[#ret+1] = string.char(g+i)
        if i < 10 then
            ret[#ret+1] = string.char(d+i)
        end
    end
    return ret
end)()

local function random_chars(len)
    local bytes = {}
    for _ = 1, len do
        bytes[_] = charset[math.random(1, #charset)]
    end
    return table.concat(bytes)
end

local function sh_str(value)
    if value
    then
        value = '' .. value
    else
        value = ''
    end
    return '"'..value:gsub("\\", "\\\\"):gsub('"','\\"'):gsub('`','\\`'):gsub('%$', '\\$')..'"'
end

local BASHKEY = 'F' .. random_chars(12) .. '_'
local BASHPROG = string.gsub([[

Tbr_temp="${Tbr_temp:-.}"

Tbr_loop "w$$p"

]], 'Tbr_', BASHKEY)

local IPC_Bash = {}
IPC_Bash.__index = IPC_Bash
IPC_Bash.sh_str = sh_str
IPC_Bash.BASH_PROGRAM = BASHPROG
IPC_Bash.BASH_SECRET_KEY = BASHKEY

local FormatMetatable = {}
function FormatMetatable:__tostring()
    return self.str:gsub(self.fmt, IPC_Bash.BASH_SECRET_KEY)
end

local function createBuiltInMetatable(builtin_str)
    local meta = {
        __tostring = function (self)
            return builtin_str:gsub('tpr_', IPC_Bash.BASH_SECRET_KEY):gsub('eval', self.name)
        end
    }
    return setmetatable({}, {
        __index = function(self, command)
            return setmetatable({name=command}, meta)
        end,
        __newindex = function(self, name, value) end
    })
end

local builtin = createBuiltInMetatable([[

tpr_unset
builtin command -p eval "${@}"
return $?
]])



local levelup = createBuiltInMetatable([[

tpr_retcode "0"
eval "$0" -c "
$(tpr_save_state)
tpr_loop
"
]])

IPC_Bash.builtin = builtin
IPC_Bash.levelup = levelup

function IPC_Bash.bash_code(code, override)
    if (nil == override)
    then
        return code
    else
        if not (type(code) == 'string')
        then
            return code
        end
        return setmetatable({
            fmt = override,
            str = code
        }, FormatMetatable)
    end
end

function IPC_Bash.extend_bash_program(...)
    local bashtable = {}
    local length = 0
    local bashkey = IPC_Bash.BASH_SECRET_KEY
    local parm={...}
    for i=1,#parm do
        local functable = parm[i]
        if type(functable) == 'table'
        then
            for name, code in pairs(functable)
            do
                length = length + 1
                bashtable[length] = bashkey..name..[[(){
]]..tostring(code)..[[
}
]]
            end
        end
    end
    if not (length == 0)
    then
        IPC_Bash.BASH_PROGRAM = table.concat(bashtable) .. IPC_Bash.BASH_PROGRAM
    end
end

function IPC_Bash.bash_code_table(pattern, bashprogtable)
    bashprog = setmetatable(
{},
{['__newindex']=function(self, name, code)
    code = IPC_Bash.bash_code(code, pattern)
    rawset(self, name, code)
end
})
    if type(bashprogtable) == 'table'
    then
        for key, value in pairs(bashprogtable)
        do
            bashprog[key] = value
        end
    end
    return bashprog
end

local bashprog = IPC_Bash.bash_code_table('Tbr_')

bashprog.fakeroot = levelup.fakeroot
bashprog.sudo = levelup.sudo
bashprog.write = builtin.echo
bashprog.read = builtin.read
bashprog.eval = builtin.eval
bashprog.kill = builtin.kill
bashprog.touch = builtin.touch
bashprog.typeset = builtin.typeset
bashprog.unset = builtin.unset
bashprog.edit = builtin.sed
bashprog.getopts = builtin.getopts

bashprog.echo = [[

   Tbr_write -n "${@}" > "${Tbr_temp}/output.sock" &
]]

bashprog.pwrite = [[
(
if (( $# == 0 ))
then
    Tbr_read -N 1073741824
    Tbr_write -n "$REPLY"
else
    for Tbr_file in "${@}"
    do
        Tbr_read -N 1073741824 < "$Tbr_file"
        Tbr_write -n "$REPLY"
    done
fi
)
]]

bashprog.cat = [[
    Tbr_pwrite > "${Tbr_temp}/output.sock" &
]]

bashprog.retcode = [[

   Tbr_write "$1" > "${Tbr_temp}/retcode.sock"
]]

bashprog.recv = [[
   Tbr_pwrite < "${Tbr_temp}/input.sock"
]]

bashprog.echo_node = [[

   for Tbr_i in "${@}"
   do
      Tbr_write "${#Tbr_i}"
      Tbr_write -n "${Tbr_i}"
      Tbr_write
   done
]]

bashprog.echo_value = [[

   Tbr_eval "Tbr_echo_node \"\$${1}\""
]]

bashprog.echo_array = [[

   Tbr_eval "Tbr_write \"\${#${1}[@]}\""
   Tbr_eval "Tbr_echo_node \"\${${1}[@]}\""
]]

bashprog.echo_table = [[

   Tbr_eval "Tbr_write \"\${#${1}[@]}\""
   Tbr_eval "
for Tbr_i in \"\${!${1}[@]}\"; do
Tbr_echo_node \"\${Tbr_i}\" \"\${${1}[\"\${Tbr_i}\"]}\";
done"
]]

bashprog.unset = [[

    POSIXLY_CORRECT=1
    unset builtin
]]

bashprog.exit = [[

   Tbr_touch "${Tbr_temp}/exit.lock"
   exit $(("$1"))
]]

bashprog.subsh = [[
    Tbr_retcode "0"
    Tbr_loop
]]

bashprog.loop = [[

(
   while (( "1" ))
   do
      (
         while (( "1" ))
         do
            Tbr_eval "$(Tbr_recv)"
            Tbr_retcode "$?"
         done
      )
      if [[ -f "${Tbr_temp}/exit.lock" ]]..']]'..[[ ;
      then
        rm  "${Tbr_temp}/exit.lock"
        break
      fi
      Tbr_retcode "$?"
   done
)
Tbr_retcode "${1}${?}"
]]

bashprog.save_state = [[
  (
  for Tbr_i in $(Tbr_get_all_vars -fr -uBASH_ARGC -uBASH_ARGV -uBASH_LINENO -uBASH_SOURCE -uBASH_VERSIONINFO -uFUNCNAME -uGROUPS -uBASHPID -uBASH_EXECUTION_STRING -uBASH_SUBSHELL -uBASH_COMMAND -uOPTIND -uOPTERR -uOPTARG -uBASH_VERSINFO -uBASHOPTS -uBASH_VERSINFO -uEUID -uPPID -uSHELLOPTS -uUID )
  do
    Tbr_typeset -p "$Tbr_i"
  done
  Tbr_typeset -f
  ) 2>/dev/null
]]

bashprog.get_all_vars = [[

  Tbr_unset OPTIND OPTERR OPTARG getopts
  Tbr_include_flags=""
  Tbr_exclude_flags=""
  Tbr_include_vars=""
  Tbr_exclude_vars=":Tbr_exclude_vars::Tbr_include_vars::Tbr_exclude_flags::Tbr_include_flags:"
  while getopts 's:u:t:f:' Tbr_flg
  do
    case "${Tbr_flg}" in
       s) Tbr_include_vars="${Tbr_include_vars}:${OPTARG}:" ;;
       u) Tbr_exclude_vars="${Tbr_exclude_vars}:${OPTARG}:" ;;
       t) Tbr_include_flags="${Tbr_include_flags}${OPTARG}" ;;
       f) Tbr_exclude_flags="${Tbr_exclude_flags}${OPTARG}" ;;
    esac
  done

  (
    declare(){
      Tbr_echo_typeset "${@}"
    }

    typeset(){
      Tbr_echo_typeset "${@}"
    }

    _(){
       :
    }

    Tbr_Tbr_Tbr_value="$(Tbr_typeset -p)"
    eval "{
        ${Tbr_Tbr_Tbr_value}
    }"
  ) 2>/dev/null
]]

bashprog.echo_typeset = [[
  Tbr_flags=""
  Tbr_unset getopts OPTIND eval echo
  while getopts 'aAilnrtux' Tbr_flg
  do
    if [[ "${Tbr_exclude_flags}" =~ "${Tbr_flgexit}" ]]..']]'..[[ ;
    then
        return
    fi
    Tbr_flags="${Tbr_flags}${Tbr_flg}"
  done

  Tbr_key="$(eval "echo \${$((OPTIND-1))}" | Tbr_edit -r 's/([^=]*).*/\1/')"

  if [[ "${Tbr_exclude_vars}" =~ ":${Tbr_key}:" ]]..']]'..[[ ;
  then
    return
  fi

  if [[ -n "${Tbr_include_vars}" ]]..']]'..[[ ;
  then
    if [[ ! "${Tbr_include_vars}" =~ ":${Tbr_key}:" ]]..']]'..[[ ;
    then
      return
    fi
  fi

  if [[ -n "${Tbr_include_flags}" ]]..']]'..[[ ;
  then
    for (( Tbr_i=0; Tbr_i<${#Tbr_include_flags}; Tbr_i++ ))
    do
      flg="${Tbr_include_flags:${Tbr_i}:1}"
      if [[ ! "${Tbr_flags}" =~ "${Tbr_flg}" ]]..']]'..[[ ;
      then
        return
      fi
    done
  fi

  echo ${Tbr_key}
]]

IPC_Bash.extend_bash_program(bashprog)

local function open_and_read(self, func, funcname, name)
    self:runcmd(self.BASH_SECRET_KEY..'echo_'..funcname..' '..sh_str(name)..' | '..self.BASH_SECRET_KEY..'cat')
    local file = io.open(self.output, 'r')
    local ret = func(file)
    file:close()
    return ret
end

local function read_value(file)
   local ret = file:read(tonumber(file:read("*l")))
   assert(string.byte(file:read(1)) == 10 )
   return ret
end

local function read_array(file)
   local array = {}
   local arraylen = tonumber(file:read("*l"))
   for i = 1,arraylen do
      array[i] = read_value(file)
   end
   return array
end

local function read_table(file)
   local array = {}
   local arraylen = tonumber(file:read("*l"))
   for i = 1,arraylen do
      local key = read_value(file)
      local value = read_value(file)
      array[key] = value
   end
   return array
end

IPC_Bash.read_value = read_value
IPC_Bash.read_table = read_table
IPC_Bash.read_array = read_array

local function get_value(self, name)
    return open_and_read(self, read_value, 'value', name)
end

local function get_array(self, name)
    return open_and_read(self, read_array, 'array', name)
end

local function get_table(self, name)
    return open_and_read(self, read_table, 'table', name)
end

IPC_Bash.random_ascii_chars = random_chars
IPC_Bash.shell_string = sh_str

function IPC_Bash:fix_shell()
    return self:runcmd(self.BASH_SECRET_KEY .. 'unset')
end

function IPC_Bash.newShell(tab)
    if nil == tab
    then
      tab = {}
    end
    local self = setmetatable(tab, IPC_Bash)
    if nil == self.bash
    then
      self.bash = 'bash'
    end
  --  self.temp = nil
  --  self.pid = nil
  --  self.input = nil
  --  self.output = nil
  --  self.bash = nil
  --  self.thread = nil
  --  self.lockcmd = nil
    return self
end

function IPC_Bash.key()
    return IPC_Bash.BASH_SECRET_KEY
end

function IPC_Bash:exit()
    return self:runcmd(self.BASH_SECRET_KEY .. 'exit')
end

function IPC_Bash:subsh()
    return self:runcmd(self.BASH_SECRET_KEY .. 'subsh')
end

function IPC_Bash:join()
    return self.thread:join()
end

--function IPC_Bash:getallvars()
--    return self:execfunc(BASH_SECRET_KEY .. 'allvars')
--end

function IPC_Bash:flush()
    local hd1 = io.open(self.input, 'w+')
    hd1:write('')
    hd1:close()
    local hd2 = io.open(self.output, 'w+')
    hd2:write('')
    hd2:close()
end

function IPC_Bash:fakeroot()
    return self:runcmd(self.BASH_SECRET_KEY..'fakeroot')
end

function IPC_Bash:sudo()
    return self:runcmd(self.BASH_SECRET_KEY..'sudo')
end

function IPC_Bash:close()
    if self.pid then
        posix.kill(self.pid)
        self:flush()
        self.pid = nil
        self.proc = nil
  --      self.thread:join()
  --      self.thread = nil
    end
end

function IPC_Bash:open()
    if nil == self.pid then
        local temp = tempdir.get_user_tempdir()
        temp = path.join(temp, random_chars(15))
        local input = path.join(temp, 'input.sock')
        local output = path.join(temp, 'output.sock')
        local retcode = path.join(temp, 'retcode.sock')
        self.temp = temp
        lfs.mkdir(temp)
        self.input = input
        self.output = output
        self.retcode = retcode
        posix.mkfifo(input)
        posix.mkfifo(output)
        posix.mkfifo(retcode)
        local bash = self.bash
        local proc = subprocess.popen( { bash, '-c', self.BASH_PROGRAM, env={[self.BASH_SECRET_KEY..'temp']=temp} } )
        self.proc = proc
        self.pid = proc.pid
 --       self.thread = coroutine.create(function()
 --           posix_wait.wait(proc.pid)
 --           self:flush()
 --           self:close()
 --       end)
 --       coroutine.resume(self.thread)
    end
end

function IPC_Bash:init()
--    local mutex = self.lockcmd
--    mutex:lock()
    self:open()
    return self
--    mutex:unlock()
end

function IPC_Bash:source(path)
    return self:runcmd('. ' .. sh_str(path))
end

function IPC_Bash:runcmd_capture(data)
    self:runcmd(self.BASH_SECRET_KEY..'echo "$('..data..')"')
    return self:recv()
end

function IPC_Bash:runcmd(data)
--    local mutex = self.lockcmd
--    mutex:lock()
    self:open()
    self:send(data)
    local file = io.open(self.retcode, 'r')
    local result = file:read("*l")
    file:close()
    if result:sub(1,1) == 'w'
    then
        local pind = result:find('p')
        local pid = tonumber(result:sub(2, pind-1))
        local result = result:sub(pind+1)
        if self.pid == pid
        then
            self.proc:wait()
            self.pid = nil
        end
    end
--    mutex:unlock()
    return tonumber(result)
end

local function shell_table(argtab)
    local tab = {}
    for k, v in ipairs(argtab)
    do
        tab[k] = sh_str(v)
    end
    return table.concat(tab, ' ')
end

function IPC_Bash:execfunc(argtab)
    return self:runcmd(shell_table(argtab))
end

function IPC_Bash:execfunc_capture(argtab)
    return self:runcmd_capture(shell_table(argtab))
end

function IPC_Bash:send(data)
    local file = io.open(self.input, 'w')
    file:write(data)
    file:close()
end

function IPC_Bash:recv()
    local file = io.open(self.output, 'r')
    local data = file:read('*a')
    file:close()
    return data
end

function IPC_Bash:setvar(name, value, type)
    return self:runcmd(IPC_Bash.bash_format(name, value, type))
end

function IPC_Bash:getvar(name, type)
    type = IPC_Bash.type_format(type)
    local ret;
    if type.isvalue
    then
        ret = get_value(self, name)
        if type.isnumber
        then
            ret = tonumber(ret) or 0
        end
    else
        if type.ismap
        then
            ret = get_table(self, name)
        else
            ret = get_array(self, name)
        end
        if type.isnumber
        then
            for k, v in pairs(ret)
            do
                ret[k] = tonumber(v) or 0
            end
        end
    end
    return ret
end

function IPC_Bash.type_format(type)
    if type
    then
        local is_int = string.find(type, 'i')
        local is_hash = string.find(type, 'A')
        local is_list = string.find(type, 'a') and (not is_hash)
        local is_var = (not is_hash) and (not is_list)
        return {
            isnumber = is_int,
            ismap = is_hash,
            isarray = is_list,
            isvalue = is_var
        }
    else
        return {
            isnumber = false,
            ismap = false,
            isarray = false,
            isvalue = true
        }
    end
end

function IPC_Bash.bash_format(name, value, vartype)
    local vartype = IPC_Bash.type_format(vartype)
    local subr = vartype.isnumber and function(v) return tostring(tonumber(v)) end or sh_str
    local list = {'typeset '}
    if vartype.ismap then
        table.insert(list, '-A ')
        table.insert(list, name)
        table.insert(list, '=(')
        if type(value) == 'table' then
            if next(value) then
                for k, v in pairs(value) do
                    table.insert(list, ' [')
                    table.insert(list, sh_str(k))
                    table.insert(list, ']=')
                    table.insert(list, subr(v))
                end
            else
                table.insert(list, " ['0']=")
                table.insert(list, subr(value))
            end
        else
            table.insert(list, " ['0']=")
            table.insert(list, subr(value))
        end
        table.insert(list, ' )')
    elseif vartype.isarray then
        table.insert(list, '-a ')
        table.insert(list, name)
        table.insert(list, '=(')
        local value1 = type(value) == 'table' and value or {value}
        for _, v in ipairs(value1) do
            table.insert(list, ' ')
            table.insert(list, subr(v))
        end
        table.insert(list, ' )')
    else
        table.insert(list, name)
        table.insert(list, '=')
        table.insert(list, subr(value))
    end
    return table.concat(list)
end

return IPC_Bash

