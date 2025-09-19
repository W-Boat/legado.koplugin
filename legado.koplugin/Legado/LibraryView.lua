local BD = require("ui/bidi")
local Font = require("ui/font")
local ffiUtil = require("ffi/util")
local util = require("util")
local logger = require("logger")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Menu = require("ui/widget/menu")
local Device = require("device")
local T = ffiUtil.template
local _ = require("gettext")

local ChapterListing = require("Legado/ChapterListing")
local ReaderUI = require("apps/reader/readerui")
local FileManager = require("apps/filemanager/filemanager")
local DocSettings = require("docsettings")
local Icons = require("Legado/Icons")
local Backend = require("Legado/Backend")
local MessageBox = require("Legado/MessageBox")
local H = require("Legado/Helper")

local LibraryView = {
    disk_available = nil,
    -- record the current reading items
    selected_item = nil,
    book_toc = nil,
    ui_refresh_time = os.time(),
    displayed_chapter = nil,
    readerui_is_showing = nil,
    chapter_call_event = nil,
    -- menu mode
    book_menu = nil,
    -- file browser mode
    book_browser = nil,
    book_browser_homedir = nil,
}

function LibraryView:init()
    if LibraryView.instance then
        return
    end
    self.book_browser_homedir = self:getBrowserHomeDir(true)
    self:backupDbWithPreCheck()
    LibraryView.instance = self
end

function LibraryView:backupDbWithPreCheck()
    local temp_dir = H.getTempDirectory()
    local last_backup_db = H.joinPath(temp_dir, "bookinfo.db.bak")
    local bookinfo_db_path = H.joinPath(temp_dir, "bookinfo.db")

    if not util.fileExists(bookinfo_db_path) then
        logger.warn("legado plugin: source database file does not exist - " .. bookinfo_db_path)
        return false
    end

    local setting_data = Backend:getSettings()
    local last_backup_time = setting_data.last_backup_time or 0
    local has_backup = util.fileExists(last_backup_db)
    local needs_backup = not has_backup or (os.time() - last_backup_time > 86400)

    if not needs_backup then
        return true
    end

    local status, err = pcall(function()
        Backend:getBookShelfCache()
    end)
    if not status then
        logger.err("legado plugin: database pre-check failed - " .. tostring(err))
        return false
    end

    if has_backup then
        util.removeFile(last_backup_db)
    end
    H.copyFileFromTo(bookinfo_db_path, last_backup_db)
    logger.info("legado plugin: backup successful")
    setting_data.last_backup_time = os.time()
    Backend:saveSettings(setting_data)
end

function LibraryView:fetchAndShow()
    local is_first = not LibraryView.instance
    local library_view = LibraryView.instance or self:getInstance()
    local use_browser = not self:isDisableBrowserMode() and is_first and self:browserViewHasLnk()
    local widget = use_browser and self:getBrowserWidget() or self:getMenuWidget()
    if widget then
        widget:show_view()
        widget:refreshItems()
    end
    return self
end

function LibraryView:isDisableBrowserMode()
    local settings = Backend:getSettings()
    return settings and settings.disable_browser == true
end
function LibraryView:browserViewHasLnk()
    local browser_homedir = self:getBrowserHomeDir(true)
    return browser_homedir and util.directoryExists(browser_homedir) and not util.isEmptyDir(browser_homedir)
end

function LibraryView:addBkShortcut(bookinfo, always_add)
    if not always_add and self:isDisableBrowserMode() then
        return
    end
    local browser = self:getBrowserWidget()
    if browser then
        browser:addBookShortcut(bookinfo)
    end
end

function LibraryView:onRefreshLibrary()
    if self.book_menu then
        self.book_menu:onRefreshLibrary()
    end
end

function LibraryView:closeMenu()
    if self.book_menu then
        self.book_menu:onClose()
    end
end

function LibraryView:openWebConfigManager()
    local configs = Backend:getWebConfigs()
    local current_config = Backend:getCurrentWebConfig()
    local current_config_id = current_config and current_config.id or nil

    -- 创建配置列表的按钮
    local config_buttons = {}
    
    -- 添加新增配置按钮
    table.insert(config_buttons, {{
        text = Icons.FA_PLUS .. " 新增配置",
        callback = function()
            self:openWebConfigTypeSelector()
        end
    }})

    -- 如果有多个配置，添加快速切换按钮
    if #configs > 1 then
        table.insert(config_buttons, {{
            text = Icons.FA_EXCHANGE .. " 快速切换",
            callback = function()
                self:openQuickConfigSwitch()
            end
        }})
    end

    -- 添加每个配置的按钮
    for _, config in ipairs(configs) do
        local is_current = (config.id == current_config_id)
        local button_text = string.format("%s %s%s",
            is_current and Icons.UNICODE_STAR or Icons.UNICODE_STAR_OUTLINE,
            config.name,
            is_current and " (当前)" or ""
        )
        
        table.insert(config_buttons, {{
            text = button_text,
            callback = function()
                self:openWebConfigMenu(config, is_current)
            end
        }})
    end

    -- 如果没有配置，显示提示和兼容旧配置的按钮
    if #configs == 0 then
        table.insert(config_buttons, {{
            text = "暂无配置，点击上方新增",
            enabled = false
        }})
        table.insert(config_buttons, {{
            text = Icons.FA_GEAR .. " 旧版配置 (兼容)",
            callback = function()
                self:openInstalledReadSource()
            end
        }})
    end

    local dialog = require("ui/widget/buttondialog"):new{
        title = "Legado WEB 配置管理",
        title_align = "center",
        buttons = config_buttons,
    }
    UIManager:show(dialog)
end

function LibraryView:openQuickConfigSwitch()
    local configs = Backend:getWebConfigs()
    local current_config = Backend:getCurrentWebConfig()
    local current_config_id = current_config and current_config.id or nil

    local switch_buttons = {}
    
    for _, config in ipairs(configs) do
        local is_current = (config.id == current_config_id)
        local button_text = string.format("%s %s",
            is_current and Icons.UNICODE_STAR or Icons.UNICODE_STAR_OUTLINE,
            config.name
        )
        
        table.insert(switch_buttons, {{
            text = button_text,
            enabled = not is_current,
            callback = function()
                if not is_current then
                    Backend:HandleResponse(Backend:switchWebConfig(config.id), function(data)
                        UIManager:close(dialog)  -- 关闭快速切换对话框
                        MessageBox:notice(string.format("已切换到配置: %s", config.name))
                        -- 刷新书架
                        if self.book_menu then
                            self.book_menu.item_table = self.book_menu:generateEmptyViewItemTable()
                            self.book_menu.multilines_show_more_text = true
                            self.book_menu.items_per_page = 1
                            self.book_menu:updateItems()
                            self.book_menu:onRefreshLibrary()
                        end
                    end, function(err_msg)
                        MessageBox:error('切换失败：' .. err_msg)
                    end)
                end
            end
        }})
    end

    local dialog = require("ui/widget/buttondialog"):new{
        title = string.format("当前: %s", current_config and current_config.name or "无"),
        title_align = "center",
        buttons = switch_buttons,
    }
    UIManager:show(dialog)
end

function LibraryView:openWebConfigMenu(config, is_current)
    local buttons = {{{
        text = is_current and "当前配置" or "切换到此配置",
        enabled = not is_current,
        callback = function()
            if not is_current then
                Backend:HandleResponse(Backend:switchWebConfig(config.id), function(data)
                    UIManager:close(dialog)  -- 关闭当前配置菜单对话框
                    MessageBox:notice("配置切换成功")
                    -- 刷新书架
                    if self.book_menu then
                        self.book_menu.item_table = self.book_menu:generateEmptyViewItemTable()
                        self.book_menu.multilines_show_more_text = true
                        self.book_menu.items_per_page = 1
                        self.book_menu:updateItems()
                        self.book_menu:onRefreshLibrary()
                    end
                end, function(err_msg)
                    MessageBox:error('切换失败：', err_msg)
                end)
            end
        end
    }}, {{
        text = "编辑配置",
        callback = function()
            UIManager:close(dialog)  -- 关闭当前配置菜单对话框
            self:openWebConfigEditorWithType(config, config.server_type or 1)
        end
    }}, {{
        text = "删除配置",
        callback = function()
            MessageBox:confirm(
                string.format("确定要删除配置 \"%s\" 吗？", config.name),
                function(result)
                    if result then
                        Backend:HandleResponse(Backend:deleteWebConfig(config.id), function(data)
                            UIManager:close(dialog)  -- 关闭当前配置菜单对话框
                            MessageBox:notice("配置删除成功")
                            self:openWebConfigManager()
                        end, function(err_msg)
                            MessageBox:error('删除失败：', err_msg)
                        end)
                    end
                end, {
                    ok_text = "删除",
                    cancel_text = "取消"
                })
        end
    }}}

    local info_text = string.format("名称：%s\nWEB地址：%s\n%s",
        config.name,
        config.url,
        config.description ~= "" and ("描述：" .. config.description) or ""
    )

    local dialog = require("ui/widget/buttondialog"):new{
        title = info_text,
        title_align = "left",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function LibraryView:openWebConfigTypeSelector(config)
    local is_edit = config ~= nil
    local title = is_edit and "选择配置类型 (编辑)" or "选择配置类型 (新建)"
    
    local type_buttons = {{{
        text = "手机APP",
        callback = function()
            UIManager:close(dialog)  -- 关闭类型选择对话框
            self:openWebConfigEditorWithType(config, 1)
        end
    }}, {{
        text = "服务器版（自动添加后缀）",
        callback = function()
            UIManager:close(dialog)  -- 关闭类型选择对话框
            self:openWebConfigEditorWithType(config, 2)
        end
    }}, {{
        text = "带认证服务（自动添加后缀）",
        callback = function()
            UIManager:close(dialog)  -- 关闭类型选择对话框
            self:openWebConfigEditorWithType(config, 3)
        end
    }}}
    
    local dialog = require("ui/widget/buttondialog"):new{
        title = title,
        title_align = "center",
        buttons = type_buttons,
    }
    UIManager:show(dialog)
end

function LibraryView:openWebConfigEditorWithType(config, server_type)
    local is_edit = config ~= nil
    local type_names = {
        [1] = "手机APP",
        [2] = "服务器版", 
        [3] = "带认证服务"
    }
    
    local title = string.format("%s WEB 配置 - %s", 
        is_edit and "编辑" or "新增", 
        type_names[server_type] or "未知类型")
    
    local name_input = config and config.name or ""
    local url_input = config and config.url or "http://"
    local desc_input = config and config.description or ""
    local username_input = config and config.reader3_un or ""
    local password_input = config and config.reader3_pwd or ""
    
    -- 根据编辑模式获取当前类型，否则使用传入的类型
    local current_type = is_edit and (config.server_type or 1) or server_type

    -- 创建输入字段数组
    local fields = {
        {
            text = name_input,
            hint = "配置名称 (必填)",
        },
        {
            text = url_input,
            hint = self:getUrlHintByType(current_type),
            input_type = "text",
        },
        {
            text = desc_input,
            hint = "描述 (可选)",
        }
    }
    
    -- 根据类型添加额外的输入框
    if current_type == 3 then
        table.insert(fields, {
            text = username_input,
            hint = "用户名 (必填)",
        })
        table.insert(fields, {
            text = password_input,
            hint = "密码 (必填)",
            text_type = "password",
        })
    end

    -- 创建输入字段的多输入对话框
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    
    local dialog
    dialog = MultiInputDialog:new{
        title = title,
        fields = fields,
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = is_edit and _("保存") or _("创建"),
                    callback = function()
                        self:handleConfigSave(dialog, config, current_type, is_edit)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function LibraryView:getUrlHintByType(server_type)
    local hints = {
        [1] = "手机APP地址 (如: http://127.0.0.1:1122)",
        [2] = "服务器地址 (如: http://127.0.0.1:1122 - 会自动添加/reader3)",
        [3] = "认证服务地址 (如: http://127.0.0.1:1122 - 会自动添加/reader3)"
    }
    return hints[server_type] or "WEB地址 (必填)"
end

function LibraryView:handleConfigSave(dialog, config, server_type, is_edit)
    local fields = dialog:getFields()
    local name = util.trim(fields[1] or "")
    local url = util.trim(fields[2] or "")
    local description = util.trim(fields[3] or "")
    local username = ""
    local password = ""
    
    -- 根据类型获取用户名密码
    if server_type == 3 then
        username = util.trim(fields[4] or "")
        password = util.trim(fields[5] or "")
    end

    -- 验证必填字段
    if name == "" then
        MessageBox:notice("配置名称不能为空")
        return
    end

    if url == "" then
        MessageBox:notice("WEB地址不能为空")
        return
    end

    -- 验证URL格式和主机名
    local socket_url = require("socket.url")
    local parsed = socket_url.parse(url)
    if not parsed then
        MessageBox:notice("WEB地址格式不正确")
        return
    end
    
    if not parsed.host or parsed.host == "" then
        MessageBox:notice("请输入有效的主机名或IP地址")
        return
    end

    -- 验证认证服务的用户名密码
    if server_type == 3 then
        if username == "" then
            MessageBox:notice("带认证服务需要提供用户名")
            return
        end
        if password == "" then
            MessageBox:notice("带认证服务需要提供密码")
            return
        end
    end
    
    -- 根据类型处理URL格式
    url = self:formatUrlByType(url, server_type)

    local operation
    if is_edit then
        operation = Backend:updateWebConfig(config.id, name, url, description, server_type, username, password)
    else
        operation = Backend:createWebConfig(name, url, description, server_type, username, password)
    end

    Backend:HandleResponse(operation, function(data)
        UIManager:close(dialog)
        MessageBox:notice(is_edit and "配置更新成功" or "配置创建成功")
        self:openWebConfigManager()
    end, function(err_msg)
        MessageBox:error((is_edit and '更新失败：' or '创建失败：') .. err_msg)
    end)
end

function LibraryView:formatUrlByType(url, server_type)
    -- 移除末尾的斜杠
    url = url:gsub("/$", "")
    
    if server_type == 2 or server_type == 3 then
        -- 服务器版和带认证服务：如果URL不以/reader3结尾，自动添加
        if not url:match("/reader3$") then
            url = url .. "/reader3"
        end
    end
    -- 类型1 (手机APP) 不需要特殊处理
    
    return url
end

function LibraryView:openInstalledReadSource()

    local setting_data = Backend:getSettings()
    local history_lines = setting_data.servers_history or {}
    local setting_url = tostring(setting_data.setting_url)
    if not history_lines[1] then
        history_lines = {}
    end

    local description = [[
        (书架与接口地址关联，设置格式符合 RFC3986，认证信息如有特殊字符需要 URL 编码，服务器版本必须加 /reader3)  示例:
        → 手机APP     http://127.0.0.1:1122
        → 服务器版    http://127.0.0.1:1122/reader3
        → 带认证服务  https://username:password@127.0.0.1:1122/reader3
    ]]

    local dialog
    local reset_callback
    local history_cur = 0
    local history_lines_len = #history_lines
    if history_lines_len > 0 then
        -- only display the last 3 lines
        local servers_history_str = table.concat(history_lines, '\n', math.max(1, #history_lines - 2))
        description = description .. string.format("\n历史记录(%s)：\n%s", history_lines_len, servers_history_str)

        reset_callback = function()
            history_cur = history_cur + 1
            if history_cur > #history_lines then
                history_cur = 1
            end
            dialog.button_table:getButtonById("reset"):enable()
            dialog:refreshButtons()
            return history_lines[history_cur]
        end
    end

    local save_callback = function(input_text)
        if H.is_str(input_text) then
            local new_setting_url = util.trim(input_text)
            return Backend:HandleResponse(Backend:setEndpointUrl(new_setting_url), function(data)
                if not self.book_menu then
                    return true
                end
                self.book_menu.item_table = self.book_menu:generateEmptyViewItemTable()
                self.book_menu.multilines_show_more_text = true
                self.book_menu.items_per_page = 1
                self.book_menu:updateItems()
                self.book_menu:onRefreshLibrary()
                return true
            end, function(err_msg)
                MessageBox:notice('设置失败：' .. tostring(err_msg))
                return false
            end)
        end
        MessageBox:notice('输入为空')
        return false
    end

    dialog = MessageBox:input(nil, nil, {
        title = "设置阅读 API 接口地址",
        input = setting_url,
        description = description,
        use_available_height = true,
        fullscreen = true,
        condensed = true,
        save_callback = save_callback,
        allow_newline = false,
        reset_button_text = '填入历史',
        reset_callback = reset_callback
    })

    if H.is_func(reset_callback) then
        dialog.button_table:getButtonById("reset"):enable()
        dialog:refreshButtons()
    end
end

function LibraryView:openBrowserMenu(file)
    self:getInstance()
    self:getBrowserWidget()
    local dialog
    local buttons = { {{
        text = "更换书籍封面",
        callback = function()
            local ui = FileManager.instance or ReaderUI.instance
            if file and ui and ui.bookinfo then
                UIManager:close(dialog)
                local custom_book_cover = DocSettings:findCustomCoverFile(file)
                if custom_book_cover and util.fileExists(custom_book_cover) then
                    util.removeFile(custom_book_cover)
                end

                local DocumentRegistry = require("document/documentregistry")
                local PathChooser = require("ui/widget/pathchooser")
                local path_chooser = PathChooser:new{
                    select_directory = false,
                    path = H.getHomeDir(),
                    file_filter = function(filename)
                        return DocumentRegistry:isImageFile(filename)
                    end,
                    onConfirm = function(image_file)
                        if DocSettings:flushCustomCover(file, image_file) then
                            self.book_browser:emitMetadataChanged(file)
                        end
                    end
                }
                UIManager:show(path_chooser)
            else
                MessageBox:notice("操作失败: 仅能在文件浏览器下操作")
            end
        end
    }, {
        text = "更多设置",
        callback = function()
            UIManager:close(dialog)
            UIManager:nextTick(function()
                self:openMenu()
            end)
        end
    }}, {{
        text = "清空书籍快捷方式",
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm("是否清除所有书籍快捷方式?", function(result)
                if result then
                    local browser_homedir = self:getBrowserHomeDir(true)
                    if self:deleteFile(browser_homedir) then
                        MessageBox:notice("已清除")
                    end
                end
            end, {
                ok_text = "清除",
                cancel_text = "取消"
            })
        end
    }}, {{
        text = "修复书籍快捷方式",
        callback = function()
            UIManager:close(dialog)
            self.book_browser:verifyBooksMetadata()
        end
    }},}

    dialog = require("ui/widget/buttondialog"):new{
        title = "Legado 设置",
        title_align = "center",
        title_face = Font:getFace("x_smalltfont"),
        info_face = Font:getFace("tfont"),
        buttons = buttons,
    }

    UIManager:show(dialog)
end

function LibraryView:selectCustomCSS()
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        title = _("选择自定义CSS文件"),
        select_directory = false,
        select_file = true,
        show_files = true,
        path = H.getHomeDir(),
        file_filter = function(filename)
            return filename:match("%.css$")  -- 只显示CSS文件
        end,
        onConfirm = function(file_path)
            Backend:HandleResponse(Backend:setCustomCSSPath(file_path), function(data)
                MessageBox:notice("自定义CSS设置成功")
                -- 更新所有书籍的CSS缓存
                self:updateAllBookCSS()
            end, function(err_msg)
                MessageBox:error('设置失败：', err_msg)
            end)
        end,
    })
end

function LibraryView:updateAllBookCSS()
    -- 获取所有书籍并更新其CSS
    local EpubHelper = require("Legado/EpubHelper")
    UIManager:nextTick(function()
        MessageBox:loading("更新样式中...", function()
            local bookinfos = Backend:getBookShelfCache()
            if H.is_tbl(bookinfos) then
                for _, bookinfo in ipairs(bookinfos) do
                    if bookinfo.cache_id then
                        EpubHelper.updateCssRes(bookinfo.cache_id)
                    end
                end
            end
            return true
        end, function(state, response)
            if state then
                MessageBox:notice("样式更新完成")
            else
                MessageBox:error("样式更新失败")
            end
        end)
    end)
end

function LibraryView:openMenu(dimen)
    local dialog
    self:getInstance()
    local unified_align = dimen and "left" or "center"
    local settings = Backend:getSettings()
    local buttons = {{},{{
        text = Icons.FA_GLOBE .. " Legado WEB 配置",
        callback = function()
            UIManager:close(dialog)
            self:openWebConfigManager()
        end,
        align = unified_align,
    }}, {{
        text = string.format("%s 流式漫画模式  %s", Icons.FA_BOOK,
            (settings.stream_image_view and Icons.UNICODE_STAR or Icons.UNICODE_STAR_OUTLINE)),
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm(string.format(
                "当前模式: %s \r\n \r\n缓存模式: 边看边下载。\n缺点：占空间。\n优点：预加载后相对流畅。\r\n \r\n流式：不下载到磁盘。\n缺点：对网络要求较高且画质缺少优化，需要下载任一章节后才能开启（建议服务端开启图片代理）。\n优点：不占空间。",
                (settings.stream_image_view and '[流式]' or '[缓存]')), function(result)
                if result then
                    settings.stream_image_view = not settings.stream_image_view or nil
                    Backend:HandleResponse(Backend:saveSettings(settings), function(data)
                        MessageBox:notice("设置成功")
                        self:closeMenu()
                    end, function(err_msg)
                        MessageBox:error('设置失败:', err_msg)
                    end)
                end
            end, {
                ok_text = "切换",
                cancel_text = "取消"
            })
        end,
        align = unified_align,
    }}, {{
        text = string.format("%s 自动上传阅读进度  %s", Icons.FA_CLOUD,
            (settings.sync_reading and Icons.UNICODE_STAR or Icons.UNICODE_STAR_OUTLINE)),
        callback = function()
            UIManager:close(dialog)
            local ok_msg = "设置已开启"
            if settings.sync_reading then
                    ok_msg = "设置已关闭"
            end
            settings.sync_reading = not settings.sync_reading or nil
            Backend:HandleResponse(Backend:saveSettings(settings), function(data)
                MessageBox:notice(ok_msg)
            end, function(err_msg)
                MessageBox:error('设置失败:', err_msg)
            end)
        end,
        align = unified_align,
    }}, {{
        text = string.format("%s 自动生成快捷方式  %s", Icons.FA_FOLDER,
            (settings.disable_browser and Icons.UNICODE_STAR_OUTLINE or Icons.UNICODE_STAR)),
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm(string.format(
                "自动生成快捷方式：%s \r\n \r\n 打开书籍目录时自动在文件浏览器 Home 目录中生成对应书籍快捷方式，支持封面显示, 关闭后可在书架菜单手动生成",
                (settings.disable_browser and '[关闭]' or '[开启]')), function(result)
                if result then
                    local ok_msg = "设置已开启"
                    if not settings.disable_browser then
                        ok_msg = "设置已关闭，请手动删除目录"
                    end
                    settings.disable_browser = not settings.disable_browser or nil
                    Backend:HandleResponse(Backend:saveSettings(settings), function(data)
                        MessageBox:notice(ok_msg)
                    end, function(err_msg)
                        MessageBox:error('设置失败:', err_msg)
                    end)
                end
            end, {
                ok_text = "切换",
                cancel_text = "取消"
            })
        end,
        align = unified_align,
    }}, {{
        text = string.format("%s 自定义CSS样式  %s", Icons.FA_PAINT_BRUSH,
            (Backend:isCustomCSSEnabled() and Icons.UNICODE_STAR or Icons.UNICODE_STAR_OUTLINE)),
        callback = function()
            UIManager:close(dialog)
            local current_css = Backend:getCustomCSSPath()
            local dialog_buttons = {{{
                text = "选择CSS文件",
                callback = function()
                    self:selectCustomCSS()
                end
            }}}
            
            if current_css then
                table.insert(dialog_buttons, {{
                    text = "移除自定义CSS",
                    callback = function()
                        Backend:HandleResponse(Backend:clearCustomCSSPath(), function(data)
                            MessageBox:notice("已恢复默认CSS样式")
                            self:updateAllBookCSS()
                        end, function(err_msg)
                            MessageBox:error('操作失败：', err_msg)
                        end)
                    end
                }})
                table.insert(dialog_buttons, {{
                    text = "重新应用CSS",
                    callback = function()
                        self:updateAllBookCSS()
                    end
                }})
            end
            
            local css_dialog = require("ui/widget/buttondialog"):new{
                title = string.format("当前CSS：%s", current_css and "自定义" or "默认"),
                title_align = "center",
                buttons = dialog_buttons,
            }
            UIManager:show(css_dialog)
        end,
        align = unified_align,
    }}, {{
        text = string.format("%s Clear all caches", Icons.FA_TRASH),
        callback = function()
            UIManager:close(dialog)
            MessageBox:confirm(
                "是否清空本地书架所有已缓存章节与阅读记录？\r\n（刷新会重新下载）",
                function(result)
                    if result then
                        Backend:closeDbManager()
                        MessageBox:loading("清除中", function()
                            return Backend:cleanAllBookCaches()
                        end, function(state, response)
                            if state == true then
                                Backend:HandleResponse(response, function(data)
                                    settings.servers_history = {}
                                    Backend:saveSettings(settings)
                                    MessageBox:notice("已清除")
                                    self:closeMenu()
                                end, function(err_msg)
                                    MessageBox:error('操作失败：', tostring(err_msg))
                                end)
                            end
                        end)
                    end
                end, {
                    ok_text = "清空",
                    cancel_text = "取消"
                })
        end,
        align = unified_align,
    }}, {{
        text = Icons.FA_QUESTION_CIRCLE .. ' ' .. "关于/更新",
        callback = function()
            UIManager:close(dialog)
            local about_txt = [[
-- 清风不识字，何故乱翻书 --

简介：
一个在 KOReader 中阅读 Legado 书库的插件，适配阅读 3.0，支持手机 APP 和服务器版本。初衷是 Kindle 的浏览器体验不佳，目的是部分替代受限设备的浏览器，实现流畅的网文阅读，提升老设备体验。

操作：
列表支持下拉或 Home 键刷新，右键列表菜单 / Menu 键左上角菜单，阅读界面下拉菜单有返回选项，书架和目录可绑定手势使用。

章节页面图标说明:
%1 可下载  %2 已阅读  %3 阅读进度

帮助改进：
请到 Github：pengcw/legado.koplugin 反馈 issues

版本: ver_%4]]
            local legado_update = require("Legado.Update")
            local curren_version = legado_update:getCurrentPluginVersion() or ""
            about_txt = T(about_txt, Icons.FA_DOWNLOAD, Icons.FA_CHECK_CIRCLE, Icons.FA_THUMB_TACK, curren_version)
            MessageBox:custom({
                text = about_txt,
                alignment = "left"
            })

            UIManager:nextTick(function()
                Backend:checkOta(true)
            end)
        end,
        align = unified_align,
    }}}

    if not Device:isTouchDevice() then
        table.insert(buttons, #buttons, {{
            text = Icons.FA_REFRESH .. ' ' .. " 同步书架",
            callback = function()
                UIManager:close(dialog)
                self:onRefreshLibrary()
            end,
            align = unified_align,
        }})
    end

    if not self.disk_available then
        local cache_dir = H.getTempDirectory()
        local disk_use = util.diskUsage(cache_dir)
        if disk_use and disk_use.available then
            self.disk_available = disk_use.available / 1073741824
        end
    end

    dialog = require("ui/widget/buttondialog"):new{
        title = string.format(Icons.FA_DATABASE .. " Free: %.1f G", self.disk_available or -1),
        title_align = unified_align,
        title_face = Font:getFace("x_smalltfont"),
        info_face = Font:getFace("tfont"),
        buttons = buttons,
        shrink_unneeded_width = dimen and true,
        anchor = dimen and function()
            return dimen
        end or nil,
    }

    UIManager:show(dialog)
end

function LibraryView:openSearchBooksDialog(def_search_input)
    require("Legado/BookSourceResults"):searchAndShow(function()
        self:onRefreshLibrary()
    end, def_search_input)
end

-- exit readerUI,  closing the at readerUI、FileManager the same time app will exit
-- readerUI -> ReturnLegadoChapterListing event -> show ChapterListing -> close ->show LibraryView ->close -> ? 
function LibraryView:openLegadoFolder(path, focused_file, selected_files, done_callback)
    UIManager:nextTick(function()
        if ReaderUI and ReaderUI.instance then
            ReaderUI.instance:onClose()
            self.readerui_is_showing = false
        end
        if FileManager.instance then
            FileManager.instance:reinit(path, focused_file, selected_files)
        else
            FileManager:showFiles(path, focused_file, selected_files)
        end
        if FileManager.instance and path then
            FileManager.instance:updateTitleBarPath(path)
        end
        if H.is_func(done_callback) then
            done_callback()
        end
    end)
end

function LibraryView:afterCloseReaderUi(callback)
    self:openLegadoFolder(nil, nil, nil, callback)
end

function LibraryView:loadAndRenderChapter(chapter)

    local cache_chapter = Backend:getCacheChapterFilePath(chapter)

    if (H.is_tbl(cache_chapter) and H.is_str(cache_chapter.cacheFilePath)) then
        self:showReaderUI(cache_chapter)
    else
        Backend:closeDbManager()
        return MessageBox:loading("正在下载正文", function()
            return Backend:downloadChapter(chapter)
        end, function(state, response)
            if state == true then
                Backend:HandleResponse(response, function(data)
                    if not H.is_tbl(data) or not H.is_str(data.cacheFilePath) then
                        MessageBox:error('下载失败')
                        return
                    end
                    self:showReaderUI(data)
                end, function(err_msg)
                    MessageBox:notice("请检查并刷新书架")
                    MessageBox:error(err_msg or '错误')
                end)
            end

        end)
    end
end

function LibraryView:ReaderUIEventCallback(chapter_call_event)
    if not (H.is_str(chapter_call_event) and H.is_tbl(self.displayed_chapter)) then
        return
    end
    local chapter = self.displayed_chapter
    self.chapter_call_event = chapter_call_event
    chapter.call_event = chapter_call_event

    local nextChapter = Backend:findNextChapter({
        chapters_index = chapter.chapters_index,
        call_event = chapter.call_event,
        book_cache_id = chapter.book_cache_id,
        totalChapterNum = chapter.totalChapterNum
    })
 
    if H.is_tbl(nextChapter) then
        nextChapter.call_event = chapter.call_event
        self:loadAndRenderChapter(nextChapter)
    else
        local bookinfo = (self.book_toc and H.is_tbl(self.book_toc.bookinfo)) 
            and self.book_toc.bookinfo 
            or Backend:getBookInfoCache(chapter.book_cache_id)

        self:afterCloseReaderUi(function()
            self:showBookTocDialog(bookinfo)
        end)
    end
end

function LibraryView:showReaderUI(chapter)
    if not (H.is_tbl(chapter) and H.is_str(chapter.cacheFilePath)) then
        return
    end
    local book_path = chapter.cacheFilePath
    if not util.fileExists(book_path) then
        return MessageBox:error(book_path, "不存在")
    end
    self.displayed_chapter = chapter

    if self.book_toc and UIManager:isWidgetShown(self.book_toc) then
        UIManager:close(self.book_toc)
    end
    if ReaderUI.instance then
        ReaderUI.instance:switchDocument(book_path, true)
    else
        UIManager:broadcastEvent(Event:new("SetupShowReader"))
        ReaderUI:showReader(book_path, nil, true)
    end
    UIManager:nextTick(function()
        Backend:after_reader_chapter_show(chapter)
    end)
end

function LibraryView:openLastReadChapter(bookinfo)
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then
        logger.err("openLastReadChapter parameter error")
        return false
    end

    local book_cache_id = bookinfo.cache_id
    local last_read_chapter = Backend:getLastReadChapter(book_cache_id)
    -- default 0
    if H.is_num(last_read_chapter) then

        local chapters_index = last_read_chapter - 1
        if chapters_index < 0 then
            chapters_index = 0
        end

        local chapter = Backend:getChapterInfoCache(book_cache_id, chapters_index)
        if H.is_tbl(chapter) and chapter.chapters_index then
            -- jump to the reading position
            chapter.call_event = "next"
            self:loadAndRenderChapter(chapter)
        else
            -- chapter does not exist, request refresh
            self:showBookTocDialog(bookinfo)
            MessageBox:notice('请同步刷新目录数据')
        end
        
        return true
    end 
end

function LibraryView:initializeRegisterEvent(parent_ref)
    local DocSettings = require("docsettings")
    local FileManager = require("apps/filemanager/filemanager")
    local util = require("util")
    local logger = require("logger")
    local Event = require("ui/event")
    local UIManager = require("ui/uimanager")
    local ChapterListing = require("Legado/ChapterListing")
    local Backend = require("Legado/Backend")
    local H = require("Legado/Helper")

    local library_view_ref = self

    local is_legado_path = function(file_path, instance)
        if instance and instance.document and instance.document.file then
            file_path = instance.document.file
        end
        return type(file_path) == 'string' and file_path:lower():find('/cache/legado.cache/', 1, true) or false
    end
    local is_legado_browser_path = function(file_path, instance)
        if instance and instance.document and instance.document.file then
            file_path = instance.document.file
        end
        return type(file_path) == 'string' and file_path:find("/Legado\u{200B}书目/", 1, true) or false
    end
    local get_chapter_event = function()
        if library_view_ref.instance then
            return library_view_ref.instance.chapter_call_event
        end
    end

    function parent_ref:onShowLegadoLibraryView()
        -- FileManager menu only
        if not (self.ui and self.ui.document) then
            self:openLibraryView()
        end
        return true
    end

    function parent_ref:_loadBookFromManager(file, undoFileOpen)

        local loading_msg = MessageBox:info("前往最近阅读章节...", 3)

        -- prioritize using custom matedata book_cache_id
        local doc_settings = DocSettings:open(file)
        local book_cache_id = doc_settings:readSetting("book_cache_id")

        if not book_cache_id then
            local ok, lnk_config = pcall(Backend.getLuaConfig, Backend, file)
            if ok and lnk_config then
                book_cache_id = lnk_config:readSetting("book_cache_id")
            end
        end

        -- unrecognized file
        if not H.is_str(book_cache_id) then
            UIManager:close(loading_msg)
            return undoFileOpen and undoFileOpen(file)
        end

        library_view_ref:getInstance()
        local library_view_instance = library_view_ref.instance

        if not library_view_instance then
            logger.warn("oadLastReadChapter LibraryView instance not loaded")
            UIManager:close(loading_msg)
            MessageBox:error("加载书架失败")
            return
        end

        local bookinfo = Backend:getBookInfoCache(book_cache_id)
        if not (H.is_tbl(bookinfo) and H.is_num(bookinfo.durChapterIndex)) then
            UIManager:close(loading_msg)
            -- no sync
            self:onShowLegadoLibraryView()
            MessageBox:notice("书籍不存在于书架,请刷新同步")
            return
        end

        local onReturnCallBack = function()
            -- local dir = library_view_instance:getBrowserHomeDir()
            -- Sometimes LibraryView instance may not start
            -- library_view_ref:openLegadoFolder(dir)
        end

        library_view_instance:refreshBookTocWidget(bookinfo, onReturnCallBack)
        library_view_instance.selectetrued_item = {cache_id = book_cache_id}

        library_view_instance:openLastReadChapter(bookinfo)
        UIManager:close(loading_msg)
        return true
    end

    function parent_ref:onShowLegadoToc(book_cache_id)
        library_view_ref:getInstance()
        local library_view_instance = library_view_ref.instance

        if not library_view_instance then
            logger.warn("ShowLegadoToc LibraryView instance not loaded")
            return true
        end
        if not book_cache_id then
            if library_view_instance.displayed_chapter then
                book_cache_id = library_view_instance.displayed_chapter.book_cache_id
            elseif library_view_instance.book_toc and 
                    library_view_instance.book_toc.bookinfo then
                book_cache_id = library_view_instance.book_toc.bookinfo.cache_id
            elseif library_view_instance.selected_item then
                book_cache_id = library_view_instance.selected_item.cache_id
            end
        end
        if not book_cache_id then
            logger.warn("ShowLegadoToc book_cache_id not obtained")
            return true
        end

        local bookinfo = Backend:getBookInfoCache(book_cache_id)
        if not (H.is_tbl(bookinfo) and H.is_num(bookinfo.durChapterIndex)) then
            MessageBox:error('书籍不存在于当前 Legado 书库或已被删除, 请检查并同步书库')
            return
        end

        library_view_instance:showBookTocDialog(bookinfo)
        return true
    end

    local calculate_goto_page = function(chapter_call_event, page_count)
        if chapter_call_event == "next" then
            return 1
        elseif page_count and chapter_call_event == "pre" then
            return page_count
        end
    end
    function parent_ref:onDocSettingsLoad(doc_settings, document)
        if not (doc_settings and doc_settings.data and document) then
            return
        end
        if is_legado_path(document.file) then

            local directory, file_name = util.splitFilePathName(document.file)
            local _, extension = util.splitFileNameSuffix(file_name or "")
            if not (directory and file_name and directory ~= "" and file_name ~= "") then
                return
            end

            local book_defaults_path = H.joinPath(directory, "book_defaults.lua")
            -- document.is_new = nil ? at readerui
            local document_is_new = (document.is_new == true) or doc_settings:readSetting("doc_props") == nil
            if document_is_new then
                doc_settings:saveSetting("legado_doc_is_new", true)
            end

            if util.fileExists(book_defaults_path) then
                local book_defaults = Backend:getLuaConfig(book_defaults_path)
                if book_defaults and H.is_tbl(book_defaults.data) then
                    local summary = doc_settings.data.summary -- keep status
                    local book_defaults_data = util.tableDeepCopy(book_defaults.data)
                    for k, v in pairs(book_defaults_data) do
                        doc_settings.data[k] = v
                    end
                    doc_settings.data.doc_path = document.file
                    doc_settings.data.summary = doc_settings.data.summary or summary
                end
            end

            if extension == 'txt' then
                doc_settings.data.txt_preformatted = 0
                doc_settings.data.style_tweaks = doc_settings.data.style_tweaks or {}
                doc_settings.data.style_tweaks.paragraph_whitespace_half = true
                doc_settings.data.style_tweaks.paragraphs_indent = true
                doc_settings.data.css = "./data/fb2.css"
            end

            -- statistics.koplugin
            if document then
                document.is_pic = true
            end
            -- Does it affect the future ？
            --[=[
                    if document_is_new then  
                        local bookinfo = library_view_ref.instance.book_toc.bookinfo
                        doc_settings.data.doc_props = doc_settings.data.doc_props or {}
                        doc_settings.data.doc_props.title = bookinfo.name or "N/A"
                        doc_settings.data.doc_props.authors = bookinfo.author or "N/A"
                    end
                ]=]

            -- current_page == nil
            -- self.ui.document:getPageCount() unreliable, sometimes equal to 0
            local chapter_call_event = get_chapter_event()
            local page_count = doc_settings:readSetting("doc_pages") or 99999
            -- koreader some cases is goto last_page
            local page_number = calculate_goto_page(chapter_call_event, page_count)
            if H.is_num(page_number) then
                doc_settings.data.last_page = page_number
            end

        elseif is_legado_browser_path(document.file) and doc_settings.data then
            doc_settings.data.provider = "legado"
        end
    end
    -- or UIManager:flushSettings() --onFlushSettings
    function parent_ref:onSaveSettings()
        if not (self.ui and self.ui.doc_settings) then
            return
        end
        local filepath = self.ui.document and self.ui.document.file or self.ui.doc_settings:readSetting("doc_path")
        if is_legado_path(filepath) then

            local directory, file_name = util.splitFilePathName(filepath)
            if not is_legado_path(directory) then
                return
            end
            -- logger.dbg("Legado: Saving reader settings...")
            if self.ui.doc_settings and type(self.ui.doc_settings.data) == 'table' then
                local persisted_settings_keys = require("Legado/BookMetaData")
                local book_defaults_path = H.joinPath(directory, "book_defaults.lua")
                local book_defaults = Backend:getLuaConfig(book_defaults_path)
                local doc_settings_data = util.tableDeepCopy(self.ui.doc_settings.data)
                local is_updated

                for k, v in pairs(doc_settings_data) do
                    if persisted_settings_keys[k] and not H.deep_equal(book_defaults.data[k], v) then
                        book_defaults.data[k] = v
                        is_updated = true
                        -- logger.info("onSaveSettings save k v", k, v)
                    end
                end
                if is_updated == true then
                    book_defaults:flush()
                end
            end
        elseif is_legado_browser_path(nil, self.ui) and self.ui.doc_settings then
            self.ui.doc_settings.data.provider = "legado"
        end
    end

    -- .cbz call twice ?
    function parent_ref:onReaderReady(doc_settings)
        -- logger.dbg("document.is_pic",self.ui.document.is_pic)
        -- logger.dbg(doc_settings.data.summary.status)
        if not (doc_settings and doc_settings.data and self.ui) then
            return
        end

        if not is_legado_path(nil, self.ui) then
            if library_view_ref.instance then
                library_view_ref.instance.readerui_is_showing = false
            end
            return
        elseif self.ui.link and self.ui.document then

            if library_view_ref.instance then
                library_view_ref.instance.readerui_is_showing = true
            end

            local chapter_call_event = get_chapter_event()
            if not chapter_call_event then
                return
            end

            local document_is_new =
                (self.ui.document.is_new == true) or doc_settings:readSetting("legado_doc_is_new") == true
            doc_settings:delSetting("legado_doc_is_new")
            if document_is_new and chapter_call_event == "next" then
                return
            end

            local function make_pages_continuous(chapter_event)
                local current_page = self.ui:getCurrentPage()
                if not current_page or current_page == 0 then
                    -- fallback to another method if current_page is unavailable
                    -- self.ui.document.info.has_pages == self.ui.paging
                    if self.ui.paging or (self.ui.document.info and self.ui.document.info.has_pages) then
                        current_page = self.view.state.page
                    else
                        current_page = self.ui.document:getXPointer()
                        current_page = self.ui.document:getPageFromXPointer(current_page)
                    end
                end

                local page_count = self.ui.document:getPageCount()
                if not (H.is_num(page_count) and page_count > 0) then
                    page_count = doc_settings:readSetting("doc_pages")
                end

                local page_number = calculate_goto_page(chapter_event, page_count)

                if H.is_num(page_number) and current_page ~= page_number then
                    self.ui.link:addCurrentLocationToStack()
                    self.ui:handleEvent(Event:new("GotoPage", page_number))
                end
            end
            make_pages_continuous(chapter_call_event)
        end
    end

    function parent_ref:onCloseDocument()
        if is_legado_path(nil, self.ui) then
            if library_view_ref.instance then
                library_view_ref.instance.readerui_is_showing = false
            end
            if not self.patches_ok then
                require("readhistory"):removeItemByPath(self.document.file)
            end
        end
    end

    function parent_ref:onShowLegadoSearch()
        local def_search_input
        if self.ui and self.ui.doc_settings and self.ui.doc_settings.data.doc_props then
            local doc_props = self.ui.doc_settings.data.doc_props
            def_search_input = doc_props.authors or doc_props.title
        end

        require("Legado/BookSourceResults"):searchAndShow(function()
            self:openLibraryView()
        end, def_search_input)

        return true
    end

    function parent_ref:onEndOfBook()
        if is_legado_path(nil, self.ui) then
            library_view_ref:getInstance()
            if library_view_ref.instance then
                local chapter_call_event = "next"
                library_view_ref.instance:ReaderUIEventCallback(chapter_call_event)
            else
                self:openLibraryView()
            end
            return true
        end
    end

    function parent_ref:onStartOfBook()
        if is_legado_path(nil, self.ui) then
            library_view_ref:getInstance()
            if library_view_ref.instance then
                local chapter_call_event = "pre"
                library_view_ref.instance:ReaderUIEventCallback(chapter_call_event)
            else
                self:openLibraryView()
            end
            return true
        end
    end

    function parent_ref:onShowLegadoBrowserOption(file)
        -- logger.info("Received ShowLegadoBrowserOption event", file)
        library_view_ref:getInstance()
        if FileManager.instance and library_view_ref.instance then
            library_view_ref.instance:openBrowserMenu(file)
        end
    end

    function parent_ref:onSuspend()
        Backend:closeDbManager()
    end

    table.insert(parent_ref.ui, 3, parent_ref)

    function parent_ref:openFile(file)
        if not H.is_str(file) then
            return
        end
        local function open_regular_file(file)
            local ReaderUI = require("apps/reader/readerui")
            UIManager:broadcastEvent(Event:new("SetupShowReader"))
            ReaderUI:showReader(file, nil, true)
        end
        if not (is_legado_browser_path(file) and file:find("\u{200B}.html", 1, true)) then
            open_regular_file(file)
            return
        end
        local ok, err = pcall(function() 
            self:_loadBookFromManager(file, open_regular_file)
        end)
        if not ok then
            logger.err("fail to open file:", err)
        end
        return true
    end
end

local function init_book_browser(parent)
    if parent.book_browser then
        return parent.book_browser
    end

    local book_browser = {
        parent = parent
    }

    function book_browser:show_view(focused_file, selected_files)
        local homedir = self.parent:getBrowserHomeDir()
        if not homedir then
            return
        end
        local current_dir = self.parent:getBrowserCurrentDir()
        if current_dir and current_dir == homedir then
            if not self.parent.book_menu then
                self.parent.book_menu = self.parent:getMenuWidget()
            end
            self.parent.book_menu:show_view()
            self.parent.book_menu:refreshItems(true)
            return
        end
        self.parent:openLegadoFolder(homedir, focused_file, selected_files)
    end

    function book_browser:goHome()
        if FileManager.instance then
            FileManager.instance:goHome()
        end
    end

    function book_browser:refreshItems()
        if FileManager.instance then
            FileManager.instance:onRefresh()
        end
    end

    function book_browser:deleteFile(file, is_file)
        self.parent:deleteFile(file, is_file)
    end
    function book_browser:verifyBooksMetadata()
        -- possible cover name change
        local browser_homedir = self.parent:getBrowserHomeDir()
        if not util.directoryExists(browser_homedir) then
            return
        end

        local function is_valid_book_file(fullpath, name)
            return util.fileExists(fullpath) and H.is_str(name) and name:find("\u{200B}.html", 1, true)
        end

        local function get_book_id(fullpath)
            local ok, lnk_config = pcall(Backend.getLuaConfig, Backend, fullpath)
            if ok and H.is_tbl(lnk_config) and lnk_config.readSetting then
                return lnk_config:readSetting("book_cache_id")
            end
            local doc_settings = DocSettings:open(fullpath)
            return doc_settings:readSetting("book_cache_id")
        end

        util.findFiles(browser_homedir, function(fullpath, name)
            if not is_valid_book_file(fullpath, name) then
                goto continue
            end

            local book_cache_id = get_book_id(fullpath)
            if not book_cache_id then
                self:deleteFile(fullpath, true)
                goto continue
            end

            local bookinfo = Backend:getBookInfoCache(book_cache_id)
            if not (H.is_tbl(bookinfo) and bookinfo.name) then
                self:deleteFile(fullpath, true)
                goto continue
            end

            self:refreshBookMetadata(nil, fullpath, bookinfo)
            ::continue::
        end, true)
    end

    function book_browser:wirteLnk(bookinfo)
        local home_dir = self.parent:getBrowserHomeDir()
        if not (home_dir and H.is_tbl(bookinfo) and bookinfo.name and bookinfo.cache_id) then
            logger.err("book_browser.wirteLnk: parameter error")
            return
        end

        local book_cache_id = bookinfo.cache_id
        local book_name = bookinfo.name
        local book_author = bookinfo.author or "未知作者"

        local book_lnk_name = string.format("%s-%s\u{200B}.html", book_name, book_author)
        book_lnk_name = util.getSafeFilename(book_lnk_name)
        if not book_lnk_name then
            logger.err("book_browser.wirteLnk: getSafeFilename error")
            return
        end
        local book_lnk_path = H.joinPath(home_dir, book_lnk_name)
        if book_lnk_path and util.fileExists(book_lnk_path) then
            return book_lnk_path, book_lnk_name
        end

        local book_lnk_config = Backend:getLuaConfig(book_lnk_path)
        book_lnk_config:saveSetting("book_cache_id", book_cache_id):flush()

        return book_lnk_path, book_lnk_name
    end

    function book_browser:getCustomMateData(filepath)
        local custom_metadata_file = DocSettings:findCustomMetadataFile(filepath)
        return custom_metadata_file and DocSettings.openSettingsFile(custom_metadata_file):readSetting("custom_props")
    end

    function book_browser:addBookShortcut(bookinfo)
        local home_dir = self.parent:getBrowserHomeDir()
        if not (home_dir and H.is_tbl(bookinfo) and bookinfo.name and bookinfo.cache_id and bookinfo.coverUrl) then
            logger.err("addBookShortcut: parameter error")
            return
        end

        local book_lnk_path, book_lnk_name = self:wirteLnk(bookinfo)
        if not (book_lnk_path and util.fileExists(book_lnk_path)) then
            logger.err("addBookShortcut: failed to create lnk")
            return
        end

        if not self:getCustomMateData(book_lnk_path) then
            self:refreshBookMetadata(book_lnk_name, book_lnk_path, bookinfo)
        else
            self:bind_provider(book_lnk_path)
        end

        if DocSettings:findCustomCoverFile(book_lnk_path) then
            return
        end

        if not NetworkMgr:isConnected() then
            return
        end
        local book_cache_id = bookinfo.cache_id
        local cover_url = bookinfo.coverUrl
        if cover_url then
            Backend:runTaskWithRetry(function()
                if DocSettings:findCustomCoverFile(book_lnk_path) then
                    self:emitMetadataChanged(book_lnk_path)
                    return true
                end
            end, 12000, 2000)
            Backend:launchProcess(function()
                local cover_path, cover_name = Backend:download_cover_img(book_cache_id, cover_url)
                if cover_path and util.fileExists(cover_path) then
                    DocSettings:flushCustomCover(book_lnk_path, cover_path)
                end
            end)
        end
    end

    function book_browser:emitMetadataChanged(path)
        --[[
        local prop_updated = {
            filepath = file,
            doc_props = book_props,
            metadata_key_updated = prop_updated,
            metadata_value_old = prop_value_old,
        }
        ]]
        UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", path))
        UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
    end

    function book_browser:bind_provider(file)
        local doc_settings = DocSettings:open(file)
        local provider = doc_settings:readSetting("provider")
        if provider ~= "legado" then
            doc_settings:saveSetting("provider", "legado"):flush()
        end
        return doc_settings
    end

    function book_browser:refreshBookMetadata(lnk_name, lnk_path, bookinfo)
        lnk_name = lnk_name or (H.is_str(lnk_path) and select(2, util.splitFilePathName(lnk_path)))
        if not (util.fileExists(lnk_path) and H.is_str(lnk_name) and H.is_tbl(bookinfo) and bookinfo.cache_id and
            bookinfo.name) then
            logger.err("browser.refreshBookMetadata parameter error")
            return
        end

        local book_cache_id = bookinfo.cache_id
        local doc_settings = self:bind_provider(lnk_path)
        if doc_settings and doc_settings.data then
            doc_settings.data = {}
            doc_settings:saveSetting("custom_props", {
                authors = bookinfo.author,
                title = bookinfo.name,
                description = bookinfo.intro
            })
            doc_settings:saveSetting("book_cache_id", book_cache_id)
            doc_settings:saveSetting("doc_props", {
                pages = 1
            }):flushCustomMetadata(lnk_path)
        end

        self:emitMetadataChanged(lnk_path)
    end

    parent.book_browser = book_browser
    return book_browser
end

local function init_book_menu(parent)
    if parent.book_menu then
        return parent.book_menu
    end
    local book_menu = Menu:new{
        name = "library_view",
        -- is_enable_shortcut = false,
        title = "书架",
        with_context_menu = true,
        align_baselines = true,
        covers_fullscreen = true, -- hint for UIManager:_repaint()
        is_borderless = true,
        title_bar_left_icon = "appbar.menu",
        title_bar_fm_style = true,
        width = Device.screen:getWidth(),
        height = Device.screen:getHeight(),
        close_callback = function()
            Backend:closeDbManager()
        end,
        show_search_item = nil,
        refresh_menu_key = nil,
        parent_ref = parent,
    }

    if Device:hasKeys() then
        book_menu.refresh_menu_key = "Home"
        if Device:hasKeyboard() then
            book_menu.refresh_menu_key = "F5"
        end
        book_menu.key_events.RefreshChapters = { { book_menu.refresh_menu_key } }
    end
    if Device:hasDPad() then
        book_menu.key_events.FocusRight = {{ "Right" }}
        book_menu.key_events.Right = nil
    end

    function book_menu:onLeftButtonTap()
        local dimen
        if self.title_bar and self.title_bar.left_button and self.title_bar.left_button.image then
            dimen = self.title_bar.left_button.image.dimen
        end
        parent:openMenu(dimen)
    end
    function book_menu:onFocusRight()
        local focused_widget = Menu.getFocusItem(self)
        if focused_widget then

            local point = focused_widget.dimen:copy()
            point.x = point.x + point.w
            point.y = point.y + point.h / 2
            point.w = 0
            point.h = 0
            UIManager:sendEvent(Event:new("Gesture", {
                ges = "tap",
                pos = point
            }))
            return true
        end
    end
    function book_menu:onSwipe(arg, ges_ev)
        local direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction)
        if direction == "south" then
            NetworkMgr:runWhenOnline(function()
                self:onRefreshLibrary()
            end)
            return
        end
        Menu.onSwipe(self, arg, ges_ev)
    end

    function book_menu:refreshItems(no_recalculate_dimen)
        local books_cache_data = Backend:getBookShelfCache()
        if H.is_tbl(books_cache_data) and #books_cache_data > 0 then
            self.item_table = self:generateItemTableFromMangas(books_cache_data)
            self.multilines_show_more_text = false
            self.items_per_page = nil
        else
            self.item_table = self:generateEmptyViewItemTable()
            self.multilines_show_more_text = true
            self.items_per_page = 1
        end
        self:updateItems(nil, no_recalculate_dimen)
    end

    function book_menu:onPrimaryMenuChoice(item)
        if not item.cache_id then
            require("Legado/BookSourceResults"):searchAndShow(function()
                self:onRefreshLibrary()
            end)
            return
        end
        
        local bookinfo = Backend:getBookInfoCache(item.cache_id)
        self.parent_ref.selected_item = item

        if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then
            return MessageBox:error("书籍信息查询出错")
        end

        local onReturnCallBack = function()
            self:show_view()
            self:refreshItems(true)
        end

        local update_toc_visibility = function()
            self.parent_ref:refreshBookTocWidget(bookinfo, onReturnCallBack, true)
        end

        update_toc_visibility()
        self:onClose()
        --self.parent_ref:openLastReadChapter(bookinfo, on_return_callback)
        
        UIManager:nextTick(function()
            Backend:autoPinToTop(bookinfo.cache_id, bookinfo.sortOrder)
            self.parent_ref:addBkShortcut(bookinfo)
        end)
    end

    function book_menu:onRefreshLibrary()
            Backend:closeDbManager()
            MessageBox:loading("Refreshing Library", function()
                return Backend:refreshLibraryCache(parent.ui_refresh_time)
            end, function(state, response)
                if state == true then
                    Backend:HandleResponse(response, function(data)
                        MessageBox:notice('同步成功')
                        self.show_search_item = true
                        self:refreshItems()
                        self.parent_ref.ui_refresh_time = os.time()
                    end, function(err_msg)
                        MessageBox:notice(response.message or '同步失败')
                    end)
                end
            end)
    end

    function book_menu:onMenuHold(item)
        if not item.cache_id then
            self.parent_ref:openSearchBooksDialog()
            return
        end
        local bookinfo = Backend:getBookInfoCache(item.cache_id)
        local msginfo = [[
书名： <<%1>>
作者： %2
分类： %3
书源： %4
总章数：%5
总字数：%6
简介：%7
    ]]

        msginfo = T(msginfo, bookinfo.name or '', bookinfo.author or '', bookinfo.kind or '', bookinfo.originName or '',
            bookinfo.totalChapterNum or '', bookinfo.wordCount or '', bookinfo.intro or '')

        MessageBox:confirm(msginfo, nil, {
            icon = "notice-info",
            no_ok_button = true,
            other_buttons_first = true,
            other_buttons = {{{
                text = (bookinfo.sortOrder > 0) and '置顶书籍' or '取消置顶',
                callback = function()
                    Backend:manuallyPinToTop(item.cache_id, bookinfo.sortOrder)
                    self:refreshItems(true)
                end
            }}, {{
                text = "快捷方式",
                callback = function()
                    UIManager:nextTick(function()
                        self.parent_ref:addBkShortcut(bookinfo, true)
                    end)
                    MessageBox:notice("已调用生成，请到 Home 目录查看")
                end
            }}, {{
                text = '换源',
                callback = function()
                    NetworkMgr:runWhenOnline(function()
                        require("Legado/BookSourceResults"):fetchAndShow(bookinfo, function()
                            self:onRefreshLibrary()
                        end)
                    end)
                end
            }}, {{
                text = '删除',
                callback = function()
                    MessageBox:confirm(string.format(
                        "是否删除 <<%s>>？\r\n删除后关联记录会隐藏，重新添加可恢复",
                        bookinfo.name), function(result)
                        if result then
                            Backend:closeDbManager()
                            MessageBox:loading("删除中...", function()
                                Backend:deleteBook(bookinfo)
                                return Backend:refreshLibraryCache()
                            end, function(state, response)
                                if state == true then
                                    Backend:HandleResponse(response, function(data)
                                        MessageBox:notice("删除成功")
                                        self:refreshItems(true)
                                    end, function(err_msg)
                                        MessageBox:error('删除失败：', err_msg)
                                    end)
                                end
                            end)
                        end
                    end, {
                        ok_text = "删除",
                        cancel_text = "取消"
                    })

                end
            }}}
        })

    end

    function book_menu:onMenuSelect(entry, pos)
        if entry.select_enabled == false then
            return true
        end
        local selected_context_menu = pos ~= nil and pos.x > 0.8
        if selected_context_menu then
            self:onMenuHold(entry, pos)
        else
            self:onPrimaryMenuChoice(entry, pos)
        end
        return true
    end

    function book_menu:generateEmptyViewItemTable()
        local hint = (self.refresh_menu_key and not Device:isTouchDevice())
            and string.format("press the %s button", self.refresh_menu_key)
            or "swiping down"
        return {{
            text = string.format("No books found. Try %s to refresh.", hint),
            dim = true,
            select_enabled = false,
        }}
    end

    function book_menu:generateItemTableFromMangas(books)
        local item_table = {}
        if self.show_search_item == true then
            item_table[1] = {
                text = string.format('%s Search...', Icons.FA_MAGNIFYING_GLASS),
                mandatory = "[Go]"
            }
            self.show_search_item = nil
        end

        for _, bookinfo in ipairs(books) do

            local show_book_title = ("%s (%s)[%s]"):format(bookinfo.name or "未命名书籍",
                bookinfo.author or "未知作者", bookinfo.originName)

            table.insert(item_table, {
                cache_id = bookinfo.cache_id,
                text = show_book_title,
                mandatory = Icons.FA_ELLIPSIS_VERTICAL
            })
        end

        return item_table
    end

    function book_menu:show_view()
        UIManager:show(self)
    end

    parent.book_menu = book_menu
    return book_menu
end

function LibraryView:getBrowserHomeDir(skip_check)
    local home_dir = H.getHomeDir()
    if not H.is_str(home_dir) then
        logger.err("LibraryView.getBrowserHomeDir: home_dir is nil")
        return nil
    end
    local browser_dir_name = "Legado\u{200B}书目"
    local expected_path = H.joinPath(home_dir, browser_dir_name)
    -- nil or home_dir changed
    if not H.is_str(self.book_browser_homedir) or self.book_browser_homedir ~= expected_path then
        -- 特殊情况：设置以 browser_dir_name 为主目录
        local clean_home_dir = home_dir:gsub("/+$", "")
        local last_folder = clean_home_dir:match("([^/]+)$")
        if last_folder and last_folder == browser_dir_name then
            self.book_browser_homedir = home_dir
        else
            self.book_browser_homedir = expected_path
        end
    end

    if not skip_check then
        local success, err = pcall(H.checkAndCreateFolder, self.book_browser_homedir)
        if not (success and util.directoryExists(self.book_browser_homedir)) then
            logger.err("LibraryView.getBrowserHomeDir: failed to create directory - " ..
                           tostring(err or "unknown error"))
            return nil
        end
    end
    return self.book_browser_homedir
end

function LibraryView:deleteFile(file, is_file)
    local exists = is_file and util.fileExists(file) or util.directoryExists(file)
    if not exists then
        return false
    end

    if FileManager.instance then
        FileManager.instance:goHome()
        FileManager.instance:deleteFile(file, is_file)
        FileManager.instance:onRefresh()
        return true
    end
    if is_file then
        return util.removeFile(file)
    else
        return pcall(ffiUtil.purgeDir, file)
    end
end

function LibraryView:getBrowserCurrentDir()
    local file_manager = FileManager.instance
    if file_manager and file_manager.file_chooser then
        return file_manager.file_chooser.path
    end
    local readerui = ReaderUI.instance
    if readerui then
        return readerui:getLastDirFile()
    end
end

function LibraryView:getInstance()
    if not LibraryView.instance then
        self:init()
    end
    return self
end

function LibraryView:getBrowserWidget()
    return init_book_browser(self)
end

function LibraryView:getMenuWidget()
    return init_book_menu(self)
end

function LibraryView:refreshBookTocWidget(bookinfo, onReturnCallBack, visible)
    if not (H.is_tbl(bookinfo) and bookinfo.cache_id) then
        logger.err("refreshBookTocWidget parameter error")
        return self.book_toc
    end

    local book_cache_id = bookinfo.cache_id

    local toc_instance = self.book_toc
    if not (H.is_tbl(toc_instance) and H.is_tbl(toc_instance.bookinfo) and 
            toc_instance.bookinfo.cache_id == book_cache_id) then
            logger.dbg("add new book_toc widget")

            self.book_toc = ChapterListing:fetchAndShow({
                cache_id = bookinfo.cache_id,
                bookUrl = bookinfo.bookUrl,
                durChapterIndex = bookinfo.durChapterIndex,
                name = bookinfo.name,
                author = bookinfo.author,
                cacheExt = bookinfo.cacheExt,
                origin = bookinfo.origin,
                originName = bookinfo.originName,
                originOrder = bookinfo.originOrder

            }, onReturnCallBack, function(chapter)
                    self:loadAndRenderChapter(chapter)
            end, true, visible)

    else
        logger.dbg("update book_toc widget ReturnCallback")
        self.book_toc:updateReturnCallback(onReturnCallBack)

        if visible == true then
            self.book_toc:refreshItems()
            UIManager:show(self.book_toc)
        end
    end

    return self.book_toc
end

function LibraryView:showBookTocDialog(bookinfo)
    -- Simple display should not cause changes onReturnCallBack
    return self:refreshBookTocWidget(bookinfo, nil, true)
end

return LibraryView
