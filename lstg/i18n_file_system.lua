local cjson = require("cjson")
local i18n = require("lib.i18n")
local table_unpack = table.unpack or unpack

---@class thlib.ui.i18n_file_system
local M = {}

---@type table<string, table<string, string>>
local locale_map_cache = {}
---@type table<string, boolean>
local locale_loaded = {}
---@type string[]
local locale_map_path_templates = {
    "assets/lang/%s/struct/file.json",
    "data/assets/lang/%s/struct/file.json",
    "packages/tffa-scripts/assets/lang/%s/struct/file.json",
    "packages/tffa-resources/assets/lang/%s/struct/file.json",
}

---@type table<string, { kind: string, name: string, key: string, default_path: string, args: table }>
local localized_resource_records = {}
---@type string[]
local localized_resource_record_order = {}
---@type table<string, fun()>
local reload_callbacks = {}
---@type string[]
local reload_callback_order = {}

local RES_TYPE_TEXTURE = 1
local RES_TYPE_IMAGE = 2

local default_locale_search = {
    en_us = { "en_us", "zh_cn" },
    zh_cn = { "zh_cn", "en_us" },
    ja_jp = { "ja_jp", "en_us", "zh_cn" },
}
setmetatable(default_locale_search, { __index = function(_, _) return default_locale_search.en_us end })

local warned = {
    missing_locale_file = {},
    read_locale_file = {},
    invalid_locale_file = {},
    missing_key = {},
    invalid_path = {},
    missing_mapped_file = {},
}

---@param locale string
---@return string[]
local function build_locale_map_paths(locale)
    local paths = {}
    for _, template in ipairs(locale_map_path_templates) do
        table.insert(paths, string.format(template, locale))
    end
    return paths
end

---@param locale string
---@return string|nil, string[]
local function find_locale_map_file(locale)
    local paths = build_locale_map_paths(locale)
    for _, p in ipairs(paths) do
        if lstg.FileManager.FileExist(p, true) then
            return p, paths
        end
    end
    return nil, paths
end

---@param path string
---@return string
local function normalize_path(path)
    local p = string.gsub(path, "\\", "/")
    while string.find(p, "//", 1, true) do
        p = string.gsub(p, "//", "/")
    end
    return p
end

---@param key string
---@param msg string
local function warn_once(key, msg)
    if warned[key][msg] then
        return
    end
    warned[key][msg] = true
    lstg.Log(3, msg)
end

---@return table
local function pack_args(...)
    return { n = select("#", ...), ... }
end

---@param kind string
---@param name string
---@return string
local function make_record_id(kind, name)
    return string.format("%s:%s", kind, tostring(name))
end

---@param kind string
---@param name string
---@param key string
---@param default_path string
---@param args table
local function register_localized_resource(kind, name, key, default_path, args)
    local id = make_record_id(kind, name)
    if not localized_resource_records[id] then
        table.insert(localized_resource_record_order, id)
    end
    localized_resource_records[id] = {
        kind = kind,
        name = name,
        key = key,
        default_path = default_path,
        args = args or { n = 0 },
    }
end

---@param res_type integer
---@param name string
---@return string|nil
local function get_res_pool(res_type, name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local ok1, pool1 = pcall(lstg.CheckRes, res_type, name)
    if ok1 and type(pool1) == "string" and pool1 ~= "" then
        return pool1
    end
    local type_name = nil
    if res_type == RES_TYPE_TEXTURE then
        type_name = "tex"
    elseif res_type == RES_TYPE_IMAGE then
        type_name = "img"
    end
    if type_name and type(CheckRes) == "function" then
        local ok2, pool2 = pcall(CheckRes, type_name, name)
        if ok2 and type(pool2) == "string" and pool2 ~= "" then
            return pool2
        end
    end
    return nil
end

---@param res_type integer
---@param name string
local function remove_resource_if_exists(res_type, name)
    local pool = get_res_pool(res_type, name)
    if not pool then
        return
    end
    pcall(lstg.RemoveResource, pool, res_type, name)
end

---@param prefix string
---@param args table
local function remove_image_group_if_exists(prefix, args)
    if type(prefix) ~= "string" or prefix == "" then
        return
    end
    local cols = tonumber(args and args[2])
    local rows = tonumber(args and args[3])
    if cols and rows and cols > 0 and rows > 0 then
        local total = cols * rows
        for i = 1, total do
            remove_resource_if_exists(RES_TYPE_IMAGE, prefix .. tostring(i))
        end
        return
    end
    local i = 1
    while true do
        local image_name = prefix .. tostring(i)
        if not get_res_pool(RES_TYPE_IMAGE, image_name) then
            break
        end
        remove_resource_if_exists(RES_TYPE_IMAGE, image_name)
        i = i + 1
    end
end

---@param name string
function M.clear_image(name)
    remove_resource_if_exists(RES_TYPE_IMAGE, name)
end

---@param name string
function M.clear_texture(name)
    remove_resource_if_exists(RES_TYPE_TEXTURE, name)
end

---@param names table|string|nil
local function clear_images(names)
    if type(names) == "string" then
        M.clear_image(names)
        return
    end
    if type(names) ~= "table" then
        return
    end
    for _, name in ipairs(names) do
        if type(name) == "string" and name ~= "" then
            M.clear_image(name)
        end
    end
end

---@param names table|string|function|nil
---@return table|string|nil
local function eval_image_names(names)
    if type(names) == "function" then
        local ok, result = pcall(names)
        if ok then
            return result
        end
        return nil
    end
    return names
end

---@return string
local function get_current_locale()
    if i18n and type(i18n.get_locale) == "function" then
        local ok, locale = pcall(i18n.get_locale)
        if ok and type(locale) == "string" and locale ~= "" then
            return locale
        end
    end
    if setting and type(setting.locale) == "string" and setting.locale ~= "" then
        return setting.locale
    end
    return "zh_cn"
end

---@param locale string
---@return string[]
local function get_locale_search_order(locale)
    if i18n and type(i18n.get_locale_search_order) == "function" then
        local ok, order = pcall(i18n.get_locale_search_order, locale)
        if ok and type(order) == "table" and #order > 0 then
            return order
        end
    end
    local src = default_locale_search[locale]
    local ret = {}
    for i, v in ipairs(src) do
        ret[i] = v
    end
    return ret
end

---@param path string
---@return boolean
local function is_ui_path(path)
    local normalized = string.lower(normalize_path(path))
    return string.sub(normalized, 1, 10) == "assets/ui/"
end

---@param locale string
---@return table<string, string>
local function load_locale_map(locale)
    if locale_loaded[locale] then
        return locale_map_cache[locale]
    end
    locale_loaded[locale] = true

    local map = {}
    local file_path, searched_paths = find_locale_map_file(locale)
    if not file_path then
        warn_once(
            "missing_locale_file",
            string.format(
                "i18n image map not found for locale '%s' (checked: %s)",
                locale,
                table.concat(searched_paths, ", ")
            )
        )
        locale_map_cache[locale] = map
        return map
    end

    local src = lstg.LoadTextFile(file_path)
    if not src then
        warn_once("read_locale_file", string.format("read localized i18n map failed: '%s'", file_path))
        locale_map_cache[locale] = map
        return map
    end

    local ok, decoded = pcall(cjson.decode, src)
    if not ok then
        lstg.Log(4, string.format("parse i18n image map failed: '%s', error: %s", file_path, tostring(decoded)))
        locale_map_cache[locale] = map
        return map
    end
    if type(decoded) ~= "table" then
        warn_once("invalid_locale_file", string.format("i18n image map is not object: '%s'", file_path))
        locale_map_cache[locale] = map
        return map
    end

    for k, v in pairs(decoded) do
        if type(k) == "string" and type(v) == "string" then
            map[k] = normalize_path(v)
        else
            warn_once(
                "invalid_locale_file",
                string.format("i18n image entry ignored in '%s': key=%s, value=%s", file_path, type(k), type(v))
            )
        end
    end

    locale_map_cache[locale] = map
    return map
end

---@param key string
---@param default_path string
---@return string
function M.resolve_image_path(key, default_path)
    if type(key) ~= "string" or key == "" then
        return default_path
    end
    if type(default_path) ~= "string" or default_path == "" then
        return default_path
    end

    local locale = get_current_locale()
    local order = get_locale_search_order(locale)
    local active_locale = order[1] or locale
    local active_map = load_locale_map(active_locale)
    if not active_map[key] then
        warn_once(
            "missing_key",
            string.format("i18n image key '%s' missing in active locale '%s'", key, active_locale)
        )
    end

    for _, lc in ipairs(order) do
        local map = load_locale_map(lc)
        local candidate = map[key]
        if type(candidate) == "string" and candidate ~= "" then
            if not is_ui_path(candidate) then
                warn_once(
                    "invalid_path",
                    string.format("i18n image key '%s' resolved to non-UI path '%s' in locale '%s'", key, candidate, lc)
                )
            elseif lstg.FileManager.FileExist(candidate, true) then
                return candidate
            else
                warn_once(
                    "missing_mapped_file",
                    string.format("i18n image key '%s' mapped file not found '%s' in locale '%s'", key, candidate, lc)
                )
            end
        end
    end

    return default_path
end

---@param record { kind: string, name: string, key: string, default_path: string, args: table }?
local function reload_localized_resource(record)
    if not record then
        return
    end
    local path = M.resolve_image_path(record.key, record.default_path)
    local args = record.args or { n = 0 }
    if record.kind == "texture" then
        remove_resource_if_exists(RES_TYPE_TEXTURE, record.name)
        local mipmap = args[1]
        if mipmap == nil then
            LoadTexture(record.name, path)
        else
            LoadTexture(record.name, path, mipmap)
        end
    elseif record.kind == "image_from_file" then
        remove_resource_if_exists(RES_TYPE_IMAGE, record.name)
        remove_resource_if_exists(RES_TYPE_TEXTURE, record.name)
        LoadImageFromFile(record.name, path, table_unpack(args, 1, args.n))
    elseif record.kind == "image_group_from_file" then
        remove_image_group_if_exists(record.name, args)
        remove_resource_if_exists(RES_TYPE_TEXTURE, record.name)
        LoadImageGroupFromFile(record.name, path, table_unpack(args, 1, args.n))
    end
end

---@param tex_name string
---@param key string
---@param default_path string
---@param mipmap boolean?
function M.load_texture(tex_name, key, default_path, mipmap)
    register_localized_resource("texture", tex_name, key, default_path, pack_args(mipmap))
    reload_localized_resource(localized_resource_records[make_record_id("texture", tex_name)])
end

---@param img_name string
---@param key string
---@param default_path string
function M.load_image_from_file(img_name, key, default_path, ...)
    register_localized_resource("image_from_file", img_name, key, default_path, pack_args(...))
    reload_localized_resource(localized_resource_records[make_record_id("image_from_file", img_name)])
end

---@param prefix string
---@param key string
---@param default_path string
function M.load_image_group_from_file(prefix, key, default_path, ...)
    register_localized_resource("image_group_from_file", prefix, key, default_path, pack_args(...))
    reload_localized_resource(localized_resource_records[make_record_id("image_group_from_file", prefix)])
end

---@param id string
---@param fn fun()
function M.register_reload_callback(id, fn)
    if type(id) ~= "string" or id == "" then
        return
    end
    if type(fn) ~= "function" then
        return
    end
    if not reload_callbacks[id] then
        table.insert(reload_callback_order, id)
    end
    reload_callbacks[id] = fn
end

---@param id string
function M.unregister_reload_callback(id)
    if type(id) ~= "string" or id == "" then
        return
    end
    reload_callbacks[id] = nil
end

---@param id string
---@param names table|string|function|nil
---@param rebuild_fn fun()
---@param run_now boolean?
function M.register_image_rebuilder(id, names, rebuild_fn, run_now)
    if type(id) ~= "string" or id == "" then
        return
    end
    if type(rebuild_fn) ~= "function" then
        return
    end
    local function callback()
        clear_images(eval_image_names(names))
        local ok, err = pcall(rebuild_fn)
        if not ok then
            lstg.Log(3, string.format("i18n image rebuilder failed '%s': %s", id, tostring(err)))
        end
    end
    M.register_reload_callback(id, callback)
    if run_now ~= false then
        callback()
    end
end

---@param locale string?
function M.invalidate_cache(locale)
    if type(locale) == "string" and locale ~= "" then
        locale_map_cache[locale] = nil
        locale_loaded[locale] = nil
    else
        locale_map_cache = {}
        locale_loaded = {}
    end
end

function M.reload_all_localized_resources()
    M.invalidate_cache()
    for _, id in ipairs(localized_resource_record_order) do
        reload_localized_resource(localized_resource_records[id])
    end
    for _, id in ipairs(reload_callback_order) do
        local fn = reload_callbacks[id]
        if type(fn) == "function" then
            local ok, err = pcall(fn)
            if not ok then
                lstg.Log(3, string.format("i18n resource reload callback failed '%s': %s", id, tostring(err)))
            end
        end
    end
end

function M.clear_registered_resources()
    localized_resource_records = {}
    localized_resource_record_order = {}
end

return M
