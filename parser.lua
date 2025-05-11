local htmlParser = require("htmlparser")
local utils = require("util")
local logger = require("logger")

local Parser = {}

function Parser.parseSearchResults(html)
    if type(html) ~= "string" or #html == 0 then
        return { results = nil, total_count = nil, error = "Empty or invalid HTML content received." }
    end

    local loopLimit = 2000
    local ok, root_or_err = pcall(htmlParser.parse, html, loopLimit)

    if not ok then
        local error_msg = "Failed to parse HTML: " .. tostring(root_or_err)
        logger.err(string.format("Zlibrary:Parser.parseSearchResults - %s", error_msg))
        return { results = nil, total_count = nil, error = error_msg }
    end

    local root = root_or_err
    if not root then
        return { results = nil, total_count = nil, error = "HTML parsing returned nil root node unexpectedly." }
    end

    local searchBox = root:select("#searchResultBox")[1]
    if not searchBox then
        logger.warn(string.format("Zlibrary:Parser.parseSearchResults - Could not find #searchResultBox element."))
        local total_count = Parser.extractTotalCount(root)
        return { results = {}, total_count = total_count, error = nil }
    end

    local total_count = Parser.extractTotalCount(root)

    local results = {}
    local loop_ok, loop_err = pcall(function()
        for _, bookcard in ipairs(searchBox:select("z-bookcard")) do
            local title_node = bookcard:select("div[slot='title']")[1]
            local author_node = bookcard:select("div[slot='author']")[1]

            local attributes = bookcard.attributes or {}
            local title = title_node and title_node:getcontent() or "Unknown Title"
            local author = author_node and author_node:getcontent() or "Unknown Author"

            table.insert(results, {
                id = attributes.id,
                title = utils.trim(title),
                author = utils.trim(author),
                year = attributes.year or "N/A",
                format = attributes.extension or "N/A",
                size = attributes.filesize or "N/A",
                lang = attributes.language or "N/A",
                rating = attributes.rating or "N/A",
                href = attributes.href,
                download = attributes.download,
            })
        end
    end)

    if not loop_ok then
        local error_msg = "Error processing book cards: " .. tostring(loop_err)
        logger.err(string.format("Zlibrary:Parser.parseSearchResults - %s", error_msg))
        return { results = nil, total_count = total_count, error = error_msg }
    end

    logger.info(string.format("Zlibrary:Parser.parseSearchResults - Successfully parsed %d results. Total count: %s", #results, tostring(total_count)))
    return { results = results, total_count = total_count, error = nil }
end

function Parser.extractTotalCount(root_node)
    if not root_node then return nil end

    local book_tab_node = root_node:select("a[data-type='book']")[1]

    if book_tab_node then
        local tab_text = book_tab_node:getcontent()
        tab_text = string.gsub(tab_text, "&nbsp;", " ")
        tab_text = utils.trim(tab_text)

        logger.dbg(string.format("Zlibrary:Parser.extractTotalCount - Found book tab text: %s", tab_text))

        local count_str = string.match(tab_text, "%((%d+)+?%s*%+?%)")

        if count_str then
            local count = tonumber(count_str)
            if count then
                logger.dbg(string.format("Zlibrary:Parser.extractTotalCount - Extracted count: %d", count))
                return count
            end
        else
             logger.warn(string.format("Zlibrary:Parser.extractTotalCount - Could not extract count from book tab text: %s", tab_text))
        end
    else
        logger.warn(string.format("Zlibrary:Parser.extractTotalCount - Could not find book tab node <a data-type='book'>."))
    end

    logger.warn(string.format("Zlibrary:Parser.extractTotalCount - Could not determine total count."))
    return nil
end

return Parser
