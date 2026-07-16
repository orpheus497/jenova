local ffi = require("ffi")
ffi.cdef[[
    int access(const char *pathname, int mode);
]]
if ffi.C.access("/does/not/exist", 0) ~= 0 then
    print("errno:", ffi.errno())
end
