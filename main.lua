local plugin_label = 'magoogles_universal_rotation'

local gui             = require 'gui'
local spell_config    = require 'core.spell_config'
local spell_tracker   = require 'core.spell_tracker'
local rotation_engine = require 'core.rotation_engine'
local profile_io      = require 'core.profile_io'
local buff_provider   = require 'core.buff_provider'
local cloud_share     = require 'core.cloud_share'
local logger          = require 'core.logger'

-- Start file logger immediately
logger.enable()

-- Always start enabled regardless of any persisted checkbox state.
-- Game crashes wipe widget state, so the saved value can be stale/false.
if gui.elements.enabled then gui.elements.enabled:set(true) end

-- Sanitize a spell config loaded from JSON.
-- Fixes the crash where require_buff=true but no buff is actually defined
-- (buff_hash=0 AND buff_name=''), which causes a dead buff condition that
-- silently prevents the spell from ever firing.
local function _sanitize_spell_cfg(sid, cfg)
    if not cfg or type(cfg) ~= 'table' then return cfg end
    if cfg.require_buff and (cfg.buff_hash == nil or cfg.buff_hash == 0)
                        and (cfg.buff_name == nil or cfg.buff_name == '') then
        cfg.require_buff = false
        console.print(string.format(
            '[UniversalRotation] WARNING: Spell %s had require_buff=true but no buff defined. ' ..
            'Auto-fixed to require_buff=false. ' ..
            'Please set the correct buff in the rotation menu.',
            tostring(sid)
        ))
    end
    return cfg
end

local equipped_ids  = {}   -- spell IDs currently on bar
local all_known_ids = {}   -- union of all ever-seen IDs (persists through bar swaps)
local all_known_set = {}

local scan_interval = 2.0  -- re-scan bar every 2 seconds
local last_scan     = -999

local last_class_key = nil

local settings = {
    scan_range         = 16.0,
    anim_delay         = 0.05,
    global_min_enemies = 0,
    debug              = false,
    overlay_enabled    = true,
    overlay_x          = 20,
    overlay_y          = 12,
    overlay_show_buffs = false,
}

-- Track hold-key state so we can short-circuit other systems
local _hold_key_active = true  -- treated as true when hold-key feature is disabled

local function is_enabled()
    if not gui.elements.enabled:get() then return false end
    if gui.elements.use_keybind:get() then
        local key   = gui.elements.keybind:get_key()
        local state = gui.elements.keybind:get_state()
        if key == 0x0A then return false end      -- not bound yet
        if state ~= 1 and state ~= true then return false end
    end

    -- Hold-to-cast: rotation only runs while the configured key is held
    if gui.elements.use_hold_key and gui.elements.use_hold_key:get() then
        local vk = 0x0A
        pcall(function() vk = gui.elements.hold_keybind:get_key() end)
        if vk == 0x0A then return false end  -- not bound yet
        local held = false
        pcall(function() held = get_key_state(vk) end)
        _hold_key_active = held and true or false
        if not held then return false end
    else
        _hold_key_active = true
    end

    return true
end

-- Whether the rotation should yield to the orbwalker right now
local function should_respect_orbwalker()
    if not gui.elements.respect_orb or not gui.elements.respect_orb:get() then return false end
    -- If the user is actively hold-casting, don't yield
    if gui.elements.use_hold_key and gui.elements.use_hold_key:get() and _hold_key_active then
        return false
    end
    return true
end

local function refresh_equipped()
    local now = get_time_since_inject()
    if now - last_scan < scan_interval then return end
    last_scan = now

    local ids = get_equipped_spell_ids()
    if not ids then equipped_ids = {}; return end

    equipped_ids = {}
    for _, id in ipairs(ids) do
        if id and id > 1 then
            table.insert(equipped_ids, id)
            if not all_known_set[id] then
                all_known_set[id] = true
                table.insert(all_known_ids, id)
            end
        end
    end
end

local function update_settings()
    settings.scan_range         = gui.elements.scan_range:get()
    settings.anim_delay         = gui.elements.anim_delay:get()
    settings.global_min_enemies = gui.elements.global_min_enemies and gui.elements.global_min_enemies:get() or 0
    settings.debug              = gui.elements.debug_mode:get()
    settings.overlay_enabled = gui.elements.overlay_enabled:get()
    settings.overlay_x       = gui.elements.overlay_x:get()
    settings.overlay_y       = gui.elements.overlay_y:get()
    settings.overlay_show_buffs = gui.elements.overlay_show_buffs and gui.elements.overlay_show_buffs:get() or false
    settings.allow_movement     = gui.elements.allow_movement and gui.elements.allow_movement:get() or false
    settings.respect_orb        = should_respect_orbwalker()
    -- See gui.lua's external_target_override checkbox tooltip.  When
    -- ON, rotation_engine treats _G.EXTERNAL_ROTATION_TARGET as
    -- authoritative -- no fallback to UR's own target_selector when
    -- it's nil/invalid.
    settings.external_target_override = gui.elements.external_target_override
        and gui.elements.external_target_override:get() or false
    -- True while the user is actively hold-casting; rotation_engine uses this to
    -- suppress cursor warps and pathfinder moves so manual movement input wins.
    settings.hold_active        = gui.elements.use_hold_key and gui.elements.use_hold_key:get() and _hold_key_active or false
    settings.hold_location_enabled = gui.elements.hold_location_enabled and gui.elements.hold_location_enabled:get() or false
    settings.hold_location_range   = gui.elements.hold_location_range   and gui.elements.hold_location_range:get()   or 15.0
    settings.hold_location_pos     = _hold_pos
    rotation_engine.set_scan_range(settings.scan_range)

    -- Sync buff dropdown filters to buff_provider
    local fchanged = false
    fchanged = buff_provider.set_filter('paragon',  gui.elements.bf_paragon  and gui.elements.bf_paragon:get()  or false) or fchanged
    fchanged = buff_provider.set_filter('talent',   gui.elements.bf_talent   and gui.elements.bf_talent:get()   or false) or fchanged
    fchanged = buff_provider.set_filter('item',     gui.elements.bf_item     and gui.elements.bf_item:get()     or false) or fchanged
    fchanged = buff_provider.set_filter('npc',      gui.elements.bf_npc      and gui.elements.bf_npc:get()      or false) or fchanged
    fchanged = buff_provider.set_filter('bsk',      gui.elements.bf_bsk      and gui.elements.bf_bsk:get()      or false) or fchanged
    fchanged = buff_provider.set_filter('dungeon',  gui.elements.bf_dungeon  and gui.elements.bf_dungeon:get()  or false) or fchanged
    fchanged = buff_provider.set_filter('passive',  gui.elements.bf_passive  and gui.elements.bf_passive:get()  or false) or fchanged
    fchanged = buff_provider.set_filter('internal', gui.elements.bf_internal and gui.elements.bf_internal:get() or false) or fchanged
    if fchanged then spell_config.invalidate_buff_lists() end
end

local function _pretty_spell_name(raw)
    if not raw or raw == '' then return nil end
    raw = tostring(raw)
    local bracket = raw:match('%[([^%]]+)%]')
    if bracket and bracket ~= '' then raw = bracket end
    raw = raw:gsub('%s*ID%s*=%s*%d+.*$', '')
    raw = raw:gsub('[%[%]]', ''):gsub('^%s+', ''):gsub('%s+$', '')
    local parts = {}
    for p in raw:gmatch('[^_]+') do parts[#parts + 1] = p end
    if #parts >= 2 then table.remove(parts, 1) end
    local phrase = table.concat(parts, ' ')
    phrase = phrase:lower():gsub('(%a)([%w\']*)', function(a, b) return a:upper() .. b end)
    return phrase
end


local function get_script_root()
    local root = string.gmatch(package.path, '.*?\\?')()
    return root and root:gsub('?', '') or ''
end

local function _set_element(el, val)
    if not el then return end
    -- Skip on nil so a missing field in an older / stripped profile
    -- doesn't clobber the widget's existing host-persisted value.
    -- _apply_profile_data calls _set_element for every global on every
    -- import, including ones the file may legitimately omit (e.g.
    -- post-strip cloud download where personal globals were removed).
    if val == nil then return end
    if type(el.set) == 'function' then pcall(el.set, el, val); return end
    if type(el.set_value) == 'function' then pcall(el.set_value, el, val); return end
end

-- Slider widgets (slider_int / slider_float) have NO :set method on this host,
-- so _set_element silently no-ops on sliders.  We work around it by rebuilding
-- the slider widget with a fresh hash so the host has no persisted state for
-- it and the new widget renders at its DEFAULT value (= the imported value).
-- See core/spell_config.lua for the per-spell variant.
local _global_apply_gen = 0
local function _apply_global_slider(field_name, ctor, min, max, val)
    if val == nil or not gui or not gui.elements then return end
    local el = gui.elements[field_name]
    local cur
    if el and type(el.get) == 'function' then
        local ok, v = pcall(el.get, el)
        if ok then cur = v end
    end
    if cur ~= nil and math.abs((cur or 0) - (val or 0)) < 1e-6 then return end
    _global_apply_gen = _global_apply_gen + 1
    local fresh_hash = get_hash('magoogles_universal_rotation_' .. field_name .. '_g' .. _global_apply_gen)
    -- ctor is the slider_int / slider_float CLASS table (a table, not a
    -- function), so construction is `ctor:new(...)` not `ctor(...)`.
    -- Latent bug pre-1.0.21 -- never triggered because every real apply
    -- found cur == val and short-circuited above; hold_location_range
    -- in 1.0.21 was the first field where on-disk value reliably
    -- diverged from the widget's constructor default.
    gui.elements[field_name] = ctor:new(min, max, val, fresh_hash)
end

local function _class_key()
    local lp = get_local_player()
    if not lp or type(lp.get_character_class_id) ~= 'function' then return 'unknown' end
    local ok, cid = pcall(lp.get_character_class_id, lp)
    cid = ok and cid or nil
    local map = {
        [0] = 'sorcerer',
        [1] = 'barbarian',
        [2] = 'druid',
        [3] = 'rogue',
        [6] = 'necromancer',
        [7] = 'spiritborn',
        [8] = 'warlock',
        [9] = 'paladin',
    }
    if cid ~= nil and map[cid] then return map[cid] end
    return 'class_' .. tostring(cid or 'unknown')
end

-- ---- Multi-profile system ----
-- Manifest per class: { active = "Default", profiles = {"Default", "Profile 2", ...} }
local _profile_names  = {}   -- ordered list of profile names for current class
local _active_profile = 'Default'
local _last_profile_idx = nil  -- tracks combo selection to detect switches

-- Hold Location state (runtime only — not persisted to profile)
local _hold_pos         = nil   -- vec3 of pinned position; nil = not yet set
local _hold_loc_prev_en = false -- previous enabled state for rising-edge detect

-- Cached result of the last cloud listing fetch (auto-loaded on class
-- detection; refreshed after a successful share/upload).  Drives the
-- in-menu picker -- gui.lua reads this each frame to render the combo.
-- profiles == nil means "never fetched"; an empty table means "fetched
-- and the server had nothing for this class".
local _cloud_browse = {
    class       = '',
    profiles    = nil,
    error       = nil,
    fetched_at  = 0,
}

-- Sentinel: which class we have already auto-loaded for.  Reset when the
-- player switches characters or after a successful share, so the next
-- handle_class_profiles tick refreshes the listing for the new context.
local _cloud_auto_loaded_class = nil

-- Autosave: persist the active profile to disk on a throttle so user
-- customizations made AFTER a cloud download (or any other profile load)
-- survive a script reload.  Without this, the on-disk file stays the
-- pristine downloaded copy and _import_profile clobbers in-memory edits
-- on next load.  We only write when the freshly-built profile JSON
-- diverges from the last snapshot, so an idle script doesn't churn disk.
local _last_saved_json   = nil
local _last_autosave_t   = 0
local AUTOSAVE_INTERVAL  = 10.0   -- seconds between dirty-checks

-- Forward-declare the cloud-listing helpers so handle_profile_io can call
-- them; the actual definitions live further down next to the other
-- network-touching code.
local _auto_load_cloud_listing
local _refresh_cloud_listing

-- Pre-format combo labels + detail lines from a listing array.  Done
-- once per fetch so the per-frame render path stays O(1) (see Lua perf
-- rules).  ASCII-only output (the menu font renders U+2014 as "?").
--
-- The combo entry stays narrow ("name (code)") so it fits the widget;
-- the detail line shown below the combo carries the full info.
local function _build_cloud_labels(profiles)
    local labels  = {}
    local details = {}
    for i, p in ipairs(profiles or {}) do
        local code = tostring(p.code or '------')
        local name = tostring(p.name or 'Unnamed')
        local short_name = name
        if #short_name > 25 then short_name = short_name:sub(1, 22) .. '...' end

        labels[i] = string.format('%s (%s)', short_name, code)

        local upd = 'unknown'
        if type(p.updated_at) == 'number' and p.updated_at > 0 then
            upd = os.date('%Y-%m-%d %H:%M', math.floor(p.updated_at))
        end
        details[i] = string.format('Code: %s  |  Updated: %s', code, upd)
    end
    return labels, details
end

-- Apply a profile listing to _cloud_browse and reset the combo selection
-- so a stale index can't survive a list shrink.
local function _apply_cloud_listing(class_key, profiles, fetched_at)
    local labels, details = _build_cloud_labels(profiles)
    _cloud_browse.class      = class_key
    _cloud_browse.profiles   = profiles
    _cloud_browse.labels     = labels
    _cloud_browse.details    = details
    _cloud_browse.error      = nil
    _cloud_browse.fetched_at = fetched_at or os.time()
    if gui.elements.cloud_browse_combo and gui.elements.cloud_browse_combo.set then
        pcall(function() gui.elements.cloud_browse_combo:set(0) end)
    end
end

local function _manifest_path_for(class_key)
    return get_script_root() .. 'universal_rotation_' .. tostring(class_key) .. '_manifest.json'
end

local function _profile_path_for(class_key, profile_name)
    profile_name = profile_name or _active_profile
    if profile_name == 'Default' then
        -- Backwards compatible: Default profile uses the old filename
        return get_script_root() .. 'universal_rotation_' .. tostring(class_key) .. '.json'
    end
    -- Sanitize name for filename: lowercase, replace spaces with underscores
    local safe = tostring(profile_name):lower():gsub('%s+', '_'):gsub('[^%w_]', '')
    return get_script_root() .. 'universal_rotation_' .. tostring(class_key) .. '_' .. safe .. '.json'
end

local function _profile_path()
    return _profile_path_for(_class_key(), _active_profile)
end

-- Convert a sanitized filename stem ("my_test_1") back to a display name
-- ("My Test 1").  Lossy: case + non-alphanumerics from the original name
-- are gone forever (the filename sanitizer in _profile_path_for is
-- one-way), but title-cased + space-separated is a reasonable recovery.
local function _safe_to_display(safe)
    local s = (safe or ''):gsub('_', ' ')
    s = s:gsub('^%s*(%l)', string.upper)
    s = s:gsub('(%s)(%l)', function (sp, c) return sp .. c:upper() end)
    return s
end

-- Best-effort scan of the script directory for orphan profile files
-- belonging to `class_key`.  Pre-multi-profile versions saved per-name
-- profile JSONs but no manifest -- after the multi-profile upgrade those
-- files are invisible to the GUI selector unless we discover them.
--
-- Uses io.popen + cmd /b dir.  This causes a brief CMD console flash on
-- Windows (Lua's GUI host doesn't pass CREATE_NO_WINDOW), so the scan
-- is one-shot per class per script-version: _load_manifest latches a
-- 'scanned_v1' flag in the manifest after the first run and skips this
-- branch on subsequent loads.
local function _discover_profiles(class_key)
    local root = get_script_root()
    if not root or root == '' then return {} end
    local prefix = 'universal_rotation_' .. tostring(class_key) .. '_'
    local cmd = 'cmd /c dir /b "' .. root .. prefix .. '*.json" 2>nul'
    local h = io.popen(cmd, 'r')
    if not h then return {} end
    local found = {}
    for line in h:lines() do
        if line and line ~= '' then
            -- Strip leading dir (defensive: depending on cwd, dir /b can
            -- emit either bare names or paths) and the .json suffix.
            local fname = line:match('([^\\/]+)$') or line
            local stem  = fname:gsub('%.json$', '')
            local safe  = stem:gsub('^' .. prefix, '')
            -- Skip the manifest itself + the legacy single-profile file
            -- (which is already auto-mapped to "Default") + empty stems.
            if safe ~= '' and safe ~= 'manifest' and stem ~= ('universal_rotation_' .. tostring(class_key)) then
                found[#found + 1] = safe
            end
        end
    end
    pcall(function () h:close() end)
    return found
end

-- Merge discovered profile filenames into an existing list, skipping
-- entries whose display name is already present (case-insensitive).
-- Returns the merged list + a count of newly-added entries.
local function _merge_discovered(existing, discovered_safe)
    local lower_present = {}
    for _, n in ipairs(existing) do lower_present[n:lower()] = true end
    local merged, added = {}, 0
    for _, n in ipairs(existing) do merged[#merged + 1] = n end
    for _, safe in ipairs(discovered_safe) do
        local display = _safe_to_display(safe)
        if not lower_present[display:lower()] then
            merged[#merged + 1] = display
            lower_present[display:lower()] = true
            added = added + 1
        end
    end
    return merged, added
end

-- Latch that's true once the orphan-profile discovery scan has run for
-- the current class.  Persisted in the manifest JSON as scanned_v1 so
-- the scan only runs once per class per install.
local _scanned_v1 = false

-- Forward-declare so _load_manifest can call _save_manifest after the
-- migration scan; the actual definition is right below.
local _save_manifest

local function _load_manifest(class_key)
    local path = _manifest_path_for(class_key)
    local data = nil
    local f = io.open(path, 'r')
    if f then
        local json = f:read('*a')
        f:close()
        local parsed = profile_io.from_json(json)
        if type(parsed) == 'table' then data = parsed end
    end

    if data then
        _profile_names  = data.profiles or { 'Default' }
        _active_profile = data.active   or 'Default'
        _scanned_v1     = data.scanned_v1 == true
    else
        _profile_names  = { 'Default' }
        _active_profile = 'Default'
        _scanned_v1     = false
    end

    -- Ensure active profile is in the list
    local found = false
    for _, n in ipairs(_profile_names) do
        if n == _active_profile then found = true; break end
    end
    if not found then _active_profile = _profile_names[1] or 'Default' end

    -- One-time orphan-profile migration: pre-multi-profile UR versions
    -- wrote per-name profile JSONs without ever touching the manifest,
    -- so after the multi-profile upgrade those files were invisible to
    -- the GUI selector and the user couldn't switch to / share them.
    -- The scan walks the script dir once per class, folds anything it
    -- finds into the manifest, and latches scanned_v1=true so we don't
    -- re-scan (and re-flash a CMD console) every load.
    if not _scanned_v1 then
        local discovered = _discover_profiles(class_key)
        if #discovered > 0 then
            local merged, added = _merge_discovered(_profile_names, discovered)
            if added > 0 then
                _profile_names = merged
                console.print(string.format(
                    '[UniversalRotation] Migrated %d existing profile file(s) for %s into the manifest.',
                    added, tostring(class_key)))
            end
        end
        _scanned_v1 = true
        _save_manifest(class_key)
    end
end

_save_manifest = function (class_key)
    local data = {
        active     = _active_profile,
        profiles   = _profile_names,
        scanned_v1 = _scanned_v1,
    }
    local json = profile_io.to_json(data)
    local path = _manifest_path_for(class_key)
    pcall(function()
        local f = assert(io.open(path, 'w'))
        f:write(json)
        f:close()
    end)
end

local function _get_active_profile_index()
    for i, n in ipairs(_profile_names) do
        if n == _active_profile then return i - 1 end  -- 0-based for combo_box
    end
    return 0
end

-- Personal globals: persisted locally so users keep their UI/keybind/filter
-- preferences across reloads, but stripped from cloud uploads (the receiver
-- doesn't want the uploader's overlay coords or debug toggle) and stripped
-- again on cloud download for backwards compatibility with profiles uploaded
-- by older versions that didn't strip on send.  Anything NOT in this list
-- (scan_range, anim_delay, global_min_enemies, allow_movement, respect_orb)
-- is rotation behavior and IS shared.
local _PERSONAL_GLOBAL_FIELDS = {
    'debug_mode', 'overlay_enabled', 'overlay_x', 'overlay_y', 'overlay_show_buffs',
    'external_target_override',
    'hold_location_enabled', 'hold_location_range',
    'bf_paragon', 'bf_talent', 'bf_item', 'bf_npc',
    'bf_bsk', 'bf_dungeon', 'bf_passive', 'bf_internal',
}

local function _strip_personal_globals(data)
    if type(data) ~= 'table' or type(data.global) ~= 'table' then return end
    for _, f in ipairs(_PERSONAL_GLOBAL_FIELDS) do data.global[f] = nil end
end

local function _cb_get(name, default)
    local el = gui.elements[name]
    if el and type(el.get) == 'function' then
        local ok, v = pcall(el.get, el)
        if ok then return v end
    end
    return default
end

-- for_share=true strips personal/UI globals before encoding, so the cloud
-- upload only carries rotation behavior + spell config.  Default false =
-- full local snapshot (used by autosave, _export_profile, manifest writes).
local function _build_profile_json(class_key, profile_name, for_share)
    class_key    = class_key    or _class_key()
    profile_name = profile_name or _active_profile
    local data = {
        version = 2,
        class   = class_key,
        profile = profile_name,
        global  = {
            -- Rotation behavior: shared + persisted locally
            scan_range               = gui.elements.scan_range:get(),
            anim_delay               = gui.elements.anim_delay:get(),
            global_min_enemies       = gui.elements.global_min_enemies and gui.elements.global_min_enemies:get() or 0,
            allow_movement           = _cb_get('allow_movement', false),
            respect_orb              = _cb_get('respect_orb', true),
            -- Personal / UI: persisted locally, stripped on share/import
            debug_mode               = gui.elements.debug_mode:get(),
            overlay_enabled          = gui.elements.overlay_enabled:get(),
            overlay_x                = gui.elements.overlay_x:get(),
            overlay_y                = gui.elements.overlay_y:get(),
            overlay_show_buffs       = gui.elements.overlay_show_buffs and gui.elements.overlay_show_buffs:get() or false,
            external_target_override = _cb_get('external_target_override', false),
            hold_location_enabled    = _cb_get('hold_location_enabled', false),
            hold_location_range      = (gui.elements.hold_location_range and gui.elements.hold_location_range:get()) or 15.0,
            bf_paragon               = _cb_get('bf_paragon', false),
            bf_talent                = _cb_get('bf_talent', false),
            bf_item                  = _cb_get('bf_item', false),
            bf_npc                   = _cb_get('bf_npc', false),
            bf_bsk                   = _cb_get('bf_bsk', false),
            bf_dungeon               = _cb_get('bf_dungeon', false),
            bf_passive               = _cb_get('bf_passive', false),
            bf_internal              = _cb_get('bf_internal', false),
        },
        spells       = {},
        buff_history = buff_provider.export_history(),
    }
    if for_share then _strip_personal_globals(data) end
    for _, sid in ipairs(all_known_ids) do
        data.spells[tostring(sid)] = spell_config.get(sid)
    end
    data.spells[tostring(gui.VIRTUAL_EVADE_ID)] = spell_config.get(gui.VIRTUAL_EVADE_ID)
    return profile_io.to_json(data)
end

local function _export_profile(class_key, profile_name)
    class_key    = class_key    or _class_key()
    profile_name = profile_name or _active_profile

    local json = _build_profile_json(class_key, profile_name)
    local path = _profile_path_for(class_key, profile_name)
    local ok, err = pcall(function()
        local f = assert(io.open(path, 'w'))
        f:write(json)
        f:close()
    end)

    if ok then
        console.print('[UniversalRotation] Saved profile: ' .. profile_name .. ' (' .. path .. ')')
        if profile_name == _active_profile then _last_saved_json = json end
    else
        console.print('[UniversalRotation] Save failed: ' .. tostring(err))
    end

    _save_manifest(class_key)
end

-- Apply a parsed profile data table to the current session.
-- skip_globals=true skips ALL global settings and only applies per-spell
-- configs.  Used for profile switches so the user's scan range, overlay
-- position, and other Global Settings stay fixed regardless of which
-- profile is active.  Startup and explicit reloads pass skip_globals=false
-- to fully restore a saved state from disk.
local function _apply_profile_data(data, display_name, silent, skip_globals)
    if type(data) ~= 'table' then return false end

    if type(data.global) == 'table' and not skip_globals then
        local g = data.global
        -- Rotation behavior
        _apply_global_slider('scan_range',         slider_float, 5.0, 30.0, g.scan_range)
        _apply_global_slider('anim_delay',         slider_float, 0.0, 0.5,  g.anim_delay)
        _apply_global_slider('global_min_enemies', slider_int,   0,   15,   g.global_min_enemies)
        _set_element(gui.elements.allow_movement,           g.allow_movement)
        _set_element(gui.elements.respect_orb,              g.respect_orb)
        -- Personal / UI
        _set_element(gui.elements.debug_mode,               g.debug_mode)
        _set_element(gui.elements.overlay_enabled,          g.overlay_enabled)
        _apply_global_slider('overlay_x',          slider_int,   0,   3000, g.overlay_x)
        _apply_global_slider('overlay_y',          slider_int,   0,   3000, g.overlay_y)
        _set_element(gui.elements.overlay_show_buffs,       g.overlay_show_buffs)
        _set_element(gui.elements.external_target_override, g.external_target_override)
        _set_element(gui.elements.hold_location_enabled,    g.hold_location_enabled)
        _apply_global_slider('hold_location_range',  slider_float, 3.0, 60.0, g.hold_location_range)
        -- Buff filter checkboxes
        _set_element(gui.elements.bf_paragon,  g.bf_paragon)
        _set_element(gui.elements.bf_talent,   g.bf_talent)
        _set_element(gui.elements.bf_item,     g.bf_item)
        _set_element(gui.elements.bf_npc,      g.bf_npc)
        _set_element(gui.elements.bf_bsk,      g.bf_bsk)
        _set_element(gui.elements.bf_dungeon,  g.bf_dungeon)
        _set_element(gui.elements.bf_passive,  g.bf_passive)
        _set_element(gui.elements.bf_internal, g.bf_internal)
    end

    if type(data.buff_history) == 'table' then
        buff_provider.import_history(data.buff_history)
    end

    if type(data.spells) == 'table' then
        for sid_str, cfg in pairs(data.spells) do
            local sid = tonumber(sid_str)
            if sid and type(cfg) == 'table' then
                cfg = _sanitize_spell_cfg(sid_str, cfg)
                spell_config.apply(sid, cfg)
                if not all_known_set[sid] then
                    all_known_set[sid] = true
                    table.insert(all_known_ids, sid)
                end
            end
        end
    end

    if not silent then
        console.print('[UniversalRotation] Loaded profile: ' .. tostring(display_name))
    end
    return true
end

local function _import_profile(class_key, profile_name, silent, skip_globals)
    class_key    = class_key    or _class_key()
    profile_name = profile_name or _active_profile

    local path = _profile_path_for(class_key, profile_name)
    local f = io.open(path, 'r')
    if not f then
        if not silent then
            console.print('[UniversalRotation] Profile not found: ' .. profile_name .. ' (' .. path .. ')')
        end
        return false
    end
    local json = f:read('*a')
    f:close()

    local data = profile_io.from_json(json)
    if type(data) ~= 'table' then
        if not silent then
            console.print('[UniversalRotation] Import failed: invalid JSON for profile ' .. profile_name)
        end
        return false
    end

    -- Seed the autosave baseline so we don't immediately re-write a
    -- file we just loaded.  The next autosave tick will only write if
    -- the user has actually customized something since this load.
    if profile_name == _active_profile then _last_saved_json = json end

    return _apply_profile_data(data, profile_name, silent, skip_globals)
end

-- Import a profile directly from a JSON string (e.g. downloaded from cloud).
-- Saves to disk under profile_name before applying so it persists.
local function _import_from_json(json_str, profile_name)
    profile_name = profile_name or ('Cloud-' .. tostring(os.time()))
    local data = profile_io.from_json(json_str)
    if type(data) ~= 'table' then
        console.print('[UniversalRotation] Cloud import: invalid profile data')
        return false
    end
    -- Save to disk so the profile persists across reloads
    local class_key = _class_key()
    -- Persist any in-memory customizations on the previously-active
    -- profile before we switch away from it -- otherwise the user's
    -- edits to the prior profile would be lost the moment they import
    -- a new cloud profile.  Skip when re-importing into the same slot.
    if _active_profile and _active_profile ~= profile_name then
        _export_profile(class_key, _active_profile)
    end
    -- Add to profile list if not already present
    local found = false
    for _, n in ipairs(_profile_names) do
        if n == profile_name then found = true; break end
    end
    if not found then
        table.insert(_profile_names, profile_name)
    end
    _active_profile = profile_name
    local path = _profile_path_for(class_key, profile_name)
    -- Strip personal/UI globals (overlay coords, debug mode, keybind-style
    -- toggles, buff filter prefs) from the on-disk copy so reloads don't
    -- clobber the downloader's screen layout or display preferences.
    -- Rotation globals (scan range, anim delay, min enemies, allow_movement,
    -- respect_orb) ARE kept so reloads also restore the uploader's rotation
    -- tuning.  Modern uploads strip personal globals before sending, but we
    -- still strip on receive in case the server holds an older payload.
    _strip_personal_globals(data)
    local sanitized_json = profile_io.to_json(data)
    pcall(function()
        local fw = io.open(path, 'w')
        if fw then fw:write(sanitized_json); fw:close() end
    end)
    -- Seed the autosave baseline -- what's on disk now matches what we
    -- just imported.  Any customization the user makes from here on
    -- will diverge from this snapshot and trigger an autosave write.
    _last_saved_json = sanitized_json
    _save_manifest(class_key)
    _last_profile_idx = _get_active_profile_index()
    _set_element(gui.elements.profile_combo, _last_profile_idx)
    -- Cloud imports apply rotation globals (scan range, anim delay, min enemies)
    -- from the uploader's profile so the rotation behaviour matches their design,
    -- but skip UI globals (overlay position, debug mode) which are personal and
    -- screen-size-dependent.  Per-spell settings are applied via skip_globals=true
    -- inside _apply_profile_data, so the inline block below handles only globals.
    if type(data.global) == 'table' then
        local g = data.global
        _apply_global_slider('scan_range',         slider_float, 5.0, 30.0, g.scan_range)
        _apply_global_slider('anim_delay',         slider_float, 0.0, 0.5,  g.anim_delay)
        _apply_global_slider('global_min_enemies', slider_int,   0,   15,   g.global_min_enemies)
        -- Apply only when the uploader actually set these (older shares
        -- omit them); _set_element no-ops on nil so the receiver's local
        -- toggle survives if the field is absent.
        if g.allow_movement ~= nil then _set_element(gui.elements.allow_movement, g.allow_movement) end
        if g.respect_orb    ~= nil then _set_element(gui.elements.respect_orb,    g.respect_orb)    end
    end
    return _apply_profile_data(data, profile_name, false, true)
end

local function _switch_profile(new_name, class_key)
    class_key = class_key or _class_key()
    if new_name == _active_profile then return end

    -- Save current profile before switching
    _export_profile(class_key, _active_profile)

    -- Switch
    _active_profile = new_name
    _save_manifest(class_key)

    -- Load new profile — skip globals so the user's scan range, overlay
    -- position, and other Global Settings stay fixed across profile switches.
    _import_profile(class_key, new_name, false, true)
end

local function _create_new_profile(class_key)
    class_key = class_key or _class_key()

    -- Find next available name
    local num = #_profile_names + 1
    local name = 'Profile ' .. tostring(num)
    -- Ensure unique
    local exists = true
    while exists do
        exists = false
        for _, n in ipairs(_profile_names) do
            if n == name then exists = true; break end
        end
        if exists then
            num = num + 1
            name = 'Profile ' .. tostring(num)
        end
    end

    -- Persist current settings to the old profile before copying
    local old_active = _active_profile
    _export_profile(class_key, old_active)

    -- Save current settings as the new profile (copy)
    table.insert(_profile_names, name)
    _active_profile = name
    _export_profile(class_key, name)
    _save_manifest(class_key)

    console.print('[UniversalRotation] Created new profile: ' .. name .. ' (copied from ' .. old_active .. ')')
end

local function _delete_profile(class_key)
    class_key = class_key or _class_key()
    if #_profile_names <= 1 then
        console.print('[UniversalRotation] Cannot delete the last profile')
        return
    end

    local to_delete = _active_profile
    local path = _profile_path_for(class_key, to_delete)

    -- Remove from list
    for i, n in ipairs(_profile_names) do
        if n == to_delete then
            table.remove(_profile_names, i)
            break
        end
    end

    -- Switch to first remaining profile
    _active_profile = _profile_names[1] or 'Default'
    _save_manifest(class_key)

    -- Delete the file
    pcall(function() os.remove(path) end)

    -- Load the new active profile — skip globals for same reason as _switch_profile
    _import_profile(class_key, _active_profile, false, true)
    console.print('[UniversalRotation] Deleted profile: ' .. to_delete)
end

local function _rename_profile(new_name, class_key)
    class_key = class_key or _class_key()
    new_name = tostring(new_name):gsub('^%s+', ''):gsub('%s+$', '')  -- trim
    if new_name == '' then return end
    if new_name == _active_profile then return end

    -- Check for duplicate
    for _, n in ipairs(_profile_names) do
        if n == new_name then
            console.print('[UniversalRotation] Profile name already exists: ' .. new_name)
            return
        end
    end

    local old_name = _active_profile
    local old_path = _profile_path_for(class_key, old_name)
    local new_path = _profile_path_for(class_key, new_name)

    -- Update list in-place
    for i, n in ipairs(_profile_names) do
        if n == old_name then
            _profile_names[i] = new_name
            break
        end
    end
    _active_profile = new_name

    -- Rename the file: write under new name, delete old (os.rename may not work cross-device)
    local f = io.open(old_path, 'r')
    if f then
        local content = f:read('*a')
        f:close()
        local fw = io.open(new_path, 'w')
        if fw then
            fw:write(content)
            fw:close()
        end
        pcall(function() os.remove(old_path) end)
    end

    _save_manifest(class_key)
    console.print('[UniversalRotation] Renamed profile: ' .. old_name .. ' → ' .. new_name)
end

-- Throttled autosave.  Runs every AUTOSAVE_INTERVAL seconds; rebuilds
-- the active profile's JSON, compares against the last snapshot we
-- wrote/loaded, and only writes when the user has actually changed
-- something.  This is what keeps customizations on a cloud-downloaded
-- (or any other) profile alive across reloads -- without it, the
-- on-disk file stays the pristine downloaded copy and tweaks vanish.
local function _autosave_if_dirty()
    if not _active_profile or _active_profile == '' then return end
    local ck = _class_key()
    if not ck or ck == '' or ck == 'unknown' then return end

    local now = get_time_since_inject()
    if now - _last_autosave_t < AUTOSAVE_INTERVAL then return end
    _last_autosave_t = now

    -- _last_saved_json being nil means no prior import or export has
    -- seeded a baseline (e.g. fresh install with no profile file, or
    -- _import_profile silently failed because the file was missing).
    -- In that case treat the in-memory state as dirty so the first
    -- autosave creates the file and seeds the baseline going forward.
    local json = _build_profile_json(ck, _active_profile)
    if json == _last_saved_json then return end

    local path = _profile_path_for(ck, _active_profile)
    local ok = pcall(function()
        local f = assert(io.open(path, 'w'))
        f:write(json)
        f:close()
    end)
    if ok then _last_saved_json = json end
end

local function handle_profile_io()
    -- Manual export/import/reload buttons removed -- cloud sharing is the
    -- only blessed sync path now.  _export_profile / _import_profile are
    -- still called below (and from the cloud import path) for on-disk
    -- persistence across profile switches and sessions.

    -- New profile button
    if gui.elements.new_profile and gui.elements.new_profile:get() then
        _create_new_profile()
        _last_profile_idx = _get_active_profile_index()
        _set_element(gui.elements.profile_combo, _last_profile_idx)
        gui.elements.new_profile:set(false)
    end

    -- Delete profile button
    if gui.elements.delete_profile and gui.elements.delete_profile:get() then
        _delete_profile()
        _last_profile_idx = _get_active_profile_index()
        _set_element(gui.elements.profile_combo, _last_profile_idx)
        gui.elements.delete_profile:set(false)
    end

    -- Profile rename: fires when the standalone Apply Rename checkbox
    -- ticks to true; reads the current text from profile_rename and
    -- resets the checkbox immediately.
    if gui.elements.profile_rename_btn and gui.elements.profile_rename_btn:get() then
        gui.elements.profile_rename_btn:set(false)
        local rename_el = gui.elements.profile_rename
        local new_name = ''
        if rename_el and type(rename_el.get) == 'function' then
            local ok, v = pcall(rename_el.get, rename_el)
            if ok and type(v) == 'string' then new_name = v end
        end
        if new_name and new_name ~= '' then
            _rename_profile(new_name)
            _last_profile_idx = _get_active_profile_index()
            _set_element(gui.elements.profile_combo, _last_profile_idx)
        end
    end

    -- Profile dropdown switching
    if gui.elements.profile_combo then
        local sel = gui.elements.profile_combo:get()
        if type(sel) == 'number' and sel ~= _last_profile_idx then
            local new_name = _profile_names[sel + 1]
            if new_name and new_name ~= _active_profile then
                _switch_profile(new_name)
            end
            _last_profile_idx = sel
        end
    end

    -- ---- Cloud sharing ----
    local ck = _class_key()

    -- Update existing share (checkbox button — only visible when profile is already shared)
    if gui.elements.cloud_share_btn and gui.elements.cloud_share_btn:get() then
        console.print('[UniversalRotation] Uploading profile to cloud...')
        -- for_share=true strips the uploader's personal/UI globals (overlay
        -- coords, debug toggle, buff filter prefs, etc.) before the upload.
        local json = _build_profile_json(ck, _active_profile, true)
        local result = cloud_share.share(ck, _active_profile, json, nil)
        if result.ok then
            console.print('[UniversalRotation] Cloud profile updated!  Code: ' .. result.code)
            -- Pull the fresh listing (with the bumped updated_at) inline so
            -- the user sees their own entry move to the top of the picker.
            _refresh_cloud_listing(ck)
        else
            console.print('[UniversalRotation] Cloud update failed: ' .. tostring(result.error))
        end
        gui.elements.cloud_share_btn:set(false)
    end

    -- New share: standalone Share Profile checkbox (visible only when
    -- the profile has not been shared yet -- the GUI hides the button
    -- in the already-shared branch).
    if gui.elements.cloud_share_new_btn and gui.elements.cloud_share_new_btn:get() then
        gui.elements.cloud_share_new_btn:set(false)
        -- input_text :get can also raise a host-side error when the widget's
        -- internal state hasn't settled (mirrors the :render crash gated by
        -- _safe_input_render in gui.lua).  pcall + fallback to the active
        -- profile name keeps the share path alive instead of crashing.
        local cs_el = gui.elements.cloud_share_name
        local display_name = ''
        if cs_el and type(cs_el.get) == 'function' then
            local ok, v = pcall(cs_el.get, cs_el)
            if ok and type(v) == 'string' then display_name = v end
        end
        if not display_name or display_name == '' then display_name = _active_profile end
        console.print('[UniversalRotation] Uploading profile to cloud as "' .. display_name .. '"...')
        -- for_share=true: see the Update branch above for rationale.
        local json = _build_profile_json(ck, _active_profile, true)
        local result = cloud_share.share(ck, _active_profile, json, display_name)
        if result.ok then
            console.print('[UniversalRotation] Profile shared!  Code: ' .. result.code
                .. '  (share this code with others so they can import it)')
            -- Refresh the picker so the brand-new entry appears.
            _refresh_cloud_listing(ck)
        else
            console.print('[UniversalRotation] Cloud share failed: ' .. tostring(result.error))
        end
    end

    -- Manual refresh of the cloud listing.  Wired separately so the
    -- (always-blocking) curl call is exclusively user-triggered, never
    -- automatic on script start.
    if gui.elements.cloud_refresh_btn and gui.elements.cloud_refresh_btn:get() then
        gui.elements.cloud_refresh_btn:set(false)
        _refresh_cloud_listing(ck)
    end

    -- (No Browse button; the listing renders from the on-disk cache via
    -- _auto_load_cloud_listing on class detection.  Server fetches are
    -- triggered explicitly by Refresh from Server / Share / Update.)

    -- Import Selected (in-menu picker) -- downloads the profile the user
    -- highlighted in the cloud_browse_combo and applies it.
    if gui.elements.cloud_import_selected_btn and gui.elements.cloud_import_selected_btn:get() then
        gui.elements.cloud_import_selected_btn:set(false)
        local profs = _cloud_browse.profiles
        if type(profs) == 'table' and #profs > 0 then
            local sel = 0
            if gui.elements.cloud_browse_combo and gui.elements.cloud_browse_combo.get then
                local s = gui.elements.cloud_browse_combo:get()
                if type(s) == 'number' then sel = s end
            end
            local entry = profs[sel + 1]   -- combo is 0-based
            if entry and entry.code then
                console.print('[UniversalRotation] Downloading cloud profile ' .. entry.code .. '...')
                local result = cloud_share.download(entry.code)
                if result.ok then
                    local profile_name = result.name or entry.name or ('Cloud-' .. entry.code)
                    local ok = _import_from_json(result.data, profile_name)
                    if ok then
                        console.print('[UniversalRotation] Imported cloud profile: ' .. profile_name)
                    end
                else
                    console.print('[UniversalRotation] Download failed: ' .. tostring(result.error))
                end
            end
        else
            console.print('[UniversalRotation] No browsed profiles to import — click Browse first.')
        end
    end

    -- Import by code: standalone Import Profile checkbox.  Reads the
    -- code from the cloud_import_code text field and downloads.
    if gui.elements.cloud_import_code_btn and gui.elements.cloud_import_code_btn:get() then
        gui.elements.cloud_import_code_btn:set(false)
        local ci_el = gui.elements.cloud_import_code
        local code = ''
        if ci_el and type(ci_el.get) == 'function' then
            local ok, v = pcall(ci_el.get, ci_el)
            if ok and type(v) == 'string' then code = v end
        end
        if code and code ~= '' then
            console.print('[UniversalRotation] Downloading cloud profile ' .. code .. '...')
            local result = cloud_share.download(code)
            if result.ok then
                local profile_name = result.name or ('Cloud-' .. code)
                local ok = _import_from_json(result.data, profile_name)
                if ok then
                    console.print('[UniversalRotation] Imported cloud profile: ' .. profile_name)
                end
            else
                console.print('[UniversalRotation] Download failed: ' .. tostring(result.error))
            end
        end
    end

    -- ---- Hold Location ----
    -- Keybind: when "Use Keybind" is on, drive the enabled checkbox from
    -- the keybind's toggle state so the key works independently of the checkbox.
    if gui.elements.use_hold_loc_keybind and gui.elements.use_hold_loc_keybind:get() then
        local vk, st = 0x0A, false
        pcall(function()
            vk = gui.elements.hold_loc_keybind:get_key()
            st = gui.elements.hold_loc_keybind:get_state()
        end)
        if vk ~= 0x0A then
            local kb_active = (st == 1 or st == true)
            if gui.elements.hold_location_enabled then
                pcall(gui.elements.hold_location_enabled.set, gui.elements.hold_location_enabled, kb_active)
            end
        end
    end

    local hl_en = gui.elements.hold_location_enabled and gui.elements.hold_location_enabled:get() or false

    -- Rising edge: always auto-capture position whenever the feature is enabled
    -- (whether via checkbox or keybind) — no need to click "Set Position Here"
    if hl_en and not _hold_loc_prev_en then
        local lp2 = get_local_player()
        if lp2 then
            local ok2, pos2 = pcall(function() return lp2:get_position() end)
            if ok2 and pos2 then
                _hold_pos = pos2
                console.print('[UniversalRotation] Hold location auto-set to current position')
            end
        end
    end

    -- Falling edge: clear the stored position when disabled
    if not hl_en and _hold_loc_prev_en then
        _hold_pos = nil
    end

    _hold_loc_prev_en = hl_en

    -- Manual "Set Position Here" button
    if gui.elements.hold_location_set_btn and gui.elements.hold_location_set_btn:get() then
        local lp2 = get_local_player()
        if lp2 then
            local ok2, pos2 = pcall(function() return lp2:get_position() end)
            if ok2 and pos2 then
                _hold_pos = pos2
                console.print('[UniversalRotation] Hold location pinned to current position')
            end
        end
        gui.elements.hold_location_set_btn:set(false)
    end

    -- Persist any pending GUI edits to disk on a throttle.  Without
    -- this, customizations made after a cloud download (or any
    -- profile load) are lost on reload because the on-disk file
    -- still holds the original imported copy.
    _autosave_if_dirty()
end

local _cloud_ready = false

-- One-shot per class: render the on-disk listing cache immediately on
-- script load.  No network call here -- io.popen on Windows briefly
-- flashes a CMD console window because Lua's GUI host doesn't pass
-- CREATE_NO_WINDOW to the curl child.  We keep the popen out of every
-- automatic path; the user explicitly refreshes via the Cloud Sharing
-- "Refresh from Server" button (see _refresh_cloud_listing below).
_auto_load_cloud_listing = function(ck)
    if not ck or ck == '' then return end
    if ck == 'unknown' then return end
    if _cloud_auto_loaded_class == ck then return end
    _cloud_auto_loaded_class = ck

    local cached = cloud_share.load_cached_listing(ck)
    if type(cached) == 'table' then
        _apply_cloud_listing(ck, cached, os.time())
    else
        _cloud_browse.class      = ck
        _cloud_browse.profiles   = nil
        _cloud_browse.labels     = nil
        _cloud_browse.details    = nil
        _cloud_browse.error      = nil
        _cloud_browse.fetched_at = 0
    end
end

-- Manual refresh: triggered by the Refresh from Server button (and
-- after a successful Share / Update so the user sees their own entry
-- without a script reload).  This is the ONLY place that calls
-- cloud_share.list, so the io.popen / CMD flash is always tied to a
-- user-visible action.
_refresh_cloud_listing = function(ck)
    if not ck or ck == '' or ck == 'unknown' then return end
    console.print('[UniversalRotation] Refreshing cloud listing for ' .. ck .. '...')
    local profs, err = cloud_share.list(ck)
    if type(profs) == 'table' then
        _apply_cloud_listing(ck, profs, os.time())
        cloud_share.save_cached_listing(ck, profs)
        console.print(string.format(
            '[UniversalRotation] Cloud listing refreshed (%d profile(s)).',
            #profs))
    else
        console.print('[UniversalRotation] Refresh failed: ' .. tostring(err))
    end
end

local function handle_class_profiles()
    if not _cloud_ready then
        cloud_share.init(get_script_root())
        _cloud_ready = true
    end

    local ck = _class_key()
    if not last_class_key then
        last_class_key = ck
        _load_manifest(ck)
        _import_profile(ck, _active_profile, true)
        _last_profile_idx = _get_active_profile_index()
        _set_element(gui.elements.profile_combo, _last_profile_idx)
        _auto_load_cloud_listing(ck)
        return
    end
    if ck ~= last_class_key then
        -- Save current profile and manifest for old class
        _export_profile(last_class_key, _active_profile)

        equipped_ids  = {}
        all_known_ids = {}
        all_known_set = {}
        last_scan     = -999

        buff_provider.clear_history()
        spell_tracker.reset_all()
        rotation_engine.reset()

        last_class_key = ck
        _load_manifest(ck)
        _import_profile(ck, _active_profile, true)
        _last_profile_idx = _get_active_profile_index()
        _set_element(gui.elements.profile_combo, _last_profile_idx)
    end

    -- Picks up the initial load and any post-share invalidations.
    _auto_load_cloud_listing(ck)
end
local function render_overlay()
    if not is_enabled() then return end

    local sw = get_screen_width()
    local sh = get_screen_height()
    if not sw or not sh then return end

    local lp = get_local_player()
    if not lp then return end

    if not settings.overlay_enabled then return end

    local x  = settings.overlay_x or (sw - 220)
    local y  = settings.overlay_y or 12
    local lh = 18
    local sz = 14

    local function line(text, col)
        graphics.text_2d(text, vec2:new(x, y), sz, col or color_white(220))
        y = y + lh
    end

    line('[ Universal Rotation ]', color_yellow(255))
    if _active_profile and _active_profile ~= 'Default' then
        line(string.format('%s | %d spells', _active_profile, #equipped_ids), color_white(180))
    else
        line(string.format('%d spells equipped', #equipped_ids), color_white(180))
    end

    local shown = 0
    local now_t = get_time_since_inject()

    -- Chain boost tracking (mirror rotation_engine's internal table isn't exposed,
    -- so we read from spell_config chain fields to show a UI hint only)
    local TARGET_MODE_SHORT = { [0]='PRI', [1]='NEAR', [2]='LHP', [3]='HHP', [4]='CLV', [5]='CUR' }

    local spell_list = {}
    for _, spell_id in ipairs(equipped_ids) do
        if spell_id > 1 then
            local cfg = spell_config.get(spell_id)
            if cfg.enabled then
                table.insert(spell_list, { id = spell_id, cfg = cfg, is_virtual = false })
            end
        end
    end
    -- Include virtual evade spell
    local evade_cfg = spell_config.get(gui.VIRTUAL_EVADE_ID)
    if evade_cfg.enabled then
        table.insert(spell_list, { id = gui.VIRTUAL_EVADE_ID, cfg = evade_cfg, is_virtual = true })
    end
    table.sort(spell_list, function(a, b) return a.cfg.priority < b.cfg.priority end)

    for _, entry in ipairs(spell_list) do
        if shown >= 8 then break end
        shown = shown + 1
        local id   = entry.id
        local cfg  = entry.cfg
        local is_virt = entry.is_virtual

        local name
        if is_virt then
            name = 'Evade'
        else
            name = _pretty_spell_name(get_name_for_spell(id)) or tostring(id)
        end

        local ready
        if is_virt then
            ready = true  -- virtual spells are always "ready"
        else
            ready = utility.is_spell_ready(id) and utility.is_spell_affordable(id)
        end
        local on_cd = not spell_tracker.is_off_cooldown(id, cfg.cooldown, cfg.charges)

        local charges_left, charges_max = spell_tracker.get_charges(id, cfg.charges)
        local charge_txt = ''
        if charges_max and charges_max > 1 then
            charge_txt = string.format(' %d/%d', charges_left, charges_max)
        end

        -- Annotate target mode if non-default
        local mode_txt = ''
        if not cfg.self_cast then
            local m = cfg.target_mode or 0
            if m ~= 0 then
                mode_txt = ' [' .. (TARGET_MODE_SHORT[m] or '?') .. ']'
            end
        else
            mode_txt = ' [SELF]'
        end

        -- Annotate cast method
        local cm = cfg.cast_method or 0
        if cm == 1 then
            mode_txt = mode_txt .. ' [KEY]'
        elseif cm == 2 then
            mode_txt = mode_txt .. ' [FSS]'
        end

        -- Resource condition hint
        local res_txt = ''
        if cfg.use_resource then
            local sym = (cfg.resource_mode == 0) and '<' or '>='
            local unit = ((cfg.resource_type or 0) == 1) and '' or '%'
            local prefix = ((cfg.resource_type or 0) == 1) and 'cp' or 'res'
            res_txt = string.format(' %s%s%d%s', prefix, sym, cfg.resource_pct or 50, unit)
        end

        local label = string.format('[%d] %s%s%s%s',
            cfg.priority, name:sub(1, 14), charge_txt, mode_txt, res_txt)

        local col
        if not ready then
            col = color_red(200)
            label = label .. ' (N/A)'
        elseif on_cd then
            col = color_yellow(200)
            label = label .. ' (CD)'
        else
            col = color_green(255)
            label = label .. ' (RDY)'
        end
        line(label, col)
    end

    if settings.overlay_show_buffs then
        y = y + 6
        line('[ Active Buffs ]', color_white(200))

        local buffs = {}
        if buff_provider and type(buff_provider.get_active_buffs) == 'function' then
            buffs = buff_provider.get_active_buffs()
        else
            local p = get_local_player and get_local_player()
            if p and type(p.get_buffs) == 'function' then
                buffs = p:get_buffs() or {}
            end
        end

        local shown_b = 0
        for _, b in ipairs(buffs) do
            if shown_b >= 10 then break end

            local name = nil
            local stacks = 0
            local rem = nil

            if type(b) == 'table' and b.name then
                name = b.name
                stacks = b.stacks or 0
                rem = b.remaining
            else
                if type(b.name) == 'function' then name = b:name() end
                if not name and type(b.get_name) == 'function' then name = b:get_name() end
                if type(b.get_stacks) == 'function' then stacks = b:get_stacks() end
                if type(b.stacks) == 'number' then stacks = b.stacks end
                if type(b.get_remaining_time) == 'function' then rem = b:get_remaining_time() end
            end

            name = tostring(name or 'Buff')
            stacks = tonumber(stacks) or 0

            local txt = name
            if stacks > 0 then txt = txt .. string.format(' (%d)', stacks) end
            if type(rem) == 'number' and rem >= 0 then
                txt = txt .. string.format(' %.1fs', rem)
            end

            line(txt:sub(1, 34), color_white(170))
            shown_b = shown_b + 1
        end
    end

end

local _last_buff_observe = -999
local function _observe_buffs_throttled()
    local now = get_time_since_inject()
    if now - _last_buff_observe < 1.0 then return end
    _last_buff_observe = now
    if buff_provider.observe_player_buffs() then
        spell_config.invalidate_buff_lists()
    end
end

-- ── Global plugin API ─────────────────────────────────────────────────────────
-- Other scripts can call these via _G.UNIVERSAL_ROTATION.<fn>()
-- Example: _G.UNIVERSAL_ROTATION.set_enabled(true)
_G.UNIVERSAL_ROTATION = {

    -- ---- Toggle ----
    set_enabled = function(value)
        if gui.elements.enabled then gui.elements.enabled:set(value and true or false) end
    end,
    get_enabled = function()
        return gui.elements.enabled and gui.elements.enabled:get() or false
    end,

    -- ---- Profile management ----
    get_active_profile = function()
        return _active_profile
    end,
    get_profile_names = function()
        local out = {}
        for i, n in ipairs(_profile_names) do out[i] = n end
        return out
    end,
    set_profile = function(name)
        _switch_profile(name)
    end,
    save_profile = function()
        _export_profile()
    end,
    load_profile = function()
        _import_profile(nil, _active_profile, false)
    end,

    -- ---- Class / spell info ----
    get_class_key = function()
        return _class_key()
    end,
    get_equipped_spell_ids = function()
        local out = {}
        for i, id in ipairs(equipped_ids) do out[i] = id end
        return out
    end,

    -- ---- Global settings ----
    get_scan_range = function()
        return gui.elements.scan_range and gui.elements.scan_range:get() or settings.scan_range
    end,
    set_scan_range = function(value)
        if gui.elements.scan_range then gui.elements.scan_range:set(tonumber(value) or 16.0) end
    end,

    get_anim_delay = function()
        return gui.elements.anim_delay and gui.elements.anim_delay:get() or settings.anim_delay
    end,
    set_anim_delay = function(value)
        if gui.elements.anim_delay then gui.elements.anim_delay:set(tonumber(value) or 0.05) end
    end,

    get_global_min_enemies = function()
        return gui.elements.global_min_enemies and gui.elements.global_min_enemies:get() or settings.global_min_enemies
    end,
    set_global_min_enemies = function(value)
        if gui.elements.global_min_enemies then gui.elements.global_min_enemies:set(math.max(0, math.floor(tonumber(value) or 0))) end
    end,

    get_debug = function()
        return gui.elements.debug_mode and gui.elements.debug_mode:get() or false
    end,
    set_debug = function(value)
        if gui.elements.debug_mode then gui.elements.debug_mode:set(value and true or false) end
    end,

    get_respect_orb = function()
        return gui.elements.respect_orb and gui.elements.respect_orb:get() or false
    end,
    set_respect_orb = function(value)
        if gui.elements.respect_orb then gui.elements.respect_orb:set(value and true or false) end
    end,

    get_allow_movement = function()
        return gui.elements.allow_movement and gui.elements.allow_movement:get() or false
    end,
    set_allow_movement = function(value)
        if gui.elements.allow_movement then gui.elements.allow_movement:set(value and true or false) end
    end,

    get_warmachine_override = function()
        return gui.elements.warmachine_override and gui.elements.warmachine_override:get() or false
    end,
    set_warmachine_override = function(value)
        if gui.elements.warmachine_override then gui.elements.warmachine_override:set(value and true or false) end
    end,

    -- ---- Hold Location ----
    get_hold_location_enabled = function()
        return gui.elements.hold_location_enabled and gui.elements.hold_location_enabled:get() or false
    end,
    -- Enabling via API always captures the current player position, same as
    -- the checkbox rising-edge behaviour.  Pass value=false to disable and
    -- clear the pin.
    set_hold_location_enabled = function(value)
        if gui.elements.hold_location_enabled then
            gui.elements.hold_location_enabled:set(value and true or false)
        end
        -- Force-trigger a position capture when enabling (mirrors the
        -- handle_profile_io rising-edge logic which runs next tick).
        -- Done inline here so callers don't need to wait a frame.
        if value then
            local lp = get_local_player()
            if lp then
                local ok, pos = pcall(function() return lp:get_position() end)
                if ok and pos then _hold_pos = pos end
            end
        else
            _hold_pos = nil
        end
    end,
    get_hold_location_range = function()
        return gui.elements.hold_location_range and gui.elements.hold_location_range:get() or 15.0
    end,
    set_hold_location_range = function(value)
        if gui.elements.hold_location_range then gui.elements.hold_location_range:set(tonumber(value) or 15.0) end
    end,
    -- Returns the current pinned position as {x, y, z}, or nil if not set.
    get_hold_location_pos = function()
        if not _hold_pos then return nil end
        local ok, x, y, z = pcall(function()
            return _hold_pos:x(), _hold_pos:y(), _hold_pos:z()
        end)
        if ok and x then return { x = x, y = y, z = z } end
        return nil
    end,
    -- Explicitly pin to the current player position without toggling on/off.
    set_hold_location_here = function()
        local lp = get_local_player()
        if not lp then return false end
        local ok, pos = pcall(function() return lp:get_position() end)
        if ok and pos then _hold_pos = pos; return true end
        return false
    end,
}
-- ─────────────────────────────────────────────────────────────────────────────

on_update(function()
    handle_class_profiles()
    refresh_equipped()
    update_settings()
    handle_profile_io()
    _observe_buffs_throttled()

    if not is_enabled() then return end

    local lp = get_local_player()
    if not lp then return end
    if lp:is_dead() then return end

    -- Hold Location: if the player has drifted outside the hold circle,
    -- move them back and skip the rotation this tick.
    if settings.hold_location_enabled and settings.hold_location_pos then
        local ok_pos, lp_pos = pcall(function() return lp:get_position() end)
        if ok_pos and lp_pos then
            local r = settings.hold_location_range or 15.0
            local ok_d, d2 = pcall(function()
                return lp_pos:squared_dist_to_ignore_z(settings.hold_location_pos)
            end)
            if ok_d and d2 and d2 > r * r then
                if pathfinder and type(pathfinder.request_move) == 'function' then
                    pcall(pathfinder.request_move, settings.hold_location_pos)
                end
                return
            end
        end
    end

    local ok, err = pcall(rotation_engine.tick, equipped_ids, settings)
    if not ok then
        console.print('[UniversalRotation] rotation_engine.tick error: ' .. tostring(err))
    end
end)

on_render_menu(function()
    local cloud_info = cloud_share.get_share_info(_class_key(), _active_profile)
    local hold_info  = nil
    if _hold_pos then
        local ok, x, y = pcall(function()
            return _hold_pos:x(), _hold_pos:y()
        end)
        if ok and x then
            hold_info = { label = string.format('Pinned: %.1f, %.1f', x, y) }
        end
    end
    gui.render(spell_config, equipped_ids, all_known_ids, _profile_names, _active_profile, cloud_info, _cloud_browse, hold_info)
end)

on_render(function()
    render_overlay()
end)

-- ---------------------------------------------------------------------------
-- Public global API.  External plugins (Gem Farmer, WarMachine, etc.) can
-- toggle the External Target Override programmatically without reaching into
-- UR's gui internals.  When ON, UR ONLY casts at _G.EXTERNAL_ROTATION_TARGET
-- (no fallback to its own picker, holds fire when the global is nil).
--
-- Typical usage from another plugin:
--
--   if UniversalRotationPlugin then
--       local prev = UniversalRotationPlugin.get_external_target_override()
--       UniversalRotationPlugin.set_external_target_override(true)
--       -- ... do bot work, write _G.EXTERNAL_ROTATION_TARGET ...
--       UniversalRotationPlugin.set_external_target_override(prev)
--   end
--
-- Setters are a no-op if the gui hasn't initialized the element yet (won't
-- happen in practice because the element is created at module load).
-- ---------------------------------------------------------------------------
UniversalRotationPlugin = {
    set_external_target_override = function (enabled)
        if gui.elements.external_target_override then
            gui.elements.external_target_override:set(enabled and true or false)
        end
    end,
    get_external_target_override = function ()
        if gui.elements.external_target_override then
            return gui.elements.external_target_override:get()
        end
        return false
    end,
    is_enabled = function ()
        if gui.elements.enabled then return gui.elements.enabled:get() end
        return false
    end,
}