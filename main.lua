--[[--
@module koplugin.Zlibrary
--]]--

local Dispatcher = require("dispatcher")  -- luacheck:ignore
local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local util = require("util")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("zlibrary.gettext")
local Config = require("zlibrary.config")
local Api = require("zlibrary.api")
local Ui = require("zlibrary.ui")
local ReaderUI = require("apps/reader/readerui")
local AsyncHelper = require("zlibrary.async_helper")
local logger = require("logger")
local Ota = require("zlibrary.ota")
local Cache = require("zlibrary.cache")
local Device = require("device")
local MultiSearchDialog = require("zlibrary.multisearch_dialog")
local DialogManager = require("zlibrary.dialog_manager")

local CWABD = WidgetContainer:extend{
    name = T("CWA Book Downloader"),
    is_doc_only = false,
    plugin_path = nil,
    dialog_manager = nil,
}

function CWABD:onDispatcherRegisterActions()
    Dispatcher:registerAction("zlibrary_search", { category="none", event="ZlibrarySearch", title=T("Z-library search"), general=true,})
end

function CWABD:init()
    local full_source_path = debug.getinfo(1, "S").source
    if full_source_path:sub(1,1) == "@" then
        full_source_path = full_source_path:sub(2)
    end
    self.plugin_path, _ = util.splitFilePathName(full_source_path):gsub("/+", "/")

    Config.loadCredentialsFromFile(self.plugin_path)

    self.dialog_manager = DialogManager:new()
    Ui.setPluginInstance(self)

    self:onDispatcherRegisterActions()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    else
        logger.warn("self.ui or self.ui.menu not initialized in Zlibrary:init")
    end
end

function CWABD:onZlibrarySearch()
    local def_search_input
    if self.ui and self.ui.doc_settings and self.ui.doc_settings.data.doc_props then
      local doc_props = self.ui.doc_settings.data.doc_props
      def_search_input = doc_props.authors or doc_props.title
    end
    self:showMultiSearchDialog(nil, def_search_input)
    return true
end

function CWABD:addToMainMenu(menu_items)
    if not self.ui.view then
        menu_items.zlibrary_main = {
            sorting_hint = "search",
            text = T("CWA Book Downloader"),
            sub_item_table = {
                {
                    text = T("Settings"),
                    keep_menu_open = true,
                    separator = true,
                    sub_item_table = {
                        {
                            text = T("Set base URL"),
                            keep_menu_open = true,
                            callback = function()
                                Ui.showGenericInputDialog(
                                    T("Set base URL"),
                                    Config.SETTINGS_BASE_URL_KEY,
                                    Config.getBaseUrl(),
                                    false,
                                    function(input_value)
                                        local success, err_msg = Config.setAndValidateBaseUrl(input_value)
                                        if not success then
                                            Ui.showErrorMessage(err_msg or T("Invalid Base URL."))
                                            return false
                                        end
                                        return true
                                    end
                                )
                            end,
                            separator = true,
                        },
                        {
                            text = T("Set username"),
                            keep_menu_open = true,
                            callback = function()
                                Ui.showGenericInputDialog(
                                    T("Set username"),
                                    Config.SETTINGS_USERNAME_KEY,
                                    Config.getSetting(Config.SETTINGS_USERNAME_KEY),
                                    false
                                )
                            end,
                        },
                        {
                            text = T("Set password"),
                            keep_menu_open = true,
                            callback = function()
                                Ui.showGenericInputDialog(
                                    T("Set password"),
                                    Config.SETTINGS_PASSWORD_KEY,
                                    Config.getSetting(Config.SETTINGS_PASSWORD_KEY),
                                    true
                                )
                            end,
                        },
                        {
                            text = T("Verify connection"),
                            keep_menu_open = true,
                            callback = function()
                                self:verifyConnection(function(success)
                                    if success then
                                        Ui.showInfoMessage(T("Connection successful!"))
                                    end
                                end)
                            end,
                            separator = true,
                        },
                        {
                            text = T("Search options"),
                            keep_menu_open = true,
                            separator = true,
                            sub_item_table = {{
                                text = T("Select search language"),
                                keep_menu_open = true,
                                callback = function()
                                    Ui.showLanguageSelectionDialog(self.ui)
                                end
                            }, {
                                text = T("Select search formats"),
                                keep_menu_open = true,
                                callback = function()
                                    Ui.showExtensionSelectionDialog(self.ui)
                                end
                            }, {
                                text = T("Select search order"),
                                keep_menu_open = true,
                                callback = function()
                                    Ui.showOrdersSelectionDialog(self.ui)
                                end
                            }}
                        },
                        {
                            text = T("Timeout settings"),
                            keep_menu_open = true,
                            separator = true,
                            callback = function()
                                Ui.showAllTimeoutConfigDialog(self.ui)
                            end,
                        },
                        {
                            text = T("Check for updates"),
                            keep_menu_open = false,
                            separator = true,
                            callback = function()
                                if self.plugin_path then
                                    Ota.startUpdateProcess(self.plugin_path)
                                else
                                    logger.err("ZLibrary: Plugin path not available for OTA update.")
                                    Ui.showErrorMessage(T("Error: Plugin path not found. Cannot check for updates."))
                                end
                            end,
                        },
                        {
                            text = T("Developer options"),
                            keep_menu_open = true,
                            separator = true,
                            sub_item_table_func = function()
                                return {
                                    {
                                        text = T("Restart server"),
                                        keep_menu_open = false,
                                        callback = function()
                                            Api.restart()
                                            Ui.showInfoMessage(T("Server restarting..."))
                                        end,
                                    },
                                }
                            end
                        },
                    }
                },
                {
                    text = T("Search"),
                    callback = function()
                        Ui.showSearchDialog(self)
                    end,
                },
                {
                    text = T("Download Queue"),
                    callback = function()
                        self:onShowDownloadQueue()
                    end,
                }
            }
        }
    end
end

function CWABD:_fetchBookList(options)
    if not NetworkMgr:isOnline() then
        Ui.showErrorMessage(T("No internet connection detected."))
        return
    end

    local function attemptFetch(retry_on_auth_error)
        retry_on_auth_error = retry_on_auth_error == nil and true or retry_on_auth_error

        local loading_msg = Ui.showLoadingMessage(options.loading_text_key)

        local task = function()
            return options.api_method()
        end

        local on_success = function(api_result)
            if api_result.error then
                Ui.closeMessage(loading_msg)
                Ui.showErrorMessage(Ui.colonConcat(options.error_prefix_key, tostring(api_result.error)))
                return
            end

            if not api_result.books or #api_result.books == 0 then
                Ui.closeMessage(loading_msg)
                if options.no_items_text_key then
                    Ui.showInfoMessage(options.no_items_text_key)
                else
                    Ui.showInfoMessage(T("No books found, please try again"))
                end
                return
            end

            Ui.closeMessage(loading_msg)
            logger.info(string.format("CWABD:%s - Fetch successful. Results: %d", options.log_context, #api_result.books))
            self[options.results_member_name] = api_result.books

            UIManager:nextTick(function()
                options.display_menu_func(self.ui, self[options.results_member_name], self)
            end)
        end

        local on_error_handler = function(err_msg)
            -- Use retry dialog for timeout and network errors
            Ui.showRetryErrorDialog(err_msg, options.operation_name or T("Operation"), function()
                -- Retry callback
                attemptFetch(false)
            end, function(final_err_msg)
                -- Cancel callback - user already knows about the error
            end, loading_msg)
        end

        AsyncHelper.run(task, on_success, on_error_handler, loading_msg)
    end

    attemptFetch()
end

function CWABD:showMultiSearchDialog(def_position, def_search_input)
    local search_dialog
    local ShowBooksMultiSearch = function(ui_self, books, plugin_self)
        search_dialog:refreshMenuItems(books)
    end
    search_dialog = MultiSearchDialog:new{
        title = T("Book search"),
        def_position = def_position,
        def_search_input = def_search_input,
        on_select_book_callback = function(book)
            self:onSelectRecommendedBook(book)
        end,
        on_search_callback = function(def_input)
            Ui.showSearchDialog(self, def_input)
        end
    }

    self.dialog_manager:trackDialog(search_dialog)
    search_dialog:fetchAndShow()
end


function CWABD:onShowDownloadQueue()
    self:_fetchBookList({
        api_method = Api.getDownloadQueue,
        loading_text_key = T("Fetching download queue..."),
        error_prefix_key = T("Failed to fetch download queue"),
        operation_name = T("Download queue"),
        log_context = "onShowDownloadQueue",
        results_member_name = "current_most_popular_books",
        display_menu_func = Ui.showDownloadQueue,
        requires_auth = false
    })
end

function CWABD:onDownloadingBookSelected(book)

    if book.queue_status == "downloading" or book.queue_status == "queued" then
        Ui.confirmCancel(book.title, function()
            local result = Api.cancelDownload(book.id)
            if result.success then
                Ui.showInfoMessage(T('Download canceled!'))
            elseif result.error then
                Ui.showInfoMessage(T(result.error))
            end
        end)
    end

end

function CWABD:onSelectRecommendedBook(book_stub)
    if not NetworkMgr:isOnline() then
        Ui.showErrorMessage(T("No internet connection detected."))
        return
    end

    if not (book_stub.id and book_stub.hash) then
        logger.warn("Zlibrary.onSelectRecommendedBook - parameter error")
        return
    end

    local book_cache = Cache:new{
            name = string.format("%s_%s", book_stub.id, book_stub.hash)
    }
    local book_details_cache = book_cache:get("details")

    if type(book_details_cache) == "table" and book_details_cache.title then
        Ui.showBookDetails(self, book_details_cache, function()
                book_cache:clear()
                self:onSelectRecommendedBook(book_stub)
        end)
        return
    end

    local function attemptBookDetails()
        local user_session = Config.getUserSession()
        local loading_msg = Ui.showLoadingMessage(T("Fetching book details..."))

        local task = function()
            return Api.getBookDetails(user_session and user_session.user_id, user_session and user_session.user_key, book_stub.id, book_stub.hash)
        end

        local on_success = function(api_result)
            if api_result.error then
                Ui.closeMessage(loading_msg)
                Ui.showErrorMessage(Ui.colonConcat(T("Failed to fetch book details"), tostring(api_result.error)))
                return
            end

            if not api_result.book then
                Ui.closeMessage(loading_msg)
                Ui.showErrorMessage(T("Could not retrieve book details."))
                return
            end

            Ui.closeMessage(loading_msg)
            logger.info(string.format("CWABD:onSelectRecommendedBook - Fetch successful for book ID: %s", api_result.book.id))

            Ui.showBookDetails(self, api_result.book)

            book_cache:insert("details", api_result.book)
        end

        local function on_error_handler(err_msg)
            -- Use retry dialog for timeout and network errors
            Ui.showRetryErrorDialog(err_msg, T("Book details"), function()
                -- Retry callback
                attemptBookDetails()
            end, function(final_err_msg)
                -- Cancel callback - user already knows about the error
            end, loading_msg)
        end

        AsyncHelper.run(task, on_success, on_error_handler, loading_msg)
    end

    attemptBookDetails()
end

function CWABD:verifyConnection(callback)
    if not NetworkMgr:isOnline() then
        Ui.showErrorMessage(T("No internet connection detected."))
        if callback then callback(false) end
        return
    end

    local email = Config.getSetting(Config.SETTINGS_USERNAME_KEY)
    local password = Config.getSetting(Config.SETTINGS_PASSWORD_KEY)

    local loading_msg = Ui.showLoadingMessage(T("Verifying connection..."))

    local task = function()
        return Api.verify(email, password)
    end

    local on_success = function(result)
        Ui.closeMessage(loading_msg)

        if result.error then
            Ui.showErrorMessage(result.error)
            if callback then callback(false) end
            return
        end

        if callback then callback(true) end
    end

    local on_error_handler = function(err_msg)
        Ui.showRetryErrorDialog(err_msg, T("Verify"), function()
            self:verifyConnection(callback)
        end, function(final_err_msg)
            if callback then callback(false) end
        end, loading_msg)
    end

    AsyncHelper.run(task, on_success, on_error_handler, loading_msg)
end

function CWABD:performSearch(query)
    if not NetworkMgr:isOnline() then
        Ui.showErrorMessage(T("No internet connection detected."))
        return
    end

    local function attemptSearch(retry_on_auth_error)
        retry_on_auth_error = retry_on_auth_error == nil and true or retry_on_auth_error

        local user_session = Config.getUserSession()
        local loading_msg = Ui.showLoadingMessage(T("Searching for \"") .. query .. "\"...")

        local selected_languages = Config.getSearchLanguages()
        local selected_extensions = Config.getSearchExtensions()
        local selected_order = Config.getSearchOrder()
        local current_page_to_search = 1

        local task = function()
            return Api.search(query, user_session and user_session.user_id, user_session and user_session.user_key, selected_languages, selected_extensions, selected_order, current_page_to_search)
        end

        local on_success
        on_success = function(api_result)
            if api_result.error then
                -- Use the retry dialog for timeouts and HTTP 400 errors
                Ui.showSearchErrorDialog(api_result.error, query, user_session, selected_languages, selected_extensions, selected_order, current_page_to_search, loading_msg, on_success, function(final_err_msg)
                    -- Cancel callback - user already knows about the error
                end)
                return
            end

            if not api_result.results or #api_result.results == 0 then
                Ui.closeMessage(loading_msg)
                Ui.showInfoMessage(T("No results found for \"") .. query .. "\".")
                return
            end

            Ui.closeMessage(loading_msg)
            logger.info(string.format("CWABD:performSearch - Fetch successful. Results: %d", #api_result.results))
            self.current_search_query = query
            self.current_search_api_page_loaded = current_page_to_search
            self.all_search_results_data = api_result.results
            self.has_more_api_results = false

            UIManager:nextTick(function()
                self:displaySearchResults(self.all_search_results_data, self.current_search_query)
            end)
        end

        local on_error_handler = function(err_msg)
            -- Use the retry dialog for timeouts and HTTP 400 errors
            Ui.showSearchErrorDialog(err_msg, query, user_session, selected_languages, selected_extensions, selected_order, current_page_to_search, loading_msg, on_success, function(final_err_msg)
                -- Cancel callback - user already knows about the error
            end)
        end

        AsyncHelper.run(task, on_success, on_error_handler, loading_msg)
    end

    attemptSearch()
end

function CWABD:displaySearchResults(initial_book_data_list, query_string)
    if not initial_book_data_list or #initial_book_data_list == 0 then
        logger.info("CWABD:displaySearchResults - No initial results to display.")
        return
    end

    local menu_items = {}
    logger.info(string.format("CWABD:displaySearchResults - Preparing menu items from %d initial results.", #initial_book_data_list))

    for i = 1, #initial_book_data_list do
        local book_menu_item_data = initial_book_data_list[i]
        menu_items[i] = Ui.createBookMenuItem(book_menu_item_data, self)
    end

    if self.active_results_menu then
        UIManager:close(self.active_results_menu)
        self.active_results_menu = nil
    end

    local function on_goto_page_handler(menu_instance, new_page_number)
        menu_instance.prev_focused_path = nil
        menu_instance.page = new_page_number

        local is_last_page_of_current_items = (new_page_number == menu_instance.page_num)

        if is_last_page_of_current_items and self.has_more_api_results then
            logger.info(string.format("CWABD: Reached page %d (last page of current items). Attempting to load more from API.", new_page_number))

            local next_api_page_to_fetch = self.current_search_api_page_loaded + 1
            local loading_msg_more = Ui.showLoadingMessage(string.format(T("Loading more results (Page %s)..."), next_api_page_to_fetch))

            local user_session_more = Config.getUserSession()
            local selected_languages_more = Config.getSearchLanguages()
            local selected_extensions_more = Config.getSearchExtensions()
            local selected_order_more = Config.getSearchOrder()

            local task_load_more = function()
                return Api.search(self.current_search_query, user_session_more.user_id, user_session_more.user_key, selected_languages_more, selected_extensions_more, selected_order_more, next_api_page_to_fetch)
            end

            local on_success_load_more
            local on_error_load_more

            on_success_load_more = function(api_result_more)
                Ui.closeMessage(loading_msg_more)

                local new_book_objects = api_result_more.results
                if new_book_objects and #new_book_objects > 0 then
                    logger.info(string.format("CWABD: Adding %d new book objects from API.", #new_book_objects))
                    self.current_search_api_page_loaded = next_api_page_to_fetch

                    local new_menu_items_to_add = {}
                    for _, book_api_data_transformed in ipairs(new_book_objects) do
                        table.insert(self.all_search_results_data, book_api_data_transformed)
                        table.insert(new_menu_items_to_add, Ui.createBookMenuItem(book_api_data_transformed, self))
                    end
                    Ui.appendSearchResultsToMenu(menu_instance, new_menu_items_to_add)
                else
                    logger.info("CWABD: No more results from API or API returned empty.")
                    self.has_more_api_results = false
                    Ui.showInfoMessage(T("No more results found."))
                    menu_instance:updateItems(1, true)
                end
            end

            on_error_load_more = function(err_msg_more)
                Ui.closeMessage(loading_msg_more)
                Ui.showErrorMessage(Ui.colonConcat(T("Failed to load more results"), tostring(err_msg_more)))
            end

            AsyncHelper.run(task_load_more, on_success_load_more, on_error_load_more, loading_msg_more)
        else
            if is_last_page_of_current_items and not self.has_more_api_results then
                logger.info("CWABD: Reached last page, and no more API results to load.")
            end
            menu_instance:updateItems(1, true)
        end
        return true
    end

    self.active_results_menu = Ui.createSearchResultsMenu(self.ui, query_string, menu_items, on_goto_page_handler)
end

function CWABD:downloadBook(book)
    if not NetworkMgr:isOnline() then
        Ui.showErrorMessage(T("No internet connection detected."))
        return
    end

    if not book.download then
        Ui.showErrorMessage(T("No download link available for this book."))
        return
    end

    local download_url = Config.getDownloadUrl(book.id)
    logger.info(string.format("CWABD:downloadBook - Download URL: %s", download_url))

    local function attemptDownload(retry_on_auth_error)
        retry_on_auth_error = retry_on_auth_error == nil and true or retry_on_auth_error

        local loading_msg = Ui.showLoadingMessage(T("Enqueing download..."))

        local function task_download()
            return Api.downloadBook(download_url)
        end

        local function on_success_download(api_result)

            Ui.closeMessage(loading_msg)
            if api_result and api_result.success then
                Ui.showInfoMessage(T("Download enqueued"))
            end
        end

        local function on_error_download(err_msg)

            -- Use retry dialog for timeout and network errors
            Ui.showRetryErrorDialog(err_msg, T("Download"), function()
                -- Retry callback
                local new_loading_msg = Ui.showLoadingMessage(T("Retrying download..."))
                loading_msg = new_loading_msg
                AsyncHelper.run(task_download, on_success_download, on_error_download, loading_msg)
            end, function(final_err_msg)
            end, loading_msg)
        end

        AsyncHelper.run(task_download, on_success_download, on_error_download, loading_msg)
    end

    Ui.confirmDownload(book.title, function()
        attemptDownload()
    end)
end

function CWABD:downloadAndShowCover(book)
    local cover_url = book.cover
    local book_id = book.id
    local book_hash = book.hash
    local book_title = book.title

    if not (cover_url and book_id and book_hash) then
        logger.warn("CWABD:downloadAndShowCover - parameter error")
        return
    end

    local function getImgExtension(url)
       local clean_url = url:match("^([^%?]+)") or url
       return clean_url:match("[%.]([^%.]+)$") or "jpg"
    end

    local cover_ext = getImgExtension(cover_url)
    local cache_path = Cache:makePath(book_id, book_hash)
    local cover_cache_path = string.format("%s.%s", cache_path, cover_ext)

    if not util.fileExists(cover_cache_path) then
        local download_result = Api.downloadBookCover(cover_url, cover_cache_path)
        if download_result.error or not download_result.success then
            if util.fileExists(cover_cache_path) then
                    pcall(os.remove, cover_cache_path)
            end
            Ui.showErrorMessage(tostring(download_result.error))
            return
        end
    end

    Ui.showCoverDialog(book_title, cover_cache_path)
end

function CWABD:onExit()
    if self.dialog_manager and self.dialog_manager:getDialogCount() > 0 then
        logger.info("CWABD:onExit - Cleaning up " .. self.dialog_manager:getDialogCount() .. " remaining dialogs")
        self.dialog_manager:closeAllDialogs()
    end
end

function CWABD:onCloseWidget()
    if self.dialog_manager and self.dialog_manager:getDialogCount() > 0 then
        logger.info("CWABD:onCloseWidget - Cleaning up " .. self.dialog_manager:getDialogCount() .. " remaining dialogs")
        self.dialog_manager:closeAllDialogs()
    end
end

return CWABD
