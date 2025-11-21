-- Scene Source Sequencer (SSS)
-- Version: 1.2.1 — single-line HH:MM:SS.mmm inputs
-- License: MIT

local obs = obslua

-- ===== Globals =====
local heartbeat_ms = 100
local only_active_scene = true
local hk_start_id = nil
local current_scene_name = ""
local scene_cfg = {}
local settings_ref = nil
local prop_refs = {}  -- [scene] = { props = {handles...} }

-- ===== Utils =====
local function now_ms() return math.floor(obs.os_gettime_ns()/1e6) end
local function trim(s) return (s and s:gsub("^%s*(.-)%s*$","%1")) or "" end
local function lower(s) return (s and s:lower()) or "" end
local function pkey(scene, field) return ("cfg__%s__%s"):format(scene, field) end
local function btn(scene, what) return ("btn__%s__%s"):format(scene, what) end

local function ms_to_hms(ms)
    if ms < 0 then ms = 0 end
    local h = math.floor(ms/3600000); ms = ms - h*3600000
    local m = math.floor(ms/60000);   ms = ms - m*60000
    local s = math.floor(ms/1000);    ms = ms - s*1000
    return h, m, s, ms
end

local function format_hms(ms)
    local h,m,s,ms2 = ms_to_hms(ms)
    return string.format("%02d:%02d:%02d.%03d", h,m,s,ms2)
end

-- accept "HH:MM:SS.mmm" or "MM:SS.mmm" or "SS.mmm"
-- also accept tokens "1h2m3s4ms" or "90s" or "750ms" for fallback
local function parse_duration_ms(str)
    if not str then return 0 end
    local s = lower(trim(str)):gsub(",", ".")
    if s == "" then return 0 end

    if s:find(":") then
        -- normalize to H:M:S(.mmm)
        local parts = {}
        for token in s:gmatch("[^:]+") do table.insert(parts, token) end
        local h,m,sec = 0,0,0
        if #parts == 3 then
            h = tonumber(parts[1]) or 0
            m = tonumber(parts[2]) or 0
            sec = tonumber(parts[3]) or 0
        elseif #parts == 2 then
            m = tonumber(parts[1]) or 0
            sec = tonumber(parts[2]) or 0
        elseif #parts == 1 then
            sec = tonumber(parts[1]) or 0
        end
        local whole = math.floor(sec)
        local frac  = sec - whole
        return ((h*3600 + m*60 + whole)*1000) + math.floor(frac*1000 + 0.5)
    end

    local total = 0
    for value, unit in s:gmatch("(%d+%.?%d*)%s*(h|hr|hrs|hour|hours|m|min|mn|mins|s|sec|secs|ms)") do
        local v = tonumber(value) or 0
        if unit == "h" or unit=="hr" or unit=="hrs" or unit=="hour" or unit=="hours" then
            total = total + math.floor(v*3600*1000 + 0.5)
        elseif unit == "m" or unit=="min" or unit=="mn" or unit=="mins" then
            total = total + math.floor(v*60*1000 + 0.5)
        elseif unit == "s" or unit=="sec" or unit=="secs" then
            total = total + math.floor(v*1000 + 0.5)
        elseif unit == "ms" then
            total = total + math.floor(v + 0.5)
        end
    end
    if total > 0 then return total end

    local vsecs = s:match("^(%d+%.?%d*)%s*s$")
    if vsecs then return math.floor(tonumber(vsecs)*1000 + 0.5) end
    local vms = s:match("^(%d+)$")
    if vms then return tonumber(vms) end
    return 0
end

-- ===== Scene/Source helpers =====
local function get_all_scene_names()
    local out = {}
    local scenes = obs.obs_frontend_get_scenes()
    if scenes then
        for _, src in ipairs(scenes) do
            local n = obs.obs_source_get_name(src)
            if n and n ~= "" then table.insert(out, n) end
        end
        obs.source_list_release(scenes)
    end
    table.sort(out)
    return out
end

local function get_scene_sources(scene_name)
    local names = {}
    local src = obs.obs_get_source_by_name(scene_name)
    if src then
        local scn = obs.obs_scene_from_source(src)
        if scn then
            local items = obs.obs_scene_enum_items(scn)
            if items then
                for _, it in ipairs(items) do
                    local s = obs.obs_sceneitem_get_source(it)
                    if s then
                        local name = obs.obs_source_get_name(s)
                        if name and name ~= "" then table.insert(names, name) end
                    end
                end
                obs.sceneitem_list_release(items)
            end
        end
        obs.obs_source_release(src)
    end
    table.sort(names)
    return names
end

local function refresh_current_scene()
    local src = obs.obs_frontend_get_current_scene()
    if src then
        current_scene_name = obs.obs_source_get_name(src)
        obs.obs_source_release(src)
    else
        current_scene_name = ""
    end
end

local function set_visible(scene_name, source_name, vis)
    if source_name == "" then return end
    local src = obs.obs_get_source_by_name(scene_name)
    if not src then return end
    local scn = obs.obs_scene_from_source(src)
    if scn then
        local it = obs.obs_scene_find_source(scn, source_name)
        if it then obs.obs_sceneitem_set_visible(it, vis) end
    end
    obs.obs_source_release(src)
end

-- ===== Parse sources list "Name|duration" =====
local function parse_sources(txt)
    local arr = {}
    txt = txt or ""
    for line in (txt.."\n"):gmatch("(.-)\r?\n") do
        local ln = trim(line)
        if ln ~= "" then
            local name, dur = ln:match("^(.-)|(.+)$")
            if name and dur then
                local ms = parse_duration_ms(dur)
                table.insert(arr, {name = trim(name), ms = ms})
            end
        end
    end
    return arr
end

local function hide_all(scene, cfg)
    for _, e in ipairs(parse_sources(cfg.sources_txt)) do
        set_visible(scene, e.name, false)
    end
end

-- ===== Sequencer =====
local function start_sequence(scene, cfg)
    local arr = parse_sources(cfg.sources_txt)
    if #arr == 0 or cfg.state ~= "idle" then return end
    if only_active_scene and scene ~= current_scene_name then return end
    hide_all(scene, cfg)
    cfg.state = "showing"
    cfg.idx = 1
    set_visible(scene, arr[1].name, true)
    cfg.until_ts = now_ms() + arr[1].ms
end

local function scheduler()
    local t = now_ms()
    for scene, cfg in pairs(scene_cfg) do
        if not cfg.enabled then goto continue end
        if only_active_scene and scene ~= current_scene_name then goto continue end

        if cfg.state == "idle" and cfg.tick_ms > 0 and t >= cfg.next_tick then
            cfg.next_tick = t + cfg.tick_ms
            if math.random(100) <= cfg.chance_pct then start_sequence(scene, cfg) end
        elseif cfg.state == "showing" then
            local arr = parse_sources(cfg.sources_txt)
            if #arr == 0 then cfg.state = "idle" goto continue end
            if t >= cfg.until_ts then
                set_visible(scene, arr[cfg.idx].name, false)
                if cfg.idx < #arr and cfg.gap_ms > 0 then
                    cfg.state = "gap"
                    cfg.until_ts = t + cfg.gap_ms
                else
                    cfg.idx = cfg.idx + 1
                    if cfg.idx > #arr then
                        cfg.state = "cooldown"
                        cfg.until_ts = t + cfg.cooldown_ms
                    else
                        set_visible(scene, arr[cfg.idx].name, true)
                        cfg.until_ts = t + arr[cfg.idx].ms
                    end
                end
            end
        elseif cfg.state == "gap" then
            if t >= cfg.until_ts then
                local arr = parse_sources(cfg.sources_txt)
                cfg.idx = cfg.idx + 1
                if cfg.idx > #arr then
                    cfg.state = "cooldown"
                    cfg.until_ts = t + cfg.cooldown_ms
                else
                    set_visible(scene, arr[cfg.idx].name, true)
                    cfg.state = "showing"
                    cfg.until_ts = t + arr[cfg.idx].ms
                end
            end
        elseif cfg.state == "cooldown" and t >= cfg.until_ts then
            cfg.state = "idle"
        end
        ::continue::
    end
end

local function hotkey(pressed)
    if not pressed then return end
    for scene, cfg in pairs(scene_cfg) do
        if cfg.enabled then
            start_sequence(scene, cfg)
            if only_active_scene then break end
        end
    end
end

-- ===== Durations I/O =====
local function normalize_duration_field(settings, key)
    local raw = obs.obs_data_get_string(settings, key) or ""
    local ms  = parse_duration_ms(raw)
    obs.obs_data_set_string(settings, key, format_hms(ms))
    return ms
end

-- ===== Config =====
local function defaults_for_scene()
    return {
        enabled=false, sources_txt="",
        add_hms="00:00:06.000",
        gap_hms="00:00:00.500",
        cool_hms="00:00:04.000",
        tick_hms="00:00:30.000",
        chance_pct=20,
        gap_ms=500, cooldown_ms=4000, tick_ms=30000,
        state="idle", idx=0, until_ts=0, next_tick=now_ms()+30000
    }
end

local function load_config(settings)
    scene_cfg = {}
    for _, name in ipairs(get_all_scene_names()) do
        local c = defaults_for_scene()
        c.enabled     = obs.obs_data_get_bool(settings, pkey(name,"enabled"))
        c.sources_txt = obs.obs_data_get_string(settings, pkey(name,"sources_txt")) or ""
        -- normalize and store ms
        c.gap_ms      = normalize_duration_field(settings, pkey(name,"gap_hms"))
        c.cooldown_ms = normalize_duration_field(settings, pkey(name,"cool_hms"))
        c.tick_ms     = normalize_duration_field(settings, pkey(name,"tick_hms"))
        c.chance_pct  = obs.obs_data_get_int(settings, pkey(name,"chance_pct"))
        c.state="idle"; c.idx=0
        c.next_tick = now_ms() + (c.tick_ms>0 and c.tick_ms or 0)
        scene_cfg[name] = c
    end
end

-- ===== Callbacks =====
local function on_add(props, prop)
    if not settings_ref then return false end
    local prop_name = obs.obs_property_name(prop)
    local scene = prop_name and prop_name:match("^btn__(.+)__add$")
    if not scene then return false end
    local src = obs.obs_data_get_string(settings_ref, pkey(scene,"add_name"))
    local ms  = normalize_duration_field(settings_ref, pkey(scene,"add_hms"))
    if src ~= "" and ms > 0 then
        local cur = obs.obs_data_get_string(settings_ref, pkey(scene,"sources_txt")) or ""
        local sep = (cur ~= "" and "\n" or "")
        obs.obs_data_set_string(settings_ref, pkey(scene,"sources_txt"), cur..sep..src.."|"..format_hms(ms))
    end
    script_update(settings_ref)
    return true
end

local function on_clear(props, prop)
    if not settings_ref then return false end
    local pn = obs.obs_property_name(prop)
    local scene = pn and pn:match("^btn__(.+)__clear$")
    if not scene then return false end
    obs.obs_data_set_string(settings_ref, pkey(scene,"sources_txt"), "")
    script_update(settings_ref)
    return true
end

local function on_preview(props, prop)
    local pn = obs.obs_property_name(prop)
    local scene = pn and pn:match("^btn__(.+)__preview$")
    if not scene then return false end
    local cfg = scene_cfg[scene]
    if cfg and cfg.enabled then start_sequence(scene, cfg) end
    return true
end

-- show/hide block
local function set_scene_block_visibility(scene, visible)
    local refs = prop_refs[scene]; if not refs then return end
    for _,h in ipairs(refs.props) do obs.obs_property_set_visible(h, visible) end
end

local function on_toggle_enable(props, prop, settings)
    local pname = obs.obs_property_name(prop)
    local scene = pname and pname:match("^cfg__(.+)__enabled$")
    if not scene then return false end
    local enabled = obs.obs_data_get_bool(settings, pkey(scene,"enabled"))
    set_scene_block_visibility(scene, enabled)
    return true
end

-- Normalize when user edits text fields
local function on_duration_changed(props, prop, settings)
    local key = obs.obs_property_name(prop)
    local ms  = normalize_duration_field(settings, key)
    return true
end

-- ===== UI =====
local function build_scene_group(props, scene)
    prop_refs[scene] = { props = {} }
    local grp = obs.obs_properties_create()

    -- Enable
    local p_enabled = obs.obs_properties_add_bool(grp, pkey(scene,"enabled"), "Enable this scene")
    obs.obs_property_set_modified_callback(p_enabled, on_toggle_enable)

    -- Source picker
    local names = get_scene_sources(scene)
    local p_add = obs.obs_properties_add_list(grp, pkey(scene,"add_name"), "Source",
        obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
    for _,n in ipairs(names) do obs.obs_property_list_add_string(p_add, n, n) end
    table.insert(prop_refs[scene].props, p_add)

    -- Single-line durations
    local p_adddur = obs.obs_properties_add_text(grp, pkey(scene,"add_hms"), "Add duration (HH:MM:SS.mmm)", obs.OBS_TEXT_DEFAULT)
    obs.obs_property_set_modified_callback(p_adddur, on_duration_changed)
    table.insert(prop_refs[scene].props, p_adddur)

    local p_btn_add = obs.obs_properties_add_button(grp, btn(scene,"add"), "＋ Add", on_add)
    table.insert(prop_refs[scene].props, p_btn_add)

    local p_txt = obs.obs_properties_add_text(grp, pkey(scene,"sources_txt"), "Sources list (Name|HH:MM:SS.mmm)", obs.OBS_TEXT_MULTILINE)
    table.insert(prop_refs[scene].props, p_txt)

    local p_btn_clear = obs.obs_properties_add_button(grp, btn(scene,"clear"), "Clear list", on_clear)
    table.insert(prop_refs[scene].props, p_btn_clear)

    local p_gap = obs.obs_properties_add_text(grp, pkey(scene,"gap_hms"), "Gap between sources (HH:MM:SS.mmm)", obs.OBS_TEXT_DEFAULT)
    obs.obs_property_set_modified_callback(p_gap, on_duration_changed)
    table.insert(prop_refs[scene].props, p_gap)

    local p_cool = obs.obs_properties_add_text(grp, pkey(scene,"cool_hms"), "Cooldown after sequence (HH:MM:SS.mmm)", obs.OBS_TEXT_DEFAULT)
    obs.obs_property_set_modified_callback(p_cool, on_duration_changed)
    table.insert(prop_refs[scene].props, p_cool)

    local p_tick = obs.obs_properties_add_text(grp, pkey(scene,"tick_hms"), "Random tick interval (HH:MM:SS.mmm)", obs.OBS_TEXT_DEFAULT)
    obs.obs_property_set_modified_callback(p_tick, on_duration_changed)
    table.insert(prop_refs[scene].props, p_tick)

    local p_ch = obs.obs_properties_add_int(grp, pkey(scene,"chance_pct"), "Random trigger chance (%)", 1, 100, 1)
    table.insert(prop_refs[scene].props, p_ch)

    local p_prev = obs.obs_properties_add_button(grp, btn(scene,"preview"), "▶ Preview sequence", on_preview)
    table.insert(prop_refs[scene].props, p_prev)

    -- initial visibility
    local enabled = settings_ref and obs.obs_data_get_bool(settings_ref, pkey(scene,"enabled")) or false
    set_scene_block_visibility(scene, enabled)

    obs.obs_properties_add_group(props, "grp_scene_"..scene, scene, obs.OBS_GROUP_NORMAL, grp)
end

function script_properties()
    local p = obs.obs_properties_create()
    obs.obs_properties_add_button(p, "refresh_btn", "↻ Refresh scenes", function() return true end)
    obs.obs_properties_add_bool(p, "only_active_scene", "Affect active scene only")
    prop_refs = {}
    for _, s in ipairs(get_all_scene_names()) do build_scene_group(p, s) end
    return p
end

-- ===== Lifecycle =====
local function load_config_internal(settings) load_config(settings) end

function script_update(settings)
    settings_ref = settings
    only_active_scene = obs.obs_data_get_bool(settings, "only_active_scene")
    load_config_internal(settings)
    for s, c in pairs(scene_cfg) do
        for _, e in ipairs(parse_sources(c.sources_txt)) do set_visible(s, e.name, false) end
        local enabled = obs.obs_data_get_bool(settings, pkey(s,"enabled"))
        set_scene_block_visibility(s, enabled)
    end
end

function script_defaults(settings)
    obs.obs_data_set_default_bool(settings, "only_active_scene", true)
    for _, s in ipairs(get_all_scene_names()) do
        obs.obs_data_set_default_string(settings, pkey(s,"add_hms"),  "00:00:06.000")
        obs.obs_data_set_default_string(settings, pkey(s,"gap_hms"),  "00:00:00.500")
        obs.obs_data_set_default_string(settings, pkey(s,"cool_hms"), "00:00:04.000")
        obs.obs_data_set_default_string(settings, pkey(s,"tick_hms"), "00:00:30.000")
        obs.obs_data_set_default_int(   settings, pkey(s,"chance_pct"), 20)
    end
end

function script_description()
    return "Scene Source Sequencer (SSS)\n" ..
           "- Single-line durations: HH:MM:SS.mmm\n" ..
           "- Per-scene source list shown in order, with gap and cooldown\n" ..
           "- Block hides when 'Enable this scene' is unchecked"
end

function script_load(settings)
    math.randomseed(os.time())
    hk_start_id = obs.obs_hotkey_register_frontend("sss_start", "Start source sequence", hotkey)
    local arr = obs.obs_data_get_array(settings, "sss_start")
    obs.obs_hotkey_load(hk_start_id, arr); if arr then obs.obs_data_array_release(arr) end

    obs.obs_frontend_add_event_callback(function(e)
        if e==obs.OBS_FRONTEND_EVENT_SCENE_CHANGED or e==obs.OBS_FRONTEND_EVENT_FINISHED_LOADING then
            refresh_current_scene()
        end
    end)

    refresh_current_scene()
    obs.timer_add(scheduler, heartbeat_ms)
end

function script_save(settings)
    local arr = obs.obs_hotkey_save(hk_start_id)
    obs.obs_data_set_array(settings, "sss_start", arr)
    if arr then obs.obs_data_array_release(arr) end
end

function script_unload()
    obs.timer_remove(scheduler)
end
