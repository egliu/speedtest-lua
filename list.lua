--[[
Copyright (c) 2018 Eric Liu.
All Rights Reserved.
--]]

local _M = {};
_M.version = "1.0";

local mt = { __index = _M };

function _M.new(self)
    return setmetatable({first=1, last=0}, mt)
end

function _M.push(self, value)
    self.last = self.last + 1;
    self[self.last] = value;
end

function _M.pop(self)
    if _M.empty(self) then
        error(l"list is empty");
    else
        local value = self[self.first];
        self[self.first] = nil;
        self.first = self.first + 1;
        return value;
    end
end

function _M.empty(self)
    if self.first > self.last then
        return true;
    else
        return false;
    end
end

return _M;