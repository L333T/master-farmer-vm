-- ============================================================================
-- Marty Nav - json.lua
-- Small JSON decoder for the nav server's answers (objects, arrays, strings,
-- numbers, true/false/null). Returns value or nil, error.
-- ============================================================================

local json = {}

local function skip(s, i)
    local _, e = s:find("^[ \t\r\n]*", i)
    return e + 1
end

local decode_value

local ESC = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function decode_string(s, i)
    -- s:sub(i, i) == '"'
    local out, j = {}, i + 1
    while true do
        local c = s:sub(j, j)
        if c == "" then error("unterminated string at " .. i) end
        if c == '"' then return table.concat(out), j + 1 end
        if c == "\\" then
            local n = s:sub(j + 1, j + 1)
            if n == "u" then
                local hex = s:sub(j + 2, j + 5)
                local code = tonumber(hex, 16) or 63
                out[#out + 1] = code < 128 and string.char(code) or "?"
                j = j + 6
            else
                out[#out + 1] = ESC[n] or n
                j = j + 2
            end
        else
            out[#out + 1] = c
            j = j + 1
        end
    end
end

local function decode_number(s, i)
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if not num or num == "" then error("bad number at " .. i) end
    return tonumber(num), i + #num
end

local function decode_array(s, i)
    local out = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "]" then return out, i + 1 end
    while true do
        local v
        v, i = decode_value(s, i)
        out[#out + 1] = v
        i = skip(s, i)
        local c = s:sub(i, i)
        if c == "]" then return out, i + 1 end
        if c ~= "," then error("expected , or ] at " .. i) end
        i = skip(s, i + 1)
    end
end

local function decode_object(s, i)
    local out = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "}" then return out, i + 1 end
    while true do
        if s:sub(i, i) ~= '"' then error("expected key at " .. i) end
        local k
        k, i = decode_string(s, i)
        i = skip(s, i)
        if s:sub(i, i) ~= ":" then error("expected : at " .. i) end
        local v
        v, i = decode_value(s, skip(s, i + 1))
        out[k] = v
        i = skip(s, i)
        local c = s:sub(i, i)
        if c == "}" then return out, i + 1 end
        if c ~= "," then error("expected , or } at " .. i) end
        i = skip(s, i + 1)
    end
end

decode_value = function(s, i)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "{" then return decode_object(s, i) end
    if c == "[" then return decode_array(s, i) end
    if c == '"' then return decode_string(s, i) end
    if s:sub(i, i + 3) == "true" then return true, i + 4 end
    if s:sub(i, i + 4) == "false" then return false, i + 5 end
    if s:sub(i, i + 3) == "null" then return nil, i + 4 end
    return decode_number(s, i)
end

---@return any value, string|nil err
function json.decode(s)
    if type(s) ~= "string" then return nil, "not a string" end
    local ok, v = pcall(decode_value, s, 1)
    if not ok then return nil, tostring(v) end
    return v
end

return json
