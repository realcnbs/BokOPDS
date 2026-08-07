local ffi = require("ffi")
local ffiutil = require("ffi/util")

local SubprocessGuard = {}

if ffi.os == "Linux" then
    ffi.cdef[[
        int prctl(int option, unsigned long arg2, unsigned long arg3,
            unsigned long arg4, unsigned long arg5);
    ]]
end

function SubprocessGuard.install()
    if ffi.os ~= "Linux" then return end
    local parent_pid = tonumber(ffi.C.getpid())
    ffiutil.addRunInSubProcessAfterForkFunc("bokopds_parent_death", function()
        -- PR_SET_PDEATHSIG=1. A hard parent crash must not leave a download or
        -- feed worker writing after BokOPDS has released its application lock.
        if ffi.C.prctl(1, 9, 0, 0, 0) ~= 0 or
                tonumber(ffi.C.getppid()) ~= parent_pid then
            ffi.C._exit(125)
        end
    end)
end

return SubprocessGuard
