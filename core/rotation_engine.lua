local spell_config   = require 'core.spell_config'
local spell_tracker  = require 'core.spell_tracker'
local target_selector = require 'core.target_selector'
local buff_provider   = require 'core.buff_provider'
local logger          = require 'core.logger'

local rotation_engine = {}

local GLOBAL_GCD     = 0.05   -- minimal delay between any two casts
local _gcd_until     = 0.0
local _scan_range    = 16.0
local _move_until    = 0.0
local _los_opts      = nil    -- set each tick from settings; used by _get_aim_target

-- Chain boosts: [spell_id] = { priority_boost, expires_at }
-- After a spell with use_chain fires, the target spell's effective priority is temporarily lowered
local _chain_boosts = {}   -- keyed by target spell_id (number)

-- Channeled spells: [spell_id] = vk_code currently held down
local _channeled_held = {}

-- Debug: per-spell last-seen result of the buff-condition gate.  When
-- debug_mode is on, every transition is console-printed so users can see
-- whether the gate is firing.  Most "spell spams in Missing mode while
-- the buff is up" reports are buff_hash mismatches (user picked the
-- skill hash instead of the buff-effect hash) -- this surfaces that
-- without the user having to open the debug log file.
local _last_buff_has = {}

-- Channeled spells: [spell_id] = monotonic time of last re-engage attempt.
-- D4 can drop a channel for many reasons (CC, animation lock, dash, item
-- pickup) while our OS-level key is still held -- without periodic
-- re-presses the channel never resumes after such an interrupt.  The
-- channeled pipeline checks get_active_spell_id() each tick and re-presses
-- the key when the in-game channel doesn't match what we expect, throttled
-- via this table so a transient mismatch can't burn the host's input queue.
local _channeled_repress_t = {}
local CHANNELED_REPRESS_THROTTLE = 0.20  -- seconds between re-press attempts

-- Co-existence with the host's auto-dodge plugin (the `evade` global --
-- HordeDev / EvadeRevamped / Paladin-style dodgers all hook into it).
--
-- The conflict that motivated this debounce: UR's "Virtual Evade" sends
-- a keypress (typically Space) which D4 routes to the player's bound
-- evade.  The host's auto-dodge calls cast_spell.position(337031, ...)
-- with a safe target.  Without coordination both can fire within one
-- frame -- the player dashes once for UR, then re-dashes for the host,
-- in opposite directions, looking like a stutter.
--
-- Bi-directional fix:
--   * Outbound: when WE fire UR's virtual evade, call evade.set_pause()
--     so the host won't fire its auto-dodge immediately on top of us.
--   * Inbound: track the last time we observed is_dangerous_position;
--     skip UR's virtual evade for HOST_DODGE_DEFERENCE_S after that to
--     give the host's auto-dodge a clean window without UR piling on.
--
-- The deference window also covers the post-dodge safe-position frame,
-- where can_act() unblocks (no longer dangerous) but the host's dash
-- animation is still resolving.
local HOST_DODGE_DEFERENCE_S = 0.6
local _last_danger_t         = -math.huge

-- Pulse helper -- called once per tick by `tick()` so the gate below
-- has the most-recent observation.  Safe-no-op when the `evade` global
-- isn't loaded (no auto-dodge plugin installed).
local function _refresh_danger_observation(player_pos)
    if not evade or not evade.is_dangerous_position or not player_pos then return end
    local ok, danger = pcall(evade.is_dangerous_position, player_pos)
    if ok and danger then
        _last_danger_t = get_time_since_inject() or 0
    end
end

local function _host_recently_dodged()
    return (get_time_since_inject() or 0) - _last_danger_t < HOST_DODGE_DEFERENCE_S
end

-- Notify host to pause auto-dodge for the next casting window.  Called
-- right after UR's virtual evade fires so the host doesn't fire ITS
-- evade on top of ours.  No-op when the host plugin isn't loaded.
local function _yield_to_us(seconds)
    if evade and evade.set_pause then
        pcall(evade.set_pause, seconds or 0.4)
    end
end

local function _release_all_channeled()
    for spell_id, vk in pairs(_channeled_held) do
        pcall(function() utility.send_key_up(vk) end)
        logger.log('channeled: KEY UP (release) spell=' .. tostring(spell_id))
    end
    _channeled_held = {}
    _channeled_repress_t = {}
end

local function _player_has_buff(required_hash, min_stacks)
    if not required_hash or required_hash == 0 then return true end
    min_stacks = min_stacks or 1

    local player = get_local_player()
    if not player or type(player.get_buffs) ~= 'function' then return false end

    -- pcall so a buff disappearing mid-call (or any host-side fault in
    -- get_buffs) can't take down the whole rotation tick.
    local ok, buffs = pcall(player.get_buffs, player)
    if not ok or type(buffs) ~= 'table' then return false end

    for _, b in ipairs(buffs) do
        if b then
            local h = nil

            if type(b.get_name_hash) == 'function' then
                h = b:get_name_hash()
            elseif type(b.name_hash) == 'function' then
                h = b:name_hash()
            elseif type(b.name_hash) == 'number' then
                h = b.name_hash
            end

            if h == required_hash then
                local stacks = 0
                if type(b.get_stacks) == 'function' then
                    stacks = b:get_stacks()
                elseif type(b.stacks) == 'number' then
                    stacks = b.stacks
                end
                -- Non-stacking buffs (Rallying Cry, Challenging Shout,
                -- most warcries / shouts in D4) report stacks=0 from the
                -- host's API even when active -- the buff is present-or-
                -- absent with no stack counter.  Without this clamp the
                -- min_stacks=1 default check (stacks >= 1) would always
                -- fail for those, making "Active" mode never fire and
                -- "Missing" mode always fire even when the buff is on.
                -- Presence in the buff list is enough to count as one
                -- effective stack; real stacking buffs still report
                -- their actual count (>= 1) and pass through unchanged.
                if stacks < 1 then stacks = 1 end
                return stacks >= min_stacks
            end
        end
    end

    return false
end

-- Evaluate the full buff condition for a spell config.
-- Returns true when the spell should be allowed to cast (condition passes).
-- Handles Single (op=0), AND (op=1), and OR (op=2) modes.
local function _eval_buff_condition(cfg)
    local op = cfg.buff_operator or 0

    -- Per-slot evaluator: true when the slot's has/missing check passes.
    local function eval_slot(hash, mode, stacks)
        if not hash or hash == 0 then return true end  -- unset slot is a no-op (passes)
        local has = _player_has_buff(hash, stacks or 1)
        return (mode == 0) and has or (not has)
    end

    if op == 0 then
        return eval_slot(cfg.buff_hash, cfg.buff_mode or 0, cfg.buff_stacks)
    end
    local slot1 = eval_slot(cfg.buff_hash, cfg.buff_mode or 0, cfg.buff_stacks)
    local slot2 = true
    if cfg.buff_extra and cfg.buff_extra[1] then
        local s = cfg.buff_extra[1]
        slot2 = eval_slot(s.hash, s.mode or 0, s.stacks)
    end
    if op == 1 then return slot1 and slot2 end  -- AND: both must pass
    if op == 2 then return slot1 or  slot2 end  -- OR: either must pass
    return true
end

-- Returns current primary resource as a percentage (0-100), or nil if unavailable / unreliable
local function _get_resource_pct()
    local lp = get_local_player()
    if not lp then return nil end

    local cur, max_r
    if type(lp.get_primary_resource_current) == 'function' then
        local ok, v = pcall(lp.get_primary_resource_current, lp)
        if ok and type(v) == 'number' then cur = v end
    end
    if type(lp.get_primary_resource_max) == 'function' then
        local ok, v = pcall(lp.get_primary_resource_max, lp)
        if ok and type(v) == 'number' then max_r = v end
    end

    -- If either is 0 / nil, we can't compute a reliable percentage — skip gracefully
    if not cur or not max_r or max_r <= 0 then return nil end
    if cur <= 0 then return nil end  -- Rogue energy / unreported resource

    return (cur / max_r) * 100.0
end

-- Secondary resource raw count. Prefers get_secondary_resource_current; falls back to
-- get_rogue_combo_points for older classes. Returns nil if no API is available.
local function _get_secondary_count()
    local lp = get_local_player()
    if not lp then return nil end
    if type(lp.get_secondary_resource_current) == 'function' then
        local ok, v = pcall(lp.get_secondary_resource_current, lp)
        if ok and type(v) == 'number' then return v end
    end
    if type(lp.get_rogue_combo_points) == 'function' then
        local ok, v = pcall(lp.get_rogue_combo_points, lp)
        if ok and type(v) == 'number' then return v end
    end
    return nil
end

-- Secondary resource as a percentage (0-100). Uses get_secondary_resource_ratio when
-- available; otherwise derives from current/max. Returns nil if unavailable.
local function _get_secondary_pct()
    local lp = get_local_player()
    if not lp then return nil end
    if type(lp.get_secondary_resource_ratio) == 'function' then
        local ok, v = pcall(lp.get_secondary_resource_ratio, lp)
        if ok and type(v) == 'number' and v >= 0 then return v * 100.0 end
    end
    -- Fallback: derive from current / max
    local cur, max_r
    if type(lp.get_secondary_resource_current) == 'function' then
        local ok, v = pcall(lp.get_secondary_resource_current, lp)
        if ok and type(v) == 'number' then cur = v end
    end
    if type(lp.get_secondary_resource_max) == 'function' then
        local ok, v = pcall(lp.get_secondary_resource_max, lp)
        if ok and type(v) == 'number' and v > 0 then max_r = v end
    end
    if cur and max_r then return (cur / max_r) * 100.0 end
    return nil
end

local function _check_resource_condition(cfg)
    if not cfg.use_resource then return true end
    if cfg.resource_override then return true end  -- bypass: assume resource is full

    local rtype = tonumber(cfg.resource_type) or 0   -- 0=Primary %, 1=Secondary count
    local threshold = tonumber(cfg.resource_pct) or 50
    local mode = tonumber(cfg.resource_mode) or 1    -- 0=Below, 1=Above

    if rtype == 1 then
        local count = _get_secondary_count()
        if count == nil then return true end  -- API unavailable, skip gracefully
        if mode == 0 then return count < threshold
        else            return count >= threshold
        end
    end

    if rtype == 2 then
        local pct2 = _get_secondary_pct()
        if pct2 == nil then return true end
        if mode == 0 then return pct2 < threshold
        else            return pct2 >= threshold
        end
    end

    local pct = _get_resource_pct()
    if pct == nil then return true end  -- API returned 0 / unreliable, skip check gracefully

    if mode == 0 then
        return pct < threshold
    else
        return pct >= threshold
    end
end

local function _check_health_condition(cfg)
    if not cfg.use_health then return true end

    local lp = get_local_player()
    if not lp then return true end

    local cur, max_h
    if type(lp.get_current_health) == 'function' then
        local ok, v = pcall(lp.get_current_health, lp)
        if ok and type(v) == 'number' and v > 0 then cur = v end
    end
    if type(lp.get_max_health) == 'function' then
        local ok, v = pcall(lp.get_max_health, lp)
        if ok and type(v) == 'number' and v > 0 then max_h = v end
    end

    if not cur or not max_h then return true end

    local pct       = (cur / max_h) * 100.0
    local threshold = tonumber(cfg.health_pct) or 50
    local mode      = tonumber(cfg.health_mode) or 0  -- 0=Below, 1=Above

    if mode == 0 then return pct < threshold
    else              return pct >= threshold
    end
end

-- Apply a chain boost after casting spell_id
local function _apply_chain(cfg)
    if not cfg.use_chain then return end
    local target_id = tonumber(cfg.chain_target_id) or 0
    if target_id == 0 then return end

    local boost    = tonumber(cfg.chain_boost) or 3
    local duration = tonumber(cfg.chain_duration) or 3.0
    local expires  = get_time_since_inject() + duration

    local existing = _chain_boosts[target_id]
    if not existing or existing.expires < get_time_since_inject() or boost > (existing.boost or 0) then
        _chain_boosts[target_id] = { boost = boost, expires = expires }
    end
end

-- Cast counters for Stack Priority Mode: [spell_id] = { count, last_cast }
local _stack_pri_counts = {}

-- Read current stack count for a buff by name_hash from the player's buff list
local function _get_buff_stacks(buff_hash)
    if not buff_hash or buff_hash == 0 then return 0 end
    local player = get_local_player()
    if not player or type(player.get_buffs) ~= 'function' then return 0 end
    -- pcall so a buff disappearing mid-call can't crash the tick.
    local ok, buffs = pcall(player.get_buffs, player)
    if not ok or type(buffs) ~= 'table' then return 0 end
    for _, b in ipairs(buffs) do
        if b then
            local h = nil
            if type(b.name_hash) == 'number' then
                h = b.name_hash
            elseif type(b.get_name_hash) == 'function' then
                h = b:get_name_hash()
            end
            if h == buff_hash then
                if type(b.stacks) == 'number' then return b.stacks end
                if type(b.get_stacks) == 'function' then return b:get_stacks() end
                return 0
            end
        end
    end
    return 0
end

-- Check if the spell is in its "build phase" for Stack Priority Mode.
-- Returns true when stacks/casts are below the target.
local function _is_in_build_phase(spell_id, cfg)
    if not cfg or not cfg.use_stack_pri then return false end
    local target = cfg.stack_pri_count or 4

    if cfg.stack_pri_use_buff and (cfg.stack_pri_buff_hash or 0) ~= 0 then
        -- Buff-based: read real stacks
        local stacks = _get_buff_stacks(cfg.stack_pri_buff_hash)
        return stacks < target
    else
        -- Cast-counter based
        local now = get_time_since_inject()
        local sc = _stack_pri_counts[spell_id]
        if sc and sc.last_cast > 0 and (now - sc.last_cast) > (cfg.stack_pri_reset or 4.0) then
            sc.count = 0
        end
        local count = sc and sc.count or 0
        return count < target
    end
end

-- Get the effective priority of a spell (chain boosts + stack-based priority override)
-- cfg is optional; if present, stack priority mode is evaluated
local function _effective_priority(spell_id, base_priority, cfg)
    local now = get_time_since_inject()
    local result = base_priority

    -- Stack Priority Mode: use override priority during build phase
    if cfg and cfg.use_stack_pri then
        local building = _is_in_build_phase(spell_id, cfg)
        if building then
            result = cfg.stack_pri_below_pri or base_priority
            if cfg.stack_pri_use_buff and (cfg.stack_pri_buff_hash or 0) ~= 0 then
                local stacks = _get_buff_stacks(cfg.stack_pri_buff_hash)
                logger.log(string.format('stack_pri: spell=%s stacks=%d/%d BUILD PHASE (buff)',
                    tostring(spell_id), stacks, cfg.stack_pri_count or 4))
            end
        end
    end

    -- Chain boost: reduce priority number so the spell fires sooner
    local cb = _chain_boosts[spell_id]
    if cb and cb.expires > now then
        result = math.max(1, result - cb.boost)
    end

    return result
end

local function _record_stack_pri_cast(spell_id, cfg)
    if not cfg or not cfg.use_stack_pri then return end
    local sc = _stack_pri_counts[spell_id]
    if not sc then
        sc = { count = 0, last_cast = 0 }
        _stack_pri_counts[spell_id] = sc
    end
    sc.count     = sc.count + 1
    sc.last_cast = get_time_since_inject()
end

local function _channeled_conditions_met(entry, targets, player_pos, settings, held)
    local cfg = entry.cfg
    local spell_id = entry.spell_id

    -- Travel mode and self_cast both bypass the enemy-presence gate so the
    -- channel keeps running while the player is just moving around.
    -- Resource / health / buff / min-enemy gates further down still apply,
    -- so the channel pauses if the user runs out of fury, etc.
    if not cfg.self_cast and not cfg.use_while_traveling then
        if not targets.is_valid or (targets.enemy_count or 0) <= 0 then return false end
        if cfg.boss_only  and not targets.has_boss  then return false end
        if cfg.elite_only and not targets.has_elite and not targets.has_boss and not targets.has_champion then return false end
    end

    local ok1 = pcall(function()
        -- Skip is_spell_ready while already channeling; the spell reports
        -- "not ready" during its own channel, which would cause stutter.
        if not held then
            if not utility.is_spell_ready(spell_id) then error('not ready') end
        end
        if not utility.is_spell_affordable(spell_id) then error('not affordable') end
    end)
    if not ok1 then return false end

    if not _check_resource_condition(cfg) then return false end
    if not _check_health_condition(cfg)   then return false end

    if cfg.require_buff and not _eval_buff_condition(cfg) then return false end

    local effective_min = math.max(cfg.min_enemies or 0, settings.global_min_enemies or 0)
    if effective_min > 0 and not (targets.has_boss or targets.has_champion) then
        local nearby = target_selector.count_near(targets, player_pos, cfg.aoe_range or 6.0)
        if nearby < effective_min then return false end
    end

    return true
end

local function can_act()
    local lp = get_local_player()
    if not lp then logger.log('can_act: NO local player'); return false end
    if lp:is_dead() then logger.log('can_act: player is DEAD'); return false end

    -- Don't cast anything in town / safe zones
    local town_ok, in_town = pcall(function()
        return lp:get_attribute(attributes.PLAYER_IN_TOWN_LEVEL_AREA)
    end)
    if town_ok and in_town and in_town > 0 then logger.log('can_act: IN TOWN'); return false end

    local pos = lp:get_position()
    if evade and evade.is_dangerous_position and evade.is_dangerous_position(pos) then
        logger.log('can_act: dangerous position (evade)')
        return false
    end

    local active = lp:get_active_spell_id()
    local blocked = { [186139]=true, [197833]=true, [211568]=true }
    if active and blocked[active] then logger.log('can_act: blocked spell active ' .. tostring(active)); return false end

    local ok, mount_val = pcall(function()
        return lp:get_attribute(attributes.CURRENT_MOUNT)
    end)
    if ok and mount_val and mount_val < 0 then logger.log('can_act: mounted'); return false end

    return true
end

-- Convert a world vec3 position to screen vec2 coordinates.
-- D4 world uses x/y as horizontal plane; vec2:coordinate_to_screen() does the projection.
-- coordinate_to_screen() may expose its result fields as getter functions (like vec3 does),
-- so we use the same function-vs-field defensive access on both input and output.
local function _world_to_screen(world_pos)
    if not world_pos then return nil end
    local ok, sx, sy = pcall(function()
        local wx = type(world_pos.x) == 'function' and world_pos:x() or world_pos.x
        local wy = type(world_pos.y) == 'function' and world_pos:y() or world_pos.y
        local v = vec2:new(wx, wy)
        local s = v:coordinate_to_screen()
        if not s then return nil, nil end
        local rx = type(s.x) == 'function' and s:x() or s.x
        local ry = type(s.y) == 'function' and s:y() or s.y
        return rx, ry
    end)
    if ok and type(sx) == 'number' and type(sy) == 'number' then
        return math.floor(sx), math.floor(sy)
    end
    return nil
end

-- Get aim target world position based on aim_mode:
--   0 = no aim (nil)
--   1 = towards closest enemy
--   2 = orbwalker direction (clear/pvp → toward enemy, flee → away)
local function _get_aim_target(aim_mode, player_pos, scan_range)
    if aim_mode == 0 then logger.log('_get_aim_target: No Aim, skipping'); return nil end

    logger.log(string.format('_get_aim_target: aim_mode=%d scan_range=%s', aim_mode, tostring(scan_range)))
    local t = target_selector.get_targets(player_pos, scan_range or 30, _los_opts)
    local enemy = t and t.closest
    if not enemy then logger.log('_get_aim_target: no enemy found'); return nil end

    local enemy_pos = nil
    pcall(function() enemy_pos = enemy:get_position() end)
    if not enemy_pos then logger.log('_get_aim_target: enemy has no position'); return nil end

    if aim_mode == 1 then
        logger.log('_get_aim_target: towards enemy')
        return enemy_pos, false
    elseif aim_mode == 2 then
        local orb_mode_val = 0
        pcall(function() orb_mode_val = orbwalker.get_orb_mode() end)
        logger.log(string.format('_get_aim_target: orbwalker mode=%d', orb_mode_val))
        if orb_mode_val == 4 then
            local flee_pos = nil
            pcall(function()
                flee_pos = enemy_pos:get_extended(player_pos, -15.0)
            end)
            logger.log('_get_aim_target: flee, aiming away')
            return flee_pos or nil, true
        else
            logger.log('_get_aim_target: orbwalker non-flee, towards enemy')
            return enemy_pos, false
        end
    end

    return nil
end

-- Key-press cast: press a single key (evade / spacebar style)
-- aim_mode: 0=no aim, 1=towards enemy, 2=orbwalker direction
-- suppress_cursor: when true, never move the mouse cursor (for hold-cast manual control)
local function try_key_cast(spell_id, vk_code, is_virtual, aim_mode, player_pos, scan_range, suppress_cursor)
    logger.log(string.format('try_key_cast: spell=%s vk=0x%02X virtual=%s aim=%d suppress=%s',
        tostring(spell_id), vk_code or 0x20, tostring(is_virtual), aim_mode or 0, tostring(suppress_cursor)))

    if not is_virtual then
        if not utility.is_spell_ready(spell_id) then logger.log('try_key_cast: not ready'); return false end
        if not utility.is_spell_affordable(spell_id) then logger.log('try_key_cast: not affordable'); return false end
    end

    vk_code   = vk_code or 0x20
    aim_mode  = aim_mode or 0

    if suppress_cursor then
        logger.log('try_key_cast: cursor suppressed, pressing key only')
        utility.send_key_press(vk_code)
        return true
    end

    if aim_mode ~= 0 and player_pos then
        local aim_pos = _get_aim_target(aim_mode, player_pos, scan_range)
        if aim_pos then
            local sx, sy = _world_to_screen(aim_pos)
            if sx and sy then
                logger.log(string.format('try_key_cast: cursor -> (%d, %d)', sx, sy))
                local cur = get_cursor_position()
                local cur_sx, cur_sy = _world_to_screen(cur)
                utility.send_mouse_move(sx, sy)
                utility.send_key_press(vk_code)
                if cur_sx and cur_sy then
                    utility.send_mouse_move(cur_sx, cur_sy)
                end
                logger.log('try_key_cast: SUCCESS (aimed)')
                return true
            else
                logger.log('try_key_cast: world_to_screen failed')
                console.print('[UniversalRota] Evade aim: world_to_screen failed — cursor not moved. Enable Debug Mode for more info.')
            end
        end
    end

    -- Fallback: just press the key with no cursor adjustment
    logger.log('try_key_cast: pressing key (no aim)')
    utility.send_key_press(vk_code)
    return true
end

-- Force Stand Still + Skill Key: hold modifier, press skill slot key, release modifier
-- Moves cursor to target_pos before casting so the skill fires at the correct target,
-- then restores the cursor to its original position.
-- Slot 0=key '1' (0x31), slot 1=key '2' (0x32), etc.
local function try_force_standstill_cast(spell_id, hold_key, slot, is_virtual, target_pos, suppress_cursor)
    if not is_virtual then
        if not utility.is_spell_ready(spell_id) then return false end
        if not utility.is_spell_affordable(spell_id) then return false end
    end

    hold_key = hold_key or 0x10  -- default: Shift
    slot = slot or 0
    local slot_key = 0x31 + slot  -- 0x31='1', 0x32='2', etc.

    -- Move cursor to the target position so FSS fires in the right direction
    local cur_sx, cur_sy = nil, nil
    if target_pos and not suppress_cursor then
        local sx, sy = _world_to_screen(target_pos)
        if sx and sy then
            local cur = get_cursor_position()
            cur_sx, cur_sy = _world_to_screen(cur)
            utility.send_mouse_move(sx, sy)
        end
    end

    utility.send_key_down(hold_key)
    utility.send_key_press(slot_key)
    utility.send_key_up(hold_key)

    -- Restore cursor
    if cur_sx and cur_sy then
        utility.send_mouse_move(cur_sx, cur_sy)
    end
    return true
end

-- Cursor-targeted cast: cast at the current mouse cursor world position
local function try_cursor_cast(spell_id, anim_delay)
    anim_delay = anim_delay or 0.05

    local ok_r, ready = pcall(utility.is_spell_ready, spell_id)
    if not ok_r or not ready then return false end
    local ok_a, affordable = pcall(utility.is_spell_affordable, spell_id)
    if not ok_a or not affordable then return false end

    local cursor_pos = get_cursor_position()
    if not cursor_pos then return false end

    local ok, v = pcall(cast_spell.position, spell_id, cursor_pos, anim_delay)
    return ok and v or false
end

local function try_cast(spell_id, target, player_pos, anim_delay, self_cast)
    anim_delay = anim_delay or 0.05

    local ok_r, ready = pcall(utility.is_spell_ready, spell_id)
    if not ok_r or not ready then return false end
    local ok_a, affordable = pcall(utility.is_spell_affordable, spell_id)
    if not ok_a or not affordable then return false end

    -- Self-cast: cast on player's position, no target needed
    if self_cast then
        local ok, v = pcall(cast_spell.self, spell_id, anim_delay)
        if ok and v then return true end
        ok, v = pcall(cast_spell.position, spell_id, player_pos, anim_delay)
        return ok and v or false
    end

    local target_pos = player_pos
    if target then
        local ok_p, tp = pcall(function() return target:get_position() end)
        if ok_p and tp then target_pos = tp end
    end

    local ok, v = pcall(cast_spell.position, spell_id, target_pos, anim_delay)
    if ok and v then return true end

    if target then
        ok, v = pcall(cast_spell.target, target, spell_id, anim_delay)
        if ok and v then return true end
    end

    ok, v = pcall(cast_spell.self, spell_id, anim_delay)
    return ok and v or false
end


local function try_move_towards(target, player_pos, desired_range)
    if not (pathfinder and type(pathfinder.request_move) == 'function') then return false end
    if not target or not player_pos then return false end
    local now = get_time_since_inject()
    if now < _move_until then return false end

    local tpos = nil
    pcall(function() tpos = target:get_position() end)
    if not tpos then return false end

    local stop = tonumber(desired_range) or 2.0
    if stop < 1.5 then stop = 1.5 end

    local move_pos = tpos
    if tpos.get_extended then
        local ok, mp = pcall(function() return tpos:get_extended(player_pos, -stop) end)
        if ok and mp then move_pos = mp end
    end

    local ok = pathfinder.request_move(move_pos)
    if ok then _move_until = now + 0.35 end
    return ok and true or false
end

function rotation_engine.tick(equipped_ids, settings)
    if not can_act() then
        _release_all_channeled()
        -- Even though we're not casting, refresh the danger observation
        -- so the post-dodge deference window is anchored at the LAST
        -- dangerous frame -- not the frame the rotation resumed.
        local lp = get_local_player()
        if lp then _refresh_danger_observation(lp:get_position()) end
        return false
    end

    -- Compute targets early so the channeled pass (which runs every frame,
    -- GCD-independent) has the data it needs.
    local lp         = get_local_player()
    local player_pos = lp:get_position()
    local range      = settings.scan_range or _scan_range

    -- Refresh the host-dodge observation once per tick so the
    -- virtual-evade gate below works on fresh data.
    _refresh_danger_observation(player_pos)

    -- Hold Location: scan enemies from the pinned point at the hold radius so
    -- only targets inside the hold circle are considered for targeting.
    local scan_center = player_pos
    local scan_r      = range
    if settings.hold_location_enabled and settings.hold_location_pos then
        scan_center = settings.hold_location_pos
        scan_r      = settings.hold_location_range or 15.0
    end
    _los_opts = settings.los_enabled and {
        los_enabled    = true,
        los_height_max = settings.los_height_max or 1.5,
    } or nil
    local targets = target_selector.get_targets(scan_center, scan_r, _los_opts)

    local spell_list = {}
    for _, spell_id in ipairs(equipped_ids) do
        if spell_id and spell_id > 1 then
            local cfg = spell_config.get(spell_id)
            if cfg.enabled then
                local name = get_name_for_spell(spell_id) or tostring(spell_id)
                local eff_pri = _effective_priority(spell_id, cfg.priority, cfg)
                table.insert(spell_list, {
                    spell_id = spell_id,
                    cfg      = cfg,
                    name     = name,
                    eff_pri  = eff_pri,
                    is_virtual = false,
                })
            end
        end
    end

    -- Inject virtual evade spell if enabled
    local evade_id = spell_config.VIRTUAL_EVADE_ID
    local evade_cfg = spell_config.get(evade_id)
    if evade_cfg.enabled then
        table.insert(spell_list, {
            spell_id = evade_id,
            cfg      = evade_cfg,
            name     = 'Evade',
            eff_pri  = _effective_priority(evade_id, evade_cfg.priority, evade_cfg),
            is_virtual = true,
        })
    end

    table.sort(spell_list, function(a, b)
        return a.eff_pri < b.eff_pri
    end)

    -- Channeled spell pass: runs every frame regardless of GCD.
    -- Holds / re-presses / releases the configured key based on conditions.
    -- Cursor behavior is fully driven by the spell's Aim Direction setting
    -- (No Aim / Towards Enemy / Orbwalker Direction); pre-1.0.25 the
    -- "Use While Traveling" flag also suppressed cursor warps, but that
    -- collapsed three valid configs into one.  Users who want manual /
    -- orbwalker travel pick Aim Direction = No Aim and the warp simply
    -- doesn't fire (orbwalker uses internal API calls, not the OS cursor,
    -- so it's unaffected either way).
    local function _channeled_aim(entry)
        local aim_mode = entry.cfg.evade_aim_mode or 0
        if aim_mode == 0 or not player_pos then return end
        local aim_pos = _get_aim_target(aim_mode, player_pos, settings and settings.scan_range or 16)
        if not aim_pos then return end
        local sx, sy = _world_to_screen(aim_pos)
        if sx and sy then utility.send_mouse_move(sx, sy) end
    end
    for _, entry in ipairs(spell_list) do
        if not entry.is_virtual and entry.cfg.is_channeled then
            local vk       = entry.cfg.evade_key or 0x20
            local held     = _channeled_held[entry.spell_id] ~= nil
            local cond_met = _channeled_conditions_met(entry, targets, player_pos, settings, held)
            if cond_met and not held then
                pcall(_channeled_aim, entry)
                pcall(function() utility.send_key_down(vk) end)
                _channeled_held[entry.spell_id] = vk
                _channeled_repress_t[entry.spell_id] = get_time_since_inject()
                logger.log('channeled: KEY DOWN spell=' .. tostring(entry.spell_id))
            elseif cond_met and held then
                pcall(_channeled_aim, entry)
                -- Re-engage if D4 dropped the channel (CC, animation lock,
                -- dash, item pickup, etc.) but our state still says held.
                -- Throttled so a transient active_spell_id mismatch during
                -- normal channel cycling doesn't spam keypress events.
                local now = get_time_since_inject()
                local last_repress = _channeled_repress_t[entry.spell_id] or 0
                if now - last_repress >= CHANNELED_REPRESS_THROTTLE then
                    local active_id = nil
                    pcall(function() active_id = lp:get_active_spell_id() end)
                    if active_id ~= entry.spell_id then
                        pcall(function() utility.send_key_up(vk) end)
                        pcall(function() utility.send_key_down(vk) end)
                        _channeled_repress_t[entry.spell_id] = now
                        logger.log(string.format(
                            'channeled: RE-ENGAGE spell=%s (active=%s)',
                            tostring(entry.spell_id), tostring(active_id)))
                    end
                end
            elseif not cond_met and held then
                pcall(function() utility.send_key_up(vk) end)
                _channeled_held[entry.spell_id] = nil
                _channeled_repress_t[entry.spell_id] = nil
                logger.log('channeled: KEY UP spell=' .. tostring(entry.spell_id))
            end
        end
    end

    -- GCD and orbwalker guard only the normal (non-channeled) cast loop below
    if get_time_since_inject() < _gcd_until then return false end

    -- Pre-1.0.25 we suppressed the entire normal cast loop while any
    -- channeled key was held, on the theory that API casts could interrupt
    -- the channel.  That broke a documented D4 mechanic: shouts, Iron
    -- Skin, Berserker's Wrath, and other instant abilities CAN fire
    -- mid-Whirlwind without ending the channel.  We now let the normal
    -- loop run -- the loop already skips entries with is_channeled=true
    -- (so the channeled spell itself isn't re-cast as an API call), and
    -- non-channeled cast paths don't release the OS-held key either.

    if settings and settings.respect_orb then
        local orb_mode_val = 0
        pcall(function() orb_mode_val = orbwalker.get_orb_mode() end)
        if orb_mode_val == 1 or orb_mode_val == 0 then
            logger.log('tick: orbwalker idle (mode=' .. tostring(orb_mode_val) .. '), yielding')
            return false
        end
    end

    for _, entry in ipairs(spell_list) do
        if entry.cfg.is_channeled then goto next_spell end  -- handled above
        local spell_id = entry.spell_id
        local cfg      = entry.cfg

        local is_virtual = entry.is_virtual

        local spell_name = is_virtual and 'Evade' or (entry.name or tostring(spell_id))
        logger.log(string.format('eval: %s (id=%s pri=%d eff=%d method=%d)',
            spell_name, tostring(spell_id), cfg.priority, entry.eff_pri, cfg.cast_method or 0))

        -- Virtual evade defers to the host's auto-dodge plugin (if any).
        -- When _last_danger_t is recent enough, skip our virtual evade
        -- so we don't pile a Spacebar press on top of the host's
        -- cast_spell.position dodge -- the user-reported "evade fights
        -- evade" stutter.  Real spells are unaffected.
        if is_virtual and _host_recently_dodged() then
            logger.log('  SKIP: virtual evade yielding to host auto-dodge')
            goto next_spell
        end

        -- Cross-plugin TRAVEL MODE: when an external plugin signals
        -- it's in a movement / interaction phase (no enemy in melee
        -- range), only self-cast spells fire.  Defensives, buffs, and
        -- player-AoE continue to cycle; offensive targeted spells are
        -- suppressed so we don't blow CDs and resources on stragglers
        -- we're walking past.  Contract is a single global; see e.g.
        -- WarMachine/core/rotation_bridge.lua.  No-op when no external
        -- plugin sets the flag.
        if _G.EXTERNAL_ROTATION_TRAVEL_MODE and not cfg.self_cast then
            logger.log('  SKIP: EXTERNAL_ROTATION_TRAVEL_MODE + non-self-cast')
            goto next_spell
        end

        -- Self-cast and cursor-targeted spells don't need enemies present
        if not cfg.self_cast and (cfg.target_mode or 0) ~= 5 then
            if not targets.is_valid or (targets.enemy_count or 0) <= 0 then
                logger.log('  SKIP: no enemies nearby')
                goto next_spell
            end
        end

        if not spell_tracker.is_off_cooldown(spell_id, cfg.cooldown, cfg.charges) then
            logger.log('  SKIP: on cooldown')
            goto next_spell
        end

        -- Virtual spells don't have real spell IDs, skip API checks
        if not is_virtual then
            local ok_r, is_ready = pcall(utility.is_spell_ready, spell_id)
            if not ok_r then
                if settings.debug then console.print(string.format('[UniversalRota] ERROR is_spell_ready(%s): %s', tostring(spell_id), tostring(is_ready))) end
                logger.log('  SKIP: is_spell_ready threw: ' .. tostring(is_ready)); goto next_spell
            end
            if not is_ready then logger.log('  SKIP: spell not ready'); goto next_spell end

            local ok_a, is_affordable = pcall(utility.is_spell_affordable, spell_id)
            if not ok_a then
                if settings.debug then console.print(string.format('[UniversalRota] ERROR is_spell_affordable(%s): %s', tostring(spell_id), tostring(is_affordable))) end
                logger.log('  SKIP: is_spell_affordable threw: ' .. tostring(is_affordable)); goto next_spell
            end
            if not is_affordable then logger.log('  SKIP: spell not affordable'); goto next_spell end
        end

        -- Resource condition check
        if not _check_resource_condition(cfg) then logger.log('  SKIP: resource condition'); goto next_spell end

        -- Health condition check
        if not _check_health_condition(cfg) then logger.log('  SKIP: health condition'); goto next_spell end

        if not cfg.self_cast then
            if cfg.boss_only and not targets.has_boss then logger.log('  SKIP: boss_only, no boss'); goto next_spell end
            if cfg.elite_only and not targets.has_elite
                and not targets.has_boss and not targets.has_champion
            then logger.log('  SKIP: elite_only, no elite/boss/champ'); goto next_spell end
        end

        if cfg.require_buff then
            local pass = _eval_buff_condition(cfg)
            if settings.debug then
                local op  = cfg.buff_operator or 0
                local has = _player_has_buff(cfg.buff_hash, cfg.buff_stacks)
                local op_names = { [0]='Single', [1]='AND', [2]='OR' }
                local dk  = tostring(spell_id) .. ':' .. tostring(cfg.buff_hash or 0) .. ':op' .. tostring(op)
                if _last_buff_has[dk] ~= (pass and 1 or 0) then
                    console.print(string.format(
                        '[UniversalRota] %s buff gate [%s]: slot1_hash=%s mode=%s stacks>=%d slot1_has=%s PASS=%s',
                        spell_name, op_names[op] or '?',
                        tostring(cfg.buff_hash or 0),
                        (cfg.buff_mode or 0) == 1 and 'Missing' or 'Active',
                        cfg.buff_stacks or 1,
                        tostring(has), tostring(pass)))
                    _last_buff_has[dk] = (pass and 1 or 0)
                end
            end
            if not pass then
                logger.log('  SKIP: buff condition not met')
                goto next_spell
            end
        end

        -- Min enemies check: use the higher of global minimum and per-spell minimum.
        -- Bosses and champions always bypass this — they are never ignored due to low mob count.
        local aoe_check = cfg.aoe_range or 6.0
        local effective_min = math.max(cfg.min_enemies or 0, settings.global_min_enemies or 0)
        if effective_min > 0 then
            if not (targets.has_boss or targets.has_champion) then
                local nearby = target_selector.count_near(targets, player_pos, aoe_check)
                if nearby < effective_min then
                    logger.log(string.format('  SKIP: min_enemies %d, have %d', effective_min, nearby))
                    goto next_spell
                end
            end
        end

        -- Determine cast method: 0=Normal, 1=Key Press, 2=Force Stand Still + Key
        local cast_method = cfg.cast_method or 0
        local METHOD_TAGS = { [0]='', [1]=' [KEY]', [2]=' [FSS]' }

        -- Dispatch a cast using the configured method.
        -- aim_pos: world position to move the cursor to before FSS cast (nil = leave cursor as-is)
        -- When stack_pri_targeted is enabled and the spell is still in its build phase,
        -- always use the normal targeted cast regardless of configured cast_method.
        local function dispatch_cast(fallback_fn, aim_pos)
            local in_build_phase = cfg.stack_pri_targeted and _is_in_build_phase(spell_id, cfg)
            local suppress_cursor = settings and settings.hold_active and true or false
            if in_build_phase then
                logger.log('  dispatch: FORCED normal cast (build phase)')
                return fallback_fn()
            elseif cast_method == 1 then
                logger.log('  dispatch: KEY PRESS')
                return try_key_cast(spell_id, cfg.evade_key, is_virtual, cfg.evade_aim_mode, player_pos, range, suppress_cursor)
            elseif cast_method == 2 then
                logger.log('  dispatch: FORCE STAND STILL')
                return try_force_standstill_cast(spell_id, cfg.force_hold_key, cfg.skill_slot, is_virtual, aim_pos, suppress_cursor)
            else
                logger.log('  dispatch: NORMAL cast')
                return fallback_fn()
            end
        end

        -- For self-cast, aim at player position
        if cfg.self_cast then
            logger.log('  path: SELF CAST')
            local dc_ok, did_cast = pcall(function()
                return dispatch_cast(function()
                    return try_cast(spell_id, nil, player_pos, settings.anim_delay or 0.05, true)
                end, player_pos)
            end)
            if not dc_ok then
                if settings.debug then console.print(string.format('[UniversalRota] ERROR casting %s (self): %s', spell_name, tostring(did_cast))) end
                logger.log('  cast error (self): ' .. tostring(did_cast))
                goto next_spell
            end
            if did_cast then
                logger.log(string.format('  CAST SUCCESS: %s (self)', spell_name))
                spell_tracker.record_cast(spell_id, cfg.charges)
                _apply_chain(cfg)
                _record_stack_pri_cast(spell_id, cfg)
                _gcd_until = get_time_since_inject() + GLOBAL_GCD
                if settings.debug then
                    console.print(string.format('[UniversalRota] Self-Cast: %s (id=%s pri=%d eff=%d%s)',
                        entry.name, tostring(spell_id), cfg.priority, entry.eff_pri, METHOD_TAGS[cast_method] or ''))
                end
                -- Virtual evade just fired -- ask the host to hold off
                -- its auto-dodge for the cast window.  See the
                -- HOST_DODGE_DEFERENCE_S comment near the top.
                if is_virtual then _yield_to_us(0.4) end
                return true
            end
            goto next_spell
        end

        -- Cursor targeting mode (target_mode == 5): cast at cursor position, no enemy needed
        if (cfg.target_mode or 0) == 5 then
            logger.log('  path: CURSOR CAST')
            local dc_ok, did_cast = pcall(function()
                return dispatch_cast(function()
                    return try_cursor_cast(spell_id, settings.anim_delay or 0.05)
                end, nil)
            end)
            if not dc_ok then
                if settings.debug then console.print(string.format('[UniversalRota] ERROR casting %s (cursor): %s', spell_name, tostring(did_cast))) end
                logger.log('  cast error (cursor): ' .. tostring(did_cast))
                goto next_spell
            end
            if did_cast then
                logger.log(string.format('  CAST SUCCESS: %s (cursor)', spell_name))
                spell_tracker.record_cast(spell_id, cfg.charges)
                _apply_chain(cfg)
                _record_stack_pri_cast(spell_id, cfg)
                _gcd_until = get_time_since_inject() + GLOBAL_GCD
                if settings.debug then
                    console.print(string.format('[UniversalRota] Cursor-Cast: %s (id=%s pri=%d eff=%d%s)',
                        entry.name, tostring(spell_id), cfg.priority, entry.eff_pri, METHOD_TAGS[cast_method] or ''))
                end
                return true
            end
            goto next_spell
        end

        -- Normal targeted cast
        do
            local spell_range = cfg.range or range

            -- Cross-plugin TARGET HINT: if an external plugin has set
            -- a kill target via _G.EXTERNAL_ROTATION_TARGET, prefer it
            -- over our own target_selector pick.  This keeps cast-
            -- target alignment with the plugin's walk target -- when
            -- the plugin is engaging a 30y Soulspire / BSK structure /
            -- elite / boss, we cast at THAT instead of the closest
            -- white mob, and orbwalker's cursor stays on the chosen
            -- target rather than yanking us back toward chaff.
            --
            -- Two modes:
            --   * HINT mode (settings.external_target_override == false):
            --     hint is preferred; falls back to UR's own picker
            --     when the hint is nil / dead / out of range.
            --   * OVERRIDE mode (settings.external_target_override == true):
            --     hint is AUTHORITATIVE.  No fallback -- if the hint
            --     is nil or invalid, this spell SKIPS this tick.
            --     Used by the WarMachine activity model and Gem Farmer
            --     where combat is gated by the external plugin -- the
            --     bot only fights when the plugin decides a mob is
            --     "interfering," and must hold fire during pure-nav
            --     phases.
            local target = nil
            local hint = _G.EXTERNAL_ROTATION_TARGET
            if hint then
                local valid = true
                if hint.is_dead then
                    local ok, dead = pcall(function () return hint:is_dead() end)
                    if ok and dead then valid = false end
                end
                if valid and hint.is_untargetable then
                    local ok, ut = pcall(function () return hint:is_untargetable() end)
                    if ok and ut then valid = false end
                end
                if valid and hint.is_immune then
                    local ok, im = pcall(function () return hint:is_immune() end)
                    if ok and im then valid = false end
                end
                if valid and spell_range and player_pos and hint.get_position then
                    local ok, hp = pcall(function () return hint:get_position() end)
                    if ok and hp then
                        local d2 = target_selector.dist2(hp, player_pos)
                        if d2 > (spell_range * spell_range) then valid = false end
                    else
                        valid = false
                    end
                end
                if valid then
                    target = hint
                    logger.log('  using EXTERNAL_ROTATION_TARGET hint')
                end
            end

            if not target then
                if settings.external_target_override then
                    -- Override mode: NO fallback.  The external plugin
                    -- has decided the bot should not engage anyone
                    -- right now (hint nil or invalid), so we hold fire.
                    -- This is what enforces "kill only when
                    -- interfering" -- the plugin clears the target
                    -- during pure navigation, so UR stays quiet.
                    logger.log('  SKIP: external_target_override on, no valid hint')
                    goto next_spell
                end
                target = target_selector.pick_target(targets, cfg, player_pos, spell_range)
            end

            if not target then
                logger.log('  SKIP: no valid target in range')
                local stype = cfg.spell_type or 0
                local is_melee = (stype == 1) or (stype == 0 and (spell_range or 0) <= 6.0)
                -- Only move toward the target if the user has explicitly opted into rotation movement.
                -- Otherwise leave movement to the orbwalker.
                if is_melee and targets.closest and settings.allow_movement and not settings.hold_active then
                    logger.log('  moving towards closest enemy')
                    try_move_towards(targets.closest, player_pos, spell_range)
                end
                goto next_spell
            end

            logger.log('  path: TARGETED CAST')
            local target_pos = nil
            pcall(function() target_pos = target:get_position() end)
            local dc_ok, did_cast = pcall(function()
                return dispatch_cast(function()
                    return try_cast(spell_id, target, player_pos, settings.anim_delay or 0.05, false)
                end, target_pos)
            end)
            if not dc_ok then
                if settings.debug then console.print(string.format('[UniversalRota] ERROR casting %s (targeted): %s', spell_name, tostring(did_cast))) end
                logger.log('  cast error (targeted): ' .. tostring(did_cast))
            end
            if did_cast then
                logger.log(string.format('  CAST SUCCESS: %s (targeted)', spell_name))
                spell_tracker.record_cast(spell_id, cfg.charges)
                _apply_chain(cfg)
                _record_stack_pri_cast(spell_id, cfg)
                _gcd_until = get_time_since_inject() + GLOBAL_GCD
                if settings.debug then
                    local mode_names = { [0]='Priority', [1]='Closest', [2]='LowestHP', [3]='HighestHP', [4]='Cleave', [5]='Cursor' }
                    console.print(string.format('[UniversalRota] Cast: %s (id=%s pri=%d eff=%d mode=%s%s)',
                        entry.name, tostring(spell_id), cfg.priority, entry.eff_pri,
                        mode_names[cfg.target_mode or 0] or '?', METHOD_TAGS[cast_method] or ''))
                end
                return true
            end
        end

        ::next_spell::
    end

    return false
end

function rotation_engine.set_scan_range(r)
    _scan_range = r or 16.0
end

function rotation_engine.reset()
    _release_all_channeled()
    _gcd_until        = 0.0
    _move_until       = 0.0
    _chain_boosts     = {}
    _stack_pri_counts = {}
end

function rotation_engine.release_channeled()
    _release_all_channeled()
end

return rotation_engine
