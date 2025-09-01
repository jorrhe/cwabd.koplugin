local Config = require("zlibrary.config")
local util = require("util")
local logger = require("logger")
local json = require("json")
local ltn12 = require("ltn12")
local http = require("socket.http")
local socketutil = require("socketutil")
local T = require("zlibrary.gettext")

local Api = {}

function Api.isAuthenticationError(error_message)
    if not error_message then
        return false
    end

    local error_str = tostring(error_message)

    if string.find(error_str, "Please login", 1, true) ~= nil or
       string.find(error_str, "Invalid credentials", 1, true) ~= nil then
        return true
    end


    if string.find(error_str, "Download limit reached", 1, true) ~= nil then
        return true
    end

    return false
end

local function _transformApiBookData(api_book,queue_status)
    if not api_book or type(api_book) ~= "table" then
        return nil
    end
    return {
        id = api_book.id,
        hash = api_book.id,
        title = util.trim(api_book.title or "Unknown Title"),
        author = util.trim(api_book.author or "Unknown Author"),
        year = api_book.year or "N/A",
        format = api_book.format or "N/A",
        size = api_book.size or api_book.filesize or "N/A",
        lang = api_book.language or "N/A",
        rating = "N/A",
        href = "",
        download = "",
        cover = api_book.preview,
        description = "",
        publisher = api_book.publisher,
        series = "",
        pages = 0,
        queue_status = queue_status,
        progress = api_book.progress,
        identifier = api_book.id,
    }
end

function Api.makeHttpRequest(options)
    logger.info(string.format("CWABD:Api.makeHttpRequest - START - URL: %s, Method: %s", options.url, options.method or "GET"))

    local response_body_table = {}
    local result = { body = nil, status_code = nil, error = nil, headers = nil }

    local sink_to_use = options.sink
    if not sink_to_use then
        response_body_table = {}
        sink_to_use = socketutil.table_sink(response_body_table)
    end

    if options.timeout then
        if type(options.timeout) == "table" then
            socketutil:set_timeout(options.timeout[1], options.timeout[2])
            logger.info(string.format("CWABD:Api.makeHttpRequest - Setting timeout to %s/%s seconds", options.timeout[1], options.timeout[2]))
        else
            socketutil:set_timeout(options.timeout)
            logger.info(string.format("CWABD:Api.makeHttpRequest - Setting timeout to %s seconds", options.timeout))
        end
    end

    local headers = options.headers
    local credentials = Config.getCredentials()

    if credentials.username and credentials.password then
        local creds = string.format("%s:%s",credentials.username,credentials.password)
        headers["Authorization"] = string.format("Basic %s",b64encode(creds))
    end

    local request_params = {
        url = options.url,
        method = options.method or "GET",
        headers = headers,
        sink = sink_to_use,
        redirect = true,
    }

    logger.info(string.format("CWABD:Api.makeHttpRequest - Request Params: URL: %s, Method: %s, Timeout: %s", request_params.url, request_params.method, tostring(options.timeout)))

    local req_ok, r_val, r_code, r_headers_tbl, r_status_str = pcall(http.request, request_params)

    if options.timeout then
        socketutil:reset_timeout()
        logger.info("CWABD:Api.makeHttpRequest - Reset timeout to default")
    end

    logger.info(string.format("CWABD:Api.makeHttpRequest - pcall result: ok=%s, r_val=%s (type %s), r_code=%s (type %s), r_headers_tbl type=%s, r_status_str=%s",
        tostring(req_ok), tostring(r_val), type(r_val), tostring(r_code), type(r_code), type(r_headers_tbl), tostring(r_status_str)))

    if not req_ok then
        local error_msg = tostring(r_val)
        if string.find(error_msg, "timeout") or
           string.find(error_msg, "wantread") or
           string.find(error_msg, "closed") or
           string.find(error_msg, "connection") or
           string.find(error_msg, "sink timeout") then
            result.error = T("Request timed out - please check your connection and try again")
        else
            result.error = T("Network request failed") .. ": " .. error_msg
        end
        logger.err(string.format("CWABD:Api.makeHttpRequest - END (pcall error) - Error: %s", result.error))
        return result
    end

    result.status_code = r_code
    result.headers = r_headers_tbl

    if not options.sink then
        result.body = table.concat(response_body_table)
    end

    if type(result.status_code) ~= "number" then
        local status_str = tostring(result.status_code)
        if string.find(status_str, "wantread") or
           string.find(status_str, "timeout") or
           string.find(status_str, "closed") or
           string.find(status_str, "sink timeout") then
            result.error = T("Request timed out - please check your connection and try again")
        else
            result.error = T("Network connection error - please check your internet connection and try again")
        end
        logger.err(string.format("CWABD:Api.makeHttpRequest - END (Invalid response code type) - Error: %s", result.error))
        return result
    end

    if result.status_code ~= 200 and result.status_code ~= 206 then
        if not result.error then
            result.error = string.format("%s: %s (%s)", T("HTTP Error"), result.status_code, r_status_str or T("Unknown Status"))
        end
    end

    logger.info(string.format("CWABD:Api.makeHttpRequest - END - Status: %s, Headers found: %s, Error: %s",
        result.status_code, tostring(result.headers ~= nil), tostring(result.error)))
    return result
end

function Api.verify(email, password)
    logger.info(string.format("CWABD:Api.verify - START"))
    local result = { user_id = nil, user_key = nil, error = nil }

    local url = Config.getStatusUrl()

    if not url then
        result.error = T("The CWABD address (URL) is not set. Please configure it in the CWA Book Downloader plugin settings.")
        logger.err(string.format("CWABD:Api.verify - END (Configuration error) - Error: %s", result.error))
        return result
    end

    local headers = {
        ["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8",
        ["Accept"] = "application/json, text/javascript, */*; q=0.01",
        ["User-Agent"] = Config.USER_AGENT,
    }

    if email and password then
        local creds = string.format("%s:%s",email,password)
        headers["Authorization"] = string.format("Basic %s",b64encode(creds))
    end

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = headers,
        timeout = Config.getLoginTimeout(),
    }

    logger.info(string.format("CWABD:Api.verify - HEADERS: %s", headers["Authentication"]))

    if http_result.error then
        result.error = http_result.error
        logger.err(string.format("CWABD:Api.verify - END (HTTP error) - Error: %s", result.error))
        return result
    end

    local data, _, err_msg = json.decode(http_result.body)

    if not data or type(data) ~= "table" then
        result.error = T("Login failed: Invalid response format") .. (err_msg and (". " .. err_msg) or "")
        logger.err(string.format("CWABD:Api.verify - END (JSON error) - Error: %s", result.error))
        return result
    end


    logger.info(string.format("CWABD:Api.verify - END (Success) - UserID: %s", result.user_id))
    return result
end

function Api.search(query, user_id, user_key, languages, extensions, order, page)
    logger.info(string.format("CWABD:Api.search - START - Query: %s, Page: %s", query, tostring(page)))
    local result = { results = nil, total_count = nil, error = nil }

    local search_url = Config.getSearchUrl()
    if not search_url then
        result.error = T("The CWABD server address (URL) is not set. Please configure it in the Z-library plugin settings.")
        logger.err(string.format("CWABD:Api.search - END (Configuration error) - Error: %s", result.error))
        return result
    end

    local body_data_parts = {}
    table.insert(body_data_parts, "query=" .. util.urlEncode(query or ""))

    if languages and #languages > 0 then
        for _, lang in ipairs(languages) do
            table.insert(body_data_parts, string.format("lang=%s", util.urlEncode(lang)))
        end
    end
    if extensions and #extensions > 0 then
        for i, ext in ipairs(extensions) do
            table.insert(body_data_parts, string.format("format=%s", util.urlEncode(ext)))
        end
    end

    if order and #order > 0 then
        for i, ord in ipairs(order) do
            table.insert(body_data_parts, "sort=" .. util.urlEncode(ord))
        end
    end

    local url_query_params = table.concat(body_data_parts, "&")

    if user_id and user_key then
        headers["Cookie"] = string.format("remix_userid=%s; remix_userkey=%s", user_id, user_key)
    end

    logger.info(string.format("CWABD:Api.search - Request URL: %s, Params: %s", search_url, url_query_params))

    local http_result = Api.makeHttpRequest{
        url = string.format("%s?%s",search_url, url_query_params),
        method = "GET",
        headers = {
            ["User-Agent"] = Config.USER_AGENT,
            ["Accept"] = "application/json, text/javascript, */*; q=0.01",
            ["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8",
        },
        source = "",
        timeout = Config.getSearchTimeout(),
    }

    if http_result.error then
        result.error = http_result.error
        result.status_code = http_result.status_code
        logger.err(string.format("CWABD:Api.search - END (HTTP error) - Error: %s, Status: %s", result.error, tostring(result.status_code)))
        return result
    end

    if not http_result.body then
        result.error = T("No response received from server - please try again")
        logger.err(string.format("CWABD:Api.search - END (Empty body) - Error: %s", result.error))
        return result
    end

    local data, _, err_msg = json.decode(http_result.body)

    if not data or type(data) ~= "table" then
        result.error = T("Invalid response format from server") .. (err_msg and (": " .. err_msg) or "")
        logger.err(string.format("CWABD:Api.search - END (JSON error) - Error: %s, Body: %s, Type:%s", result.error, http_result.body, type(data)))
        return result
    end

    if data.error then
        result.error = T("Search API error") .. ": " .. (data.error.message or data.error)
        logger.warn(string.format("CWABD:Api.search - END (API error in response) - Error: %s", result.error))
        return result
    end

    local books_from_api = {}
    if type(data) == "table" then
        books_from_api = data
    end

    local transformed_books = {}
    if #books_from_api > 0 then
        for _, api_book_item in ipairs(books_from_api) do
            local transformed_book = _transformApiBookData(api_book_item)
            if transformed_book then
                table.insert(transformed_books, transformed_book)
            else
                logger.warn("CWABD:Api.search - Failed to transform an API book item, skipping.")
            end
        end
    end
    result.results = transformed_books

    if data.pagination and data.pagination.total_items then
        result.total_count = tonumber(data.pagination.total_items)
    elseif data.exactBooksCount then -- Fallback for exact match count
        result.total_count = tonumber(data.exactBooksCount)
    elseif #transformed_books > 0 and not result.total_count then
        logger.warn("CWABD:Api.search - Total count not found in API response pagination or exactBooksCount.")
    end

    logger.info(string.format("CWABD:Api.search - END (Success) - Found %d results, Total reported: %s", #result.results, tostring(result.total_count)))
    return result
end

function Api.downloadBook(download_url)
    logger.info(string.format("CWABD:Api.downloadBook - START - URL: %s", download_url))

    local result = { success = false, error = nil }

    local headers = { ["User-Agent"] = Config.USER_AGENT }

    local http_result = Api.makeHttpRequest{
        url = download_url,
        method = "GET",
        headers = headers,
        timeout = Config.getDownloadTimeout(),
    }

    if http_result.error and not (http_result.status_code and http_result.headers) then
        result.error = http_result.error
        logger.err(string.format("CWABD:Api.downloadBook - END (Request error) - Error: %s", result.error))
        return result
    end

    local data, _, err_msg = json.decode(http_result.body)

    if not data or type(data) ~= "table" then
        result.error = T("Invalid response format from server") .. (err_msg and (": " .. err_msg) or "")
        logger.err(string.format("CWABD:Api.downloadBook - END (JSON error) - Error: %s, Body: %s, Type:%s", result.error, http_result.body, type(data)))
        return result
    else
        result.success = true
        logger.info(string.format("CWABD:Api.downloadBook - END (Success)"))
        return result
    end
end

function Api.downloadBookCover(download_url, target_filepath)
    logger.info(string.format("CWABD:Api.downloadBookCover - START - URL: %s, Target: %s", download_url, target_filepath))
    local result = { success = false, error = nil }
    local file, err_open = io.open(target_filepath, "wb")
    if not file then
        result.error = T("Failed to open target file") .. ": " .. (err_open or T("Unknown error"))
        logger.err(string.format("CWABD:Api.downloadBookCover - END (File open error) - Error: %s", result.error))
        return result
    end

    local headers = { ["User-Agent"] = Config.USER_AGENT }

    local http_result = Api.makeHttpRequest{
        url = download_url,
        method = "GET",
        headers = headers,
        sink = socketutil.file_sink(file),
        timeout = Config.getCoverTimeout(),
    }

    if http_result.error and not (http_result.status_code and http_result.headers) then
        result.error = http_result.error
        pcall(os.remove, target_filepath)
        logger.err(string.format("CWABD:Api.downloadBookCover - END (Request error) - Error: %s", result.error))
        return result
    end

    if http_result.error then
        result.error = http_result.error
        pcall(os.remove, target_filepath)
        logger.err("CWABD:Api.downloadBookCover - END (HTTP error from Api.makeHttpRequest) - Error: " .. result.error .. ", Status: " .. tostring(http_result.status_code))
        return result
    end

    if http_result.status_code ~= 200 then
        result.error = string.format("%s: %s", T("Download HTTP Error"), http_result.status_code)
        pcall(os.remove, target_filepath)
        logger.err("CWABD:Api.downloadBookCover - END (HTTP status error) - Error: " .. result.error)
        return result
    end

    logger.info("CWABD:Api.downloadBookCover - END (Success)")
    result.success = true
    return result
end

function Api.getDownloadQueue()
    local url = Config.getDownloadQueueUrl()
    if not url then
        logger.warn("Api.getDownloadQueue - Base URL not configured")
        return { error = T("CWA Book Downloader server URL not configured.") }
    end

    local headers = {
        ['Content-Type'] = 'application/x-www-form-urlencoded',
        ["User-Agent"] = Config.USER_AGENT,
    }

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = headers,
        timeout = Config.getPopularTimeout(),
    }

    if http_result.error then
        logger.warn("Api.getDownloadQueue - HTTP request error: ", http_result.error)
        return { error = http_result.error }
    end

    if not http_result.body then
        logger.warn("Api.getDownloadQueue - No response body")
        return { error = T("Failed to fetch download queue (no response body).") }
    end

    local success, data = pcall(json.decode, http_result.body)
    if not success or not data then
        logger.warn("Api.getDownloadQueue - Failed to decode JSON: ", http_result.body)
        return { error = T("Failed to parse queue download response.") }
    end

    local transformed_books = {}

    for queue_status, queue_data in pairs(data) do
        for _,book_data in pairs(queue_data) do
            local transformed_book = _transformApiBookData(book_data,queue_status)
            if transformed_book then
                table.insert(transformed_books, transformed_book)
            else
                logger.warn("Api.getDownloadQueue - Failed to transform book data: ", book_data.id)
            end
        end

    end

    return { books = transformed_books }
end

function Api.cancelDownload(book_id)
    local url = Config.getCancelDownloadUrl(book_id)
    if not url then
        logger.warn("Api.cancelDownload - Base URL not configured")
        return { error = T("CWA Book Downloader server URL not configured.") }
    end

    local headers = {
        ['Content-Type'] = 'application/x-www-form-urlencoded',
        ["User-Agent"] = Config.USER_AGENT,
    }

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "DELETE",
        headers = headers,
        timeout = Config.getPopularTimeout(),
    }

    if http_result.error then
        logger.warn("Api.cancelDownload - HTTP request error: ", http_result.error)
        return { error = http_result.error }
    end

    if not http_result.body then
        logger.warn("Api.cancelDownload - No response body")
        return { error = T("Failed to cancel download.") }
    end

    local success, data = pcall(json.decode, http_result.body)
    if not success or not data then
        logger.warn("Api.cancelDownload - Failed to decode JSON: ", http_result.body)
        return { error = T("Failed to parse cancel download response.") }
    end

    return { success = true }
end

function Api.restart()
    local url = Config.getRestartUrl()
    if not url then
        logger.warn("Api.cancelDownload - Base URL not configured")
        return { error = T("CWA Book Downloader server URL not configured.") }
    end

    local headers = {
        ['Content-Type'] = 'application/x-www-form-urlencoded',
        ["User-Agent"] = Config.USER_AGENT,
    }

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = headers,
        timeout = Config.getPopularTimeout(),
    }

    return { success = true }
end

function Api.getBookDetails(user_id, user_key, book_id, book_hash)
    local url = Config.getBookDetailsUrl(book_id, book_hash)
    if not url then
        logger.warn("Api.getBookDetails - URL could not be constructed. Base URL configured? Book ID/Hash provided?")
        return { error = T("CWABD server URL not configured or book identifiers missing.") }
    end

    local headers = {
        ["User-Agent"] = Config.USER_AGENT,
        ['Content-Type'] = 'application/x-www-form-urlencoded',
    }
    if user_id and user_key then
        headers["Cookie"] = string.format("remix_userid=%s; remix_userkey=%s", user_id, user_key)
    end

    local http_result = Api.makeHttpRequest{
        url = url,
        method = "GET",
        headers = headers,
        timeout = Config.getBookDetailsTimeout(),
    }

    if http_result.error then
        logger.warn("Api.getBookDetails - HTTP request error: ", http_result.error)
        return { error = http_result.error }
    end

    if not http_result.body then
        logger.warn("Api.getBookDetails - No response body")
        return { error = T("Failed to fetch book details (no response body).") }
    end

    local success, data = pcall(json.decode, http_result.body)
    if not success or not data then
        logger.warn("Api.getBookDetails - Failed to decode JSON: ", http_result.body)
        return { error = T("Failed to parse book details response.") }
    end

    if data.success ~= 1 or not data.book then
        logger.warn("Api.getBookDetails - API error: ", http_result.body)
        return { error = data.message or T("API returned an error for book details.") }
    end

    local transformed_book = _transformApiBookData(data.book)
    if not transformed_book then
        logger.warn("Api.getBookDetails - Failed to transform book data: ", data.book.id)
        return { error = T("Failed to process book details.") }
    end

    return { book = transformed_book }
end

local b='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/' -- You will need this for encoding/decoding
-- encoding
function b64encode(data)
    return ((data:gsub('.', function(x)
        local r,b='',x:byte()
        for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
        return r;
    end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if (#x < 6) then return '' end
        local c=0
        for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
        return b:sub(c+1,c+1)
    end)..({ '', '==', '=' })[#data%3+1])
end

return Api
