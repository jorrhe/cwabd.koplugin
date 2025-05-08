local utils = {}

function utils.escape(str)
    return str:gsub("([^%w%-_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

function utils.trim(str)
    return str:match("^%s*(.-)%s*$")
end

return utils