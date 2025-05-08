local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local T = require("gettext")
local DownloadMgr = require("ui/downloadmgr")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local Config = require("config")
local utils = require("utils")
local logger = require("logger")

local Ui = {}

function Ui.showInfoMessage(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function Ui.showErrorMessage(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 5 })
end

function Ui.showLoadingMessage(text)
    local message = InfoMessage:new{ text = text, timeout = 0 }
    UIManager:show(message)
    return message
end

function Ui.closeMessage(message_widget)
    if message_widget then
        UIManager:close(message_widget)
    end
end

function Ui.showFullTextDialog(title, full_text)
    UIManager:show(ConfirmBox:new{
        title = title,
        text = full_text,
        ok_text = T("OK"),
    })
end

function Ui.showDownloadDirectoryDialog()
    local current_dir = G_reader_settings:readSetting(Config.SETTINGS_DOWNLOAD_DIR_KEY)
    DownloadMgr:new{
        title = T("Select Z-library Download Directory"),
        onConfirm = function(path)
            if path then
                G_reader_settings:saveSetting(Config.SETTINGS_DOWNLOAD_DIR_KEY, path)
                Ui.showInfoMessage(string.format(T("Download directory set to: %s"), path))
            else
                Ui.showErrorMessage(T("No directory selected."))
            end
        end,
    }:chooseDir(current_dir)
end

local function _showMultiSelectionDialog(parent_ui, title, setting_key, options_list)
    local selected_values_table = G_reader_settings:readSetting(setting_key) or {}
    local selected_values_set = {}
    for _, value in ipairs(selected_values_table) do
        selected_values_set[value] = true
    end

    local current_selection_state = {}
    for _, option_info in ipairs(options_list) do
        current_selection_state[option_info.value] = selected_values_set[option_info.value] or false
    end

    local menu_items = {}
    local selection_menu

    for i, option_info in ipairs(options_list) do
        local option_value = option_info.value
        menu_items[i] = {
            text = option_info.name,
            mandatory_func = function()
                return current_selection_state[option_value] and T("[X]") or "[ ]"
            end,
            callback = function()
                current_selection_state[option_value] = not current_selection_state[option_value]
                selection_menu:updateItems(nil, true)
            end,
            keep_menu_open = true,
        }
    end

    selection_menu = Menu:new{
        title = title,
        item_table = menu_items,
        parent = parent_ui,
        onClose = function()
            local ok, err = pcall(function()
                local new_selected_values = {}
                for value, is_selected in pairs(current_selection_state) do
                    if is_selected then table.insert(new_selected_values, value) end
                end
                table.sort(new_selected_values, function(a, b)
                    local name_a, name_b
                    for _, info in ipairs(options_list) do
                        if info.value == a then name_a = info.name end
                        if info.value == b then name_b = info.name end
                    end
                    return (name_a or "") < (name_b or "")
                end)

                if #new_selected_values > 0 then
                    G_reader_settings:saveSetting(setting_key, new_selected_values)
                    Ui.showInfoMessage(string.format(T("%d items selected for %s."), #new_selected_values, title))
                else
                    G_reader_settings:delSetting(setting_key)
                    Ui.showInfoMessage(string.format(T("Filter cleared for %s."), title))
                end
            end)
            if not ok then
                logger.error("Zlibrary:Ui._showMultiSelectionDialog - Error during onClose for %s: %s", title, tostring(err))
            end
            UIManager:close(selection_menu)
        end,
    }
    UIManager:show(selection_menu)
end

function Ui.showLanguageSelectionDialog(parent_ui)
    _showMultiSelectionDialog(parent_ui, T("Select Search Languages"), Config.SETTINGS_SEARCH_LANGUAGES_KEY, Config.SUPPORTED_LANGUAGES)
end

function Ui.showExtensionSelectionDialog(parent_ui)
    _showMultiSelectionDialog(parent_ui, T("Select Search Formats"), Config.SETTINGS_SEARCH_EXTENSIONS_KEY, Config.SUPPORTED_EXTENSIONS)
end

function Ui.showGenericInputDialog(title, setting_key, current_value_or_default, is_password)
    local dialog

    dialog = InputDialog:new{
        title = title,
        input = current_value_or_default or "",
        text_type = is_password and "password" or nil,
        buttons = {{
            {
                text = T("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = T("Set"),
                callback = function()
                    local input = dialog:getInputText()
                    if input and input:match("%S") then
                        Config.saveSetting(setting_key, utils.trim(input))
                        Ui.showInfoMessage(T("Setting saved successfully!"))
                    else
                        Config.deleteSetting(setting_key)
                        Ui.showInfoMessage(T("Setting cleared."))
                    end
                    UIManager:close(dialog)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Ui.showSearchDialog(parent_zlibrary)
    local dialog
    dialog = InputDialog:new{
        title = T("Search Z-library"),
        input = "",
        buttons = {{
            {
                text = T("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = T("Search"),
                callback = function()
                    local query = dialog:getInputText()
                    UIManager:close(dialog)

                    if not query or not query:match("%S") then
                        Ui.showErrorMessage(T("Please enter a search term."))
                        return
                    end

                    local login_ok = parent_zlibrary:login()

                    if not login_ok then
                        return
                    end

                    local trimmed_query = utils.trim(query)
                    parent_zlibrary:performSearch(trimmed_query)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Ui.createBookMenuItem(book_data, parent_zlibrary_instance)
    local year_str = (book_data.year and book_data.year ~= "N/A" and tostring(book_data.year) ~= "0") and (" (" .. book_data.year .. ")") or ""
    local title = book_data.title or T("Unknown Title")
    local author = book_data.author or T("Unknown Author")
    local main_text_part = string.format("%s by %s%s", title, author, year_str)

    local sub_text_parts = {}
    if book_data.format and book_data.format ~= "N/A" then table.insert(sub_text_parts, book_data.format) end
    if book_data.size and book_data.size ~= "N/A" then table.insert(sub_text_parts, book_data.size) end
    if book_data.rating and book_data.rating ~= "N/A" then table.insert(sub_text_parts, T("Rating: ") .. book_data.rating) end
    local sub_text_part = table.concat(sub_text_parts, " | ")

    local combined_text = main_text_part
    if sub_text_part ~= "" then
        combined_text = combined_text .. " | " .. sub_text_part
    end

    return {
        text = combined_text,
        callback = function()
            Ui.showBookDetails(parent_zlibrary_instance, book_data)
        end,
        keep_menu_open = true,
        original_book_data_ref = book_data,
    }
end

function Ui.createSearchResultsMenu(parent_ui_ref, query_string, initial_menu_items, on_goto_page_handler)
    local menu = Menu:new{
        title = T("Search Results: ") .. query_string,
        item_table = initial_menu_items,
        parent = parent_ui_ref,
        items_per_page = 10,
        show_captions = true,
        onGotoPage = on_goto_page_handler,
    }
    UIManager:show(menu)
    return menu
end

function Ui.appendSearchResultsToMenu(menu_instance, new_menu_items)
    if not menu_instance or not menu_instance.item_table then return end
    for _, item_data in ipairs(new_menu_items) do
        table.insert(menu_instance.item_table, item_data)
    end
    menu_instance:switchItemTable(menu_instance.title, menu_instance.item_table, -1, nil, menu_instance.subtitle)
end

function Ui.showBookDetails(parent_zlibrary, book)
    local details_menu_items = {}
    local details_menu

    local full_title = book.title or ""
    table.insert(details_menu_items, {
        text = T("Title: ") .. full_title,
        enabled = true,
        callback = function()
            Ui.showFullTextDialog(T("Full Title"), full_title)
        end,
        keep_menu_open = true,
    })

    local full_author = book.author or ""
    table.insert(details_menu_items, {
        text = T("Author: ") .. full_author,
        enabled = true,
        callback = function()
            Ui.showFullTextDialog(T("Full Author"), full_author)
        end,
        keep_menu_open = true,
    })

    if book.year and book.year ~= "N/A" and tostring(book.year) ~= "0" then table.insert(details_menu_items, { text = T("Year: ") .. book.year, enabled = false }) end
    if book.format and book.format ~= "N/A" then table.insert(details_menu_items, { text = T("Format: ") .. book.format, enabled = false }) end
    if book.size and book.size ~= "N/A" then table.insert(details_menu_items, { text = T("Size: ") .. book.size, enabled = false }) end
    if book.lang and book.lang ~= "N/A" then table.insert(details_menu_items, { text = T("Language: ") .. book.lang, enabled = false }) end
    if book.rating and book.rating ~= "N/A" then table.insert(details_menu_items, { text = T("Rating: ") .. book.rating, enabled = false }) end

    if book.href then
        local full_link = Config.getBookUrl(book.href)
        table.insert(details_menu_items, {
            text = T("Link: ") .. full_link,
            enabled = true,
            callback = function()
                Ui.showFullTextDialog(T("Full Link"), full_link)
            end,
            keep_menu_open = true,
        })
    end

    table.insert(details_menu_items, { text = "---" })

    if book.download then
        table.insert(details_menu_items, {
            text = T("Download Book"),
            callback = function()
                parent_zlibrary:downloadBook(book)
            end,
            keep_menu_open = true,
        })
    else
        table.insert(details_menu_items, { text = T("Download link not available"), enabled = false })
    end

    table.insert(details_menu_items, { text = "---" })

    table.insert(details_menu_items, {
        text = T("Back"),
        callback = function()
            if details_menu then UIManager:close(details_menu) end
        end,
    })

    details_menu = Menu:new{
        title = T("Book Details"),
        item_table = details_menu_items,
        parent = parent_zlibrary.ui,
    }
    UIManager:show(details_menu)
end

function Ui.confirmDownload(filename, ok_callback)
    UIManager:show(ConfirmBox:new{
        text = string.format(T("Download \"%s\"?"), filename),
        ok_text = T("Download"),
        ok_callback = ok_callback,
        cancel_text = T("Cancel")
    })
end

function Ui.confirmOpenBook(filename, ok_open_callback)
    UIManager:show(ConfirmBox:new{
        text = string.format(T("\"%s\" downloaded successfully. Open it now?"), filename),
        ok_text = T("Open book"),
        ok_callback = ok_open_callback,
        cancel_text = T("Close")
    })
end

return Ui
