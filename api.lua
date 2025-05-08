local http = require("socket.http")
local ltn12 = require("ltn12")
local Config = require("config")
local utils = require("utils")
local json = require("dkjson")
local Parser = require("parser")
local logger = require("logger")

local Api = {}

local function append_array_query_params(base_url, param_name, values)
    if not values or #values == 0 then
        return base_url
    end
    local params_str_parts = {}
    for i, value in ipairs(values) do
        table.insert(params_str_parts, string.format("%s[%d]=%s", param_name, i - 1, utils.escape(value)))
    end
    local separator = base_url:find("?") and "&" or "?"
    return base_url .. separator .. table.concat(params_str_parts, "&")
end

function Api.makeHttpRequest(options)
    logger.dbg("Zlibrary:Api.makeHttpRequest - START - URL: %s, Method: %s", options.url, options.method or "GET")

    local response_body_table = {}
    local result = { body = nil, status_code = nil, error = nil }

    local sink = options.sink or ltn12.sink.table(response_body_table)

    local request_params = {
        url = options.url,
        method = options.method or "GET",
        headers = options.headers,
        source = options.source,
        sink = sink,
        timeout = options.timeout or Config.REQUEST_TIMEOUT,
        redirect = options.redirect or false
    }
    logger.dbg("Zlibrary:Api.makeHttpRequest - Request Params: URL: %s, Method: %s, Timeout: %s, Redirect: %s", request_params.url, request_params.method, request_params.timeout, tostring(request_params.redirect))

    local ok, r1, r2, r3 = pcall(http.request, request_params)

    logger.dbg(string.format("Zlibrary:Api.makeHttpRequest - pcall result: ok=%s, r1=%s (type %s), r2=%s (type %s), r3=%s (type %s)",
        tostring(ok), tostring(r1), type(r1), tostring(r2), type(r2), tostring(r3), type(r3)))

    local final_status_code
    local status_text

    if not ok then
        result.error = "Network request failed: " .. tostring(r1)
        logger.err("Zlibrary:Api.makeHttpRequest - END (pcall error) - Error: %s", result.error)
        return result
    end

    if request_params.redirect then
        if type(r1) == "number" and r1 >= 0 and type(r2) == "number" then
             final_status_code = r2
        else
            if type(r1) == "number" then
                final_status_code = r1
            else
                 result.error = "Unexpected http.request result with redirect=true: " .. tostring(r1)
                 logger.err("Zlibrary:Api.makeHttpRequest - END (unexpected redirect result) - Error: %s", result.error)
                 return result
            end
        end
    else
        final_status_code = r1
        status_text = r3
    end

    result.status_code = final_status_code

    if not options.sink then
        result.body = table.concat(response_body_table)
    end

    if final_status_code ~= 200 then
        result.error = string.format("HTTP Error: %s (%s)", final_status_code, status_text or "Unknown Status")
    end

    logger.dbg("Zlibrary:Api.makeHttpRequest - END - Status: %s, Error: %s", result.status_code, tostring(result.error))
    return result
end

function Api.login(email, password)
    logger.info("Zlibrary:Api.login - START")
    local result = { user_id = nil, user_key = nil, error = nil }

    local rpc_url = Config.getRpcUrl()
    if not rpc_url then
        result.error = "The Zlibrary server address (URL) is not set. Please configure it in the Zlibrary plugin settings."
        logger.err("Zlibrary:Api.login - END (Configuration error) - Error: %s", result.error)
        return result
    end

    local body_data = {
        isModal = "true",
        email = email,
        password = password,
        site_mode = "books",
        action = "login",
        gg_json_mode = "1"
    }
    local body_parts = {}
    for k, v in pairs(body_data) do
        table.insert(body_parts, utils.escape(k) .. "=" .. utils.escape(v))
    end
    local body = table.concat(body_parts, "&")

    local http_result = Api.makeHttpRequest{
        url = rpc_url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8",
            ["Accept"] = "application/json, text/javascript, */*; q=0.01",
            ["User-Agent"] = Config.USER_AGENT,
            ["X-Requested-With"] = "XMLHttpRequest",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        redirect = true,
    }

    if http_result.error then
        result.error = "Login request failed: " .. http_result.error
        logger.err("Zlibrary:Api.login - END (HTTP error) - Error: %s", result.error)
        return result
    end

    local data, _, err_msg = json.decode(http_result.body)

    if not data or type(data) ~= "table" then
        result.error = "Login failed: Invalid response format. " .. (err_msg or "")
        logger.err("Zlibrary:Api.login - END (JSON error) - Error: %s", result.error)
        return result
    end

    local session = data.response or {}
    local user_id = tostring(session.user_id or "")
    local user_key = session.user_key or ""

    if user_id == "" or user_key == "" then
        result.error = "Login failed: " .. (session.message or "Credentials rejected or invalid response.")
        logger.warn("Zlibrary:Api.login - END (Credentials error) - Error: %s", result.error)
        return result
    end

    result.user_id = user_id
    result.user_key = user_key
    logger.info("Zlibrary:Api.login - END (Success) - UserID: %s", result.user_id)
    return result
end

function Api.search(query, user_id, user_key, languages, extensions, page)
    logger.info("Zlibrary:Api.search - START - Query: %s, Page: %s", query, tostring(page))
    local result = { results = nil, total_count = nil, error = nil }

    local base_url = Config.getBaseUrl()
    if not base_url then
        result.error = "The Zlibrary server address (URL) is not set. Please configure it in the Zlibrary plugin settings." -- Updated
        logger.err("Zlibrary:Api.search - END (Configuration error) - Error: %s", result.error)
        return result
    end

    local search_url = Config.getSearchUrl(query)
    if not search_url then -- This will be nil if base_url was nil
        result.error = "Could not construct the Zlibrary search address. Please verify the Zlibrary URL in the plugin settings." -- Updated
        logger.err("Zlibrary:Api.search - END (Configuration error) - Error: %s", result.error)
        return result
    end

    local headers = {
        ["User-Agent"] = Config.USER_AGENT,
        ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
        ["Accept-Language"] = "en-US,en;q=0.5",
        ["Referer"] = base_url .. "/",
    }
    if user_id and user_key then
        headers["Cookie"] = string.format("remix_userid=%s; remix_userkey=%s", user_id, user_key)
    end

    search_url = append_array_query_params(search_url, "languages", languages)
    search_url = append_array_query_params(search_url, "extensions", extensions)

    search_url = search_url .. (search_url:find("?") and "&" or "?") .. "content_type=book"

    if page and page > 1 then
        search_url = search_url .. "&page=" .. tostring(page)
    end

    logger.dbg("Zlibrary:Api.search - Final Search URL: %s", search_url)

    local http_result = Api.makeHttpRequest{
        url = search_url,
        method = "GET",
        headers = headers,
        redirect = true,
    }

    if http_result.error then
        result.error = "Search request failed: " .. http_result.error
        logger.err("Zlibrary:Api.search - END (HTTP error) - Error: %s", result.error)
        return result
    end

    local parsed = Parser.parseSearchResults(http_result.body)

    if parsed.error then
        result.error = parsed.error
        logger.err("Zlibrary:Api.search - END (Parse error) - Error: %s", result.error)
        return result
    end

    result.results = parsed.results
    result.total_count = parsed.total_count
    logger.info("Zlibrary:Api.search - END (Success) - Found results: %d, Total: %s", #result.results, tostring(result.total_count))
    return result
end

function Api.downloadBook(download_url, target_filepath, user_id, user_key, referer_url)
    logger.info("Zlibrary:Api.downloadBook - START - URL: %s, Target: %s", download_url, target_filepath)
    local result = { success = false, error = nil }
    local file, err_open = io.open(target_filepath, "wb")
    if not file then
        result.error = "Failed to open target file: " .. (err_open or "Unknown error")
        logger.err("Zlibrary:Api.downloadBook - END (File open error) - Error: %s", result.error)
        return result
    end

    local headers = { ["User-Agent"] = Config.USER_AGENT }
    if user_id and user_key then
        headers["Cookie"] = string.format("remix_userid=%s; remix_userkey=%s", user_id, user_key)
    end
    if referer_url then
        headers["Referer"] = referer_url
    end

    local http_result = Api.makeHttpRequest{
        url = download_url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.file(file),
        timeout = 300,
        redirect = true
    }

    if http_result.error or http_result.status_code ~= 200 then
        result.error = "Download failed: " .. (http_result.error or string.format("HTTP Error: %s", http_result.status_code))
        pcall(os.remove, target_filepath)
        logger.err("Zlibrary:Api.downloadBook - END (Download error) - Error: %s", result.error)
        return result
    else
        result.success = true
        logger.info("Zlibrary:Api.downloadBook - END (Success)")
        return result
    end
end

return Api
