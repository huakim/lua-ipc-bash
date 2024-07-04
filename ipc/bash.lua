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
   return '"'..value:gsub("\\", "\\\\"):gsub('"','\\"'):gsub('`','\\`'):gsub('%$', '\\$')..'"'
end

local BASH_SECRET_KEY = 'F' .. random_chars(12) .. '_'
local BASH_PROGRAM = string.gsub([[

Tbr_temp="${Tbr_temp:-.}"

Tbr_echo(){
   /bin/echo -n "${@}" > "${Tbr_temp}/output.sock" &
}

Tbr_cat(){
   /bin/cat > "${Tbr_temp}/output.sock" &
}

Tbr_retcode(){
   /bin/echo "$1" > "${Tbr_temp}/retcode.sock"
}

Tbr_recv(){
   /bin/cat "${Tbr_temp}/input.sock"
}

Tbr_echo_node(){
   for i in "${@}"
   do
      echo "${#i}"
      echo -n "${i}"
      echo
   done
}

Tbr_echo_value(){
   eval "Tbr_echo_node \"\$${1}\""
}

Tbr_echo_array(){
   eval "echo \"\${#${1}[@]}\""
   eval "Tbr_echo_node \"\${${1}[@]}\""
}

Tbr_echo_table(){
   eval "echo \"\${#${1}[@]}\""
   eval "
for i in \"\${!${1}[@]}\"; do
Tbr_echo_node \"\${i}\" \"\${${1}[\"\${i}\"]}\";
done"
}

Tbr_unset(){
    POSIXLY_CORRECT=1
    unset eval
    unset builtin
}

Tbr_exit(){
   /bin/kill -SIGTERM "${Tbr_PID}"
}

Tbr_loop(){
(
   Tbr_PID=${BASHPID}
   while (( "1" ))
   do
      (
         while (( "1" ))
         do
            eval "$(Tbr_recv)"
            Tbr_retcode "$?"
            Tbr_unset
         done
      )
   done
)
}

Tbr_loop


]], 'Tbr_', BASH_SECRET_KEY)

local IPC_Bash = {}
IPC_Bash.__index = IPC_Bash
IPC_Bash.sh_str = sh_str
IPC_Bash.BASH_PROGRAM = BASH_PROGRAM
IPC_Bash.BASH_SECRET_KEY = BASH_SECRET_KEY

local function open_and_read(self, func, funcname, name)
    self:runcmd(BASH_SECRET_KEY..'echo_'..funcname..' '..sh_str(name)..' | '..BASH_SECRET_KEY..'cat')
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

function IPC_Bash.newShell(tab)
    if nil == tab
    then
      tab = {}
    end
    local self = setmetatable(tab, IPC_Bash)
    if nil == self.bash
    then
      self.bash = 'ksh'
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
    return BASH_SECRET_KEY
end

function IPC_Bash:exit()
    return self:runcmd(BASH_SECRET_KEY .. 'exit')
end

function IPC_Bash:subsh()
    return self:runcmd(BASH_SECRET_KEY .. 'loop')
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
    if not self.pid then
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
        local proc = subprocess.popen( { bash, '-c', BASH_PROGRAM, env={[BASH_SECRET_KEY..'temp']=temp} } )
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
    self:runcmd(BASH_SECRET_KEY..'echo "$('..data..')"')
    return self:recv()
end

function IPC_Bash:runcmd(data)
--    local mutex = self.lockcmd
--    mutex:lock()
    self:open()
    self:send(data)
    local file = io.open(self.retcode, 'r')
    local result = tonumber(file:read("*l"))
    file:close()
--    mutex:unlock()
    return result
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
            ret = tonumber(ret)
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

function IPC_Bash.bash_format(name, value, type)
    local type = IPC_Bash.type_format(type)
    local subr = type.isnumber and function(v) return tostring(tonumber(v)) end or sh_str
    local list = {'typeset '}
    if type.ismap then
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
    elseif type.isarray then
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

