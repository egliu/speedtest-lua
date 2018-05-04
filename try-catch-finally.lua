--[[
Copyright (c) 2018 Eric Liu.
All Rights Reserved.
--]]

local _M = {};
_M.version = "1.0";

local functionType = "function";

function _M.try(tryBlock, ...)
    local status = true;
    local err = nil;
    local args = {...}

    if type(tryBlock) == functionType then
        status, err = xpcall(function() tryBlock(unpack(args)) end, debug.traceback);
    end

    local finally = function(finallyBlock, catchBlockDeclared)
        if type(finallyBlock) == functionType then
            finallyBlock();
        end

        if not catchBlockDeclared and not status then
            error(err);
        end
    end

    local catch = function (catchBlock)
        local catchBlockDeclared = (type(catchBlock) == functionType);

        if not status and catchBlockDeclared then
            local ex = err or "unknown error occurred";
            catchBlock(ex);
        end

        return {
            finally = function(finallyBlock)
                finally(finallyBlock, catchBlockDeclared);
            end
        }
    end

    return {
        catch = catch,
        finally = function(finallyBlock)
            finallyBlock(finallyBlock, false);
        end
    }
end

return _M;