local plugin_label   = 'magoogles_universal_rotation'
local plugin_version = '1.0.34'
console.print('Lua Plugin - Magoogles Universal Rotation - v' .. plugin_version)

local gui = {}

local _spell_trees = {}

local function _get_spell_tree(spell_id)
    local id = tostring(spell_id)
    if _spell_trees[id] then return _spell_trees[id] end
    local t = tree_node:new(2)
    _spell_trees[id] = t
    return t
end

local function _pretty_spell_name(raw)
    if not raw or raw == '' then return nil end
    raw = tostring(raw):gsub('[%[%]]', ''):gsub('^%s+', ''):gsub('%s+$', '')
    local parts = {}
    for p in raw:gmatch('[^_]+') do parts[#parts + 1] = p end
    if #parts >= 2 then table.remove(parts, 1) end -- drop class prefix
    local phrase = table.concat(parts, ' ')
    phrase = phrase:lower():gsub('(%a)([%w\']*)', function(a, b) return a:upper() .. b end)
    return phrase
end


local function cb(default, key)
    return checkbox:new(default, get_hash(plugin_label .. '_' .. key))
end
local function si(min, max, default, key)
    return slider_int:new(min, max, default, get_hash(plugin_label .. '_' .. key))
end
local function sf(min, max, default, key)
    return slider_float:new(min, max, default, get_hash(plugin_label .. '_' .. key))
end

-- input_text widgets sometimes raise a Lua error from inside :render when
-- the user types into them in a state the host's widget binding does not
-- like (reproducible: typing into "Cloud Sharing > Display Name" before
-- the cloud listing has been fetched -- the host crashed the whole game).
-- Bare :render calls let that error propagate up to the host, which kills
-- the game.  spell_config.lua's buff_search has long wrapped its render in
-- pcall for this exact reason; we now apply the same pattern to every
-- input_text in gui.lua.  On render failure we drop a fresh-hash widget
-- in place so the next frame starts clean instead of repeating the crash.
local _input_gen = {}
local function _safe_input_render(field_key, label, tooltip)
    local el = gui.elements[field_key]
    if not el then return end
    local ok = pcall(function()
        el:render(label, tooltip, false, '', '')
    end)
    if not ok then
        _input_gen[field_key] = (_input_gen[field_key] or 0) + 1
        local fresh = get_hash(plugin_label .. '_' .. field_key .. '_g' .. _input_gen[field_key])
        gui.elements[field_key] = input_text:new(fresh)
    end
end

gui.plugin_label   = plugin_label
gui.plugin_version = plugin_version

-- Sentinel ID for virtual evade spell (won't collide with real spell IDs)
gui.VIRTUAL_EVADE_ID = 999999999

gui.elements = {
    main_tree      = tree_node:new(0),
    enabled        = cb(true, 'enabled'),
    use_keybind    = cb(false, 'use_keybind'),
    keybind        = keybind:new(0x0A, true, get_hash(plugin_label .. '_keybind')),

    -- Hold-to-cast: rotation only runs while this key is held
    use_hold_key   = cb(false, 'use_hold_key'),
    hold_keybind   = keybind:new(0x0A, false, get_hash(plugin_label .. '_hold_keybind')),

    global_tree    = tree_node:new(1),
    scan_range     = sf(5.0, 30.0, 16.0, 'scan_range'),
    anim_delay     = sf(0.0, 0.5,  0.05, 'anim_delay'),
    global_min_enemies = si(0, 15, 0, 'global_min_enemies'),
    allow_movement = cb(false, 'allow_movement'),       -- pathfinder.request_move for melee positioning
    respect_orb    = cb(true,  'respect_orb'),          -- only act when orbwalker is active or hold-key is held
    -- External target override: when ON, UR's targeting becomes
    -- AUTHORITATIVE on _G.EXTERNAL_ROTATION_TARGET -- it casts only
    -- at the external plugin's pick (or holds fire if the plugin
    -- has cleared the target).  When OFF (default), the external
    -- target is a HINT and UR falls back to its own target_selector
    -- when the hint is missing/invalid.  Turn ON when running an
    -- external bot (WarMachine activities, Gem Farmer, etc.) so
    -- combat doesn't pull the bot off its navigation goal -- the
    -- external plugin controls when to fight.
    external_target_override = cb(false, 'external_target_override'),
    debug_mode     = cb(false, 'debug_mode'),

    los_enabled    = cb(false, 'los_enabled'),
    los_height_max = sf(0.3, 8.0, 1.5, 'los_height_max'),


    overlay_enabled = cb(true, 'overlay_enabled'),
    overlay_x       = si(0, 3000, 20, 'overlay_x'),
    overlay_y       = si(0, 3000, 20, 'overlay_y'),
    overlay_show_buffs = cb(false, 'overlay_show_buffs'),

    -- Multi-profile controls
    profile_combo      = combo_box:new(0, get_hash(plugin_label .. '_profile_combo')),
    profile_rename     = input_text:new(get_hash(plugin_label .. '_profile_rename')),
    -- Standalone Apply button (the input_text's built-in button is awkward
    -- because it fires on the input's close-edge; a checkbox-as-button is
    -- more predictable -- main.lua reads it, applies, then resets it).
    profile_rename_btn = cb(false, 'profile_rename_btn'),
    new_profile        = cb(false, 'new_profile'),
    delete_profile     = cb(false, 'delete_profile'),

    equipped_tree  = tree_node:new(1),
    inactive_tree  = tree_node:new(1),
    evade_tree     = tree_node:new(1),

    -- Unified profile management dropdown.  Wraps the per-class profile
    -- selector, rename/new/delete, JSON reload, file export/import, and
    -- the nested Cloud Sharing tree -- everything that touches a profile
    -- lives in one place.
    profiles_tree     = tree_node:new(1),

    -- Cloud sharing (nested inside profiles_tree)
    cloud_tree            = tree_node:new(1),
    cloud_share_name      = input_text:new(get_hash(plugin_label .. '_cloud_share_name')),
    -- Standalone Share button (replaces the input_text's built-in button --
    -- main.lua reads it, uploads, then resets it on the next tick).
    cloud_share_new_btn   = cb(false, 'cloud_share_new_btn'),
    -- "Update existing share" -- only visible when the active profile has
    -- already been shared.
    cloud_share_btn       = cb(false, 'cloud_share_btn'),
    -- Manual refresh.  The auto-load on script start reads the on-disk
    -- cache only; this button is the only path that actually hits the
    -- server (so the curl-spawn console flash is always user-triggered).
    cloud_refresh_btn     = cb(false, 'cloud_refresh_btn'),
    -- In-menu picker for the cached cloud listing.  Items list is
    -- rebuilt each render from cloud_browse.labels; index is read by
    -- main.lua when the Import Selected button fires.
    cloud_browse_combo        = combo_box:new(0, get_hash(plugin_label .. '_cloud_browse_combo')),
    cloud_import_selected_btn = cb(false, 'cloud_import_selected_btn'),
    cloud_import_code         = input_text:new(get_hash(plugin_label .. '_cloud_import_code')),
    cloud_import_code_btn     = cb(false, 'cloud_import_code_btn'),

    -- Hold Location
    hold_location_tree     = tree_node:new(1),
    hold_location_enabled  = cb(false, 'hold_location_enabled'),
    hold_location_range    = sf(3.0, 60.0, 15.0, 'hold_location_range'),
    hold_location_set_btn  = cb(false, 'hold_location_set_btn'),
    use_hold_loc_keybind   = cb(false, 'use_hold_loc_keybind'),
    hold_loc_keybind       = keybind:new(0x0A, true, get_hash(plugin_label .. '_hold_loc_keybind')),

    -- Buff filter checkboxes (controls which categories appear in buff dropdowns)
    buff_filter_tree    = tree_node:new(2),
    -- One-shot diagnostic button: prints every buff currently on the
    -- player (hash + name + stacks) to console.  Use to verify a
    -- spell's "Buff Condition" hash actually matches what's active --
    -- the most common Missing-mode bug is the user picking the SKILL
    -- entry from the dropdown instead of the buff-EFFECT entry, which
    -- have different hashes.
    bf_dump_buffs       = cb(false, 'bf_dump_buffs'),
    bf_paragon          = cb(false, 'bf_paragon'),
    bf_talent           = cb(false, 'bf_talent'),
    bf_item             = cb(false, 'bf_item'),
    bf_npc              = cb(false, 'bf_npc'),
    bf_bsk              = cb(false, 'bf_bsk'),
    bf_dungeon          = cb(false, 'bf_dungeon'),
    bf_passive          = cb(false, 'bf_passive'),
    bf_internal         = cb(false, 'bf_internal'),
}

-- cloud_browse: { profiles=array|nil, error=string|nil, fetched_at=number, class=string }
--   profiles is the array returned by cloud_share.list (each entry has
--   code, name, updated_at).  nil = never fetched.  Empty array = fetched
--   and the server had nothing for this class.
gui.render = function(spell_config, equipped_ids, all_known_ids, profile_names, active_profile, cloud_info, cloud_browse, hold_info)
    if not gui.elements.main_tree:push('Magoogles Universal Rotation | v' .. plugin_version) then return end

    gui.elements.enabled:render('Enable', 'Enable the universal rotation')
    gui.elements.use_keybind:render('Use keybind', 'Toggle rotation on/off with a key')
    if gui.elements.use_keybind:get() then
        gui.elements.keybind:render('Toggle Key', 'Key to toggle the rotation')
    end

    gui.elements.use_hold_key:render('Hold-to-Cast', 'Rotation only runs while this key is held — lets you move freely when not held. Stacks with Toggle Key (both must be active).')
    if gui.elements.use_hold_key:get() then
        gui.elements.hold_keybind:render('Hold Key', 'Press the key you want to hold to activate the rotation')
    end

    -- ---- Profiles (selector + rename/new/delete + cloud sharing) ----
    if gui.elements.profiles_tree:push('Profiles') then
        if profile_names and #profile_names > 0 then
            gui.elements.profile_combo:render('Profile', profile_names, 'Switch between saved profiles for this class. Settings update immediately.')
            -- input_text:render is wrapped in pcall via _safe_input_render
            -- (see the helper above) -- a host-side crash inside the widget
            -- otherwise takes the whole game down.
            _safe_input_render('profile_rename', 'Rename Profile', 'Enter a new name for the active profile')
            gui.elements.profile_rename_btn:render('Apply Rename', 'Save the new profile name from the field above.')
            gui.elements.new_profile:render('New Profile (copy current)', 'Create a new profile by copying all current settings')
            if #profile_names > 1 then
                gui.elements.delete_profile:render('Delete Current Profile', 'Permanently delete the active profile and switch to another')
            end
        end

        -- Cloud sharing (nested under Profiles)
        if gui.elements.cloud_tree:push('Cloud Sharing') then
            render_menu_header('Share your rotation profile or import one from the community.')

            if cloud_info and cloud_info.code then
                -- Profile has already been shared — show code and update button
                render_menu_header(string.format(
                    'Shared as: "%s"  |  Code: %s',
                    tostring(cloud_info.display_name or ''),
                    tostring(cloud_info.code)
                ))
                gui.elements.cloud_share_btn:render(
                    'Update Cloud Profile',
                    'Re-upload the current settings to the cloud — overwrites your previous share.'
                )
            else
                -- Not shared yet — show name input + share button (separate)
                _safe_input_render('cloud_share_name', 'Display Name', 'Name shown in the cloud listing')
                gui.elements.cloud_share_new_btn:render(
                    'Share Profile',
                    'Upload this profile to the cloud (leaves name blank to use the local profile name).'
                )
            end

            -- Manual refresh from server.  The auto-load on script start
            -- reads only the on-disk cache (no curl/CMD console flash);
            -- this button is the only path that hits the server, so the
            -- cost is always tied to a user-visible action.
            gui.elements.cloud_refresh_btn:render(
                'Refresh from Server',
                'Pull the latest cloud listing for your class.  Required to see profiles other players have shared since the last refresh; cached entries stay visible if the server is unreachable.')

            -- Picker.  Labels + details are pre-built in main.lua so this
            -- render path stays O(1) per frame.
            if cloud_browse and type(cloud_browse.profiles) == 'table' then
                local profs   = cloud_browse.profiles
                local labels  = cloud_browse.labels  or {}
                local details = cloud_browse.details or {}
                if #profs == 0 then
                    render_menu_header('No shared profiles for this class yet — click Refresh from Server, or be the first to share one.')
                else
                    render_menu_header(string.format(
                        '%d profile(s) for %s',
                        #profs, tostring(cloud_browse.class or '?')))
                    gui.elements.cloud_browse_combo:render(
                        'Cloud Profile', labels,
                        'Pick a profile to import.  Click Refresh from Server above to pull the latest listing.')
                    -- Detail line for the highlighted entry (full code +
                    -- updated_at).  Combo only shows "name (code)" so the
                    -- entry can stay narrow even with long names; the
                    -- detail line gives the rest.
                    local sel = 0
                    if gui.elements.cloud_browse_combo.get then
                        local s = gui.elements.cloud_browse_combo:get()
                        if type(s) == 'number' then sel = s end
                    end
                    if sel < 0 then sel = 0 end
                    if sel >= #profs then sel = #profs - 1 end
                    local detail = details[sel + 1]
                    if detail then render_menu_header(detail) end
                    gui.elements.cloud_import_selected_btn:render(
                        'Import Selected',
                        'Download the highlighted profile and save it as a new local profile.')
                end
            end

            _safe_input_render(
                'cloud_import_code',
                'Share Code',
                'Paste a share code from a friend (useful for cross-class profiles).  For your own class, pick one from the Cloud Profile dropdown above.'
            )
            gui.elements.cloud_import_code_btn:render(
                'Import Profile',
                'Download and apply the profile with the share code from the field above.'
            )

            gui.elements.cloud_tree:pop()
        end

        gui.elements.profiles_tree:pop()
    end

    if gui.elements.global_tree:push('Global Settings') then
        gui.elements.scan_range:render('Scan Range (yds)', 'How far to scan for enemies', 1)
        gui.elements.anim_delay:render('Animation Delay (s)', 'Global animation delay after each cast', 2)
        gui.elements.global_min_enemies:render('Global Min Enemies', 'Minimum enemies required globally before any spell fires (0 = off). Per-spell min is also respected — whichever is higher wins.', 1)
        gui.elements.respect_orb:render('Respect Orbwalker', 'Only run the rotation while the orbwalker is in clear/pvp mode (or while Hold-to-Cast is held). Recommended ON to avoid fighting your orbwalker.')
        gui.elements.allow_movement:render('Allow Movement', 'Let the rotation move the character into melee range (pathfinder.request_move). Turn OFF if you want the orbwalker to handle ALL movement.')
        gui.elements.los_enabled:render('Line-of-Sight Filter',
            'Skip targets blocked by walls or on unreachable cliffs. '
            .. 'Uses a wall-collision check and a height-difference check. '
            .. 'Enable if the rotation spins on enemies through walls or across ledges.')
        if gui.elements.los_enabled:get() then
            gui.elements.los_height_max:render('Max Height Diff (cliff)',
                'Enemies more than this many units above or below the player are ignored. '
                .. '1.5 is a safe default — raise it only if your build legitimately attacks uphill.', 1)
        end
        gui.elements.external_target_override:render('External Target Override',
            'When ON, UR ONLY casts at the target an external plugin '
            .. 'has picked (_G.EXTERNAL_ROTATION_TARGET).  No fallback '
            .. 'to closest-mob selection.  Hold fire when the external '
            .. 'plugin clears the target.  Turn ON when running an '
            .. 'external bot (WarMachine, Gem Farmer, etc.) so combat '
            .. 'follows the plugin\'s priority model (pathing > '
            .. 'objectives > only-fight-when-interfering) instead of '
            .. 'auto-engaging every mob within scan range.')
        gui.elements.debug_mode:render('Debug Mode', 'Print cast info to console')

        gui.elements.overlay_enabled:render('Overlay', 'Show/hide the on-screen overlay')
        if gui.elements.overlay_enabled:get() then
            gui.elements.overlay_x:render('Overlay X', 'Overlay left position (px)', 1)
            gui.elements.overlay_y:render('Overlay Y', 'Overlay top position (px)', 1)
            gui.elements.overlay_show_buffs:render('Show Active Buff List', 'Show active buffs in the overlay')
        end

        -- Hold Location
        if gui.elements.hold_location_tree:push('Hold Location') then
            render_menu_header('Pin the character to a fixed point. Enemies outside the radius are ignored; the character auto-returns if it drifts out.')
            gui.elements.hold_location_enabled:render('Enable Hold Location', 'Lock combat to a radius around a fixed point in the world — position is captured automatically on enable')
            gui.elements.use_hold_loc_keybind:render('Use Keybind', 'Toggle Hold Location on/off with a key (also captures position on each enable)')
            if gui.elements.use_hold_loc_keybind:get() then
                gui.elements.hold_loc_keybind:render('Hold Location Key', 'Key to toggle Hold Location on/off')
            end
            gui.elements.hold_location_range:render('Hold Radius (yds)', 'Enemies outside this circle are ignored; player returns here if pushed out', 1)
            gui.elements.hold_location_set_btn:render('Set Position Here', 'Re-pin to the current player position without toggling the feature')
            if type(hold_info) == 'table' and hold_info.label then
                render_menu_header(hold_info.label)
            end
            gui.elements.hold_location_tree:pop()
        end

        -- Buff dropdown filters
        if gui.elements.buff_filter_tree:push('Buff Dropdown Filters') then
            render_menu_header('Skill buffs are always shown. Toggle extra categories below. Tip: use the "Search Buffs" field inside each spell\'s settings to find any buff by name across all categories without changing these filters.')
            gui.elements.bf_dump_buffs:render('Print Active Buffs to Console',
                'Dump every buff currently on the player (hash + name + stacks).  Use to verify a spell\'s Buff Condition hash matches what the game is reporting -- the most common cause of "Missing-mode keeps spamming while my buff is up" is picking the wrong dropdown entry (skill vs buff effect have different hashes).')
            gui.elements.bf_paragon:render('Show Paragon',         'Include paragon board buffs')
            gui.elements.bf_talent:render('Show Talent',           'Include talent tree buffs')
            gui.elements.bf_item:render('Show Item / Gear',        'Include gear slot and item affix buffs')
            gui.elements.bf_npc:render('Show NPC / Actor',         'Include NPC and actor buffs')
            gui.elements.bf_bsk:render('Show BSK / Horde',         'Include Infernal Horde (BSK) buffs')
            gui.elements.bf_dungeon:render('Show Dungeon Affix',   'Include dungeon affix buffs')
            gui.elements.bf_passive:render('Show Passives',        'Include passive effect buffs')
            gui.elements.bf_internal:render('Show Internal/Other', 'Include unnamed, hash-only, and engine-internal buffs')
            gui.elements.buff_filter_tree:pop()
        end

        gui.elements.global_tree:pop()
    end

    -- ---- Virtual Evade Spell ----
    if gui.elements.evade_tree:push('Evade Spell') then
        render_menu_header('Virtual spell that presses a key (spacebar by default). Participates in the rotation like any other spell.')
        spell_config.render(gui.VIRTUAL_EVADE_ID, 'Evade', equipped_ids, all_known_ids)
        gui.elements.evade_tree:pop()
    end

    local equipped_set = {}
    for _, id in ipairs(equipped_ids) do
        if id and id > 1 then equipped_set[id] = true end
    end

    if gui.elements.equipped_tree:push('Equipped Spells') then
        render_menu_header('These spells are currently on your skill bar.')
        local any = false
        for _, spell_id in ipairs(equipped_ids) do
            if spell_id and spell_id > 1 then
                any = true
                local name = _pretty_spell_name(get_name_for_spell(spell_id)) or ('Spell ' .. spell_id)
                local spell_tree = _get_spell_tree(spell_id)
                if spell_tree:push(name) then
                    spell_config.render(spell_id, name, equipped_ids, all_known_ids)
                    spell_tree:pop()
                end
            end
        end
        if not any then
            render_menu_header('No spells detected on skill bar.')
        end
        gui.elements.equipped_tree:pop()
    end

    if all_known_ids and #all_known_ids > 0 then
        if gui.elements.inactive_tree:push('Other Known Spells') then
            render_menu_header('Spells detected previously but not currently on bar.')
            for _, spell_id in ipairs(all_known_ids) do
                if not equipped_set[spell_id] then
                    local name = _pretty_spell_name(get_name_for_spell(spell_id)) or ('Spell ' .. spell_id)
                    local spell_tree = _get_spell_tree(spell_id)
                    if spell_tree:push(name) then
                        spell_config.render(spell_id, name, equipped_ids, all_known_ids)
                        spell_tree:pop()
                    end
                end
            end
            gui.elements.inactive_tree:pop()
        end
    end

    gui.elements.main_tree:pop()
end

return gui
