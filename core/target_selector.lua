local target_selector = {}

-- Targeting modes (used by spell_cfg.target_mode)
target_selector.MODE_PRIORITY  = 0   -- boss > elite > champion > closest  (default)
target_selector.MODE_CLOSEST   = 1   -- nearest enemy
target_selector.MODE_LOWEST_HP = 2   -- execute: least current HP
target_selector.MODE_HIGHEST_HP = 3  -- tankiest enemy
target_selector.MODE_CLEAVE    = 4   -- most enemies within aoe_range

local SCAN_RANGE = 16.0

local function _try(fn, ...)
    local ok, v = pcall(fn, ...)
    if not ok then return nil end
    return v
end

local function _truthy(fn, ...)
    local v = _try(fn, ...)
    return v and true or false
end

local function _pos(obj)
    return _try(function() return obj:get_position() end)
end

local function _dist2(a_pos, b_pos)
    if a_pos and a_pos.squared_dist_to_ignore_z then
        return _try(function() return a_pos:squared_dist_to_ignore_z(b_pos) end) or math.huge
    end
    if not (a_pos and b_pos and a_pos.x and b_pos.x) then return math.huge end
    local dx = a_pos:x() - b_pos:x()
    local dy = a_pos:y() - b_pos:y()
    return dx * dx + dy * dy
end

function target_selector.dist2(a_pos, b_pos)
    return _dist2(a_pos, b_pos)
end

local function _is_dead(obj)
    return _truthy(function() return obj:is_dead() end)
end

local function _is_valid_enemy(obj)
    if not obj then return false end
    if _is_dead(obj) then return false end
    if obj.is_enemy and not _truthy(function() return obj:is_enemy() end) then return false end
    if obj.is_immune and _truthy(function() return obj:is_immune() end) then return false end
    if obj.is_untargetable and _truthy(function() return obj:is_untargetable() end) then return false end
    return true
end

local function _enemy_list()
    if not actors_manager then return {} end
    if type(actors_manager.get_enemy_npcs) == 'function' then
        return _try(actors_manager.get_enemy_npcs) or {}
    end
    if type(actors_manager.get_enemy_actors) == 'function' then
        return _try(actors_manager.get_enemy_actors) or {}
    end
    return {}
end

local function _is_boss(obj)     return obj.is_boss and _truthy(function() return obj:is_boss() end) end
local function _is_elite(obj)    return obj.is_elite and _truthy(function() return obj:is_elite() end) end
local function _is_champion(obj) return obj.is_champion and _truthy(function() return obj:is_champion() end) end

local function _get_current_hp(obj)
    if type(obj.get_current_health) == 'function' then
        local v = _try(function() return obj:get_current_health() end)
        if type(v) == 'number' then return v end
    end
    return math.huge
end

-- Count how many enemies in `all_enemies` are within `radius` of `center_pos`
local function _count_nearby(all_enemies, center_pos, radius)
    local r2 = radius * radius
    local c = 0
    for _, e in ipairs(all_enemies) do
        local ep = _pos(e)
        if ep and _dist2(ep, center_pos) <= r2 then
            c = c + 1
        end
    end
    return c
end

function target_selector.get_targets(player_pos, range, options)
    range = range or SCAN_RANGE
    local r2 = range * range

    local enemies = _enemy_list()
    local result = {
        is_valid       = false,
        closest        = nil,
        closest_elite  = nil,
        closest_boss   = nil,
        closest_champ  = nil,
        has_elite      = false,
        has_boss       = false,
        has_champion   = false,
        enemy_count    = 0,
        all_enemies    = {},
    }

    local closest_dist       = math.huge
    local closest_elite_dist = math.huge
    local closest_boss_dist  = math.huge
    local closest_champ_dist = math.huge

    for _, enemy in ipairs(enemies or {}) do
        if not _is_valid_enemy(enemy) then goto continue end

        local epos = _pos(enemy)
        if not epos then goto continue end

        local d2 = _dist2(epos, player_pos)
        if d2 > r2 then goto continue end

        -- Line-of-sight / cliff filter (opt-in via options.los_enabled)
        if options and options.los_enabled then
            -- Height check: skip enemies on unreachable cliffs or floors
            local ok_z, dz = pcall(function()
                return math.abs(player_pos:z() - epos:z())
            end)
            if ok_z and dz and dz > (options.los_height_max or 1.5) then goto continue end

            -- Wall check via prediction module (single fast call)
            if prediction and type(prediction.is_wall_collision) == 'function' then
                local ok_w, blocked = pcall(prediction.is_wall_collision, player_pos, epos, 1.0)
                if ok_w and blocked then goto continue end
            end
        end

        result.is_valid = true
        result.enemy_count = result.enemy_count + 1
        result.all_enemies[#result.all_enemies + 1] = enemy

        if d2 < closest_dist then
            closest_dist = d2
            result.closest = enemy
        end

        if _is_boss(enemy) then
            result.has_boss = true
            if d2 < closest_boss_dist then
                closest_boss_dist = d2
                result.closest_boss = enemy
            end
        elseif _is_elite(enemy) then
            result.has_elite = true
            if d2 < closest_elite_dist then
                closest_elite_dist = d2
                result.closest_elite = enemy
            end
        elseif _is_champion(enemy) then
            result.has_champion = true
            if d2 < closest_champ_dist then
                closest_champ_dist = d2
                result.closest_champ = enemy
            end
        end

        ::continue::
    end

    return result
end

function target_selector.pick_target(targets, spell_cfg, player_pos, range)
    if not (targets and targets.is_valid) then return nil end

    local r2 = nil
    if range and player_pos then r2 = range * range end

    local function in_range(enemy)
        if not r2 then return true end
        local epos = _pos(enemy)
        if not epos then return false end
        return _dist2(epos, player_pos) <= r2
    end

    -- Build a filtered list of in-range enemies
    local function build_in_range()
        local out = {}
        for _, e in ipairs(targets.all_enemies or {}) do
            if e and in_range(e) then
                out[#out + 1] = e
            end
        end
        return out
    end

    local function best_of(candidates)
        if not (candidates and player_pos and r2) then
            for _, e in ipairs(candidates or {}) do
                if e and in_range(e) then return e end
            end
            return nil
        end
        local best, best_d2 = nil, math.huge
        for _, e in ipairs(candidates or {}) do
            if e and in_range(e) then
                local d2 = _dist2(_pos(e), player_pos)
                if d2 < best_d2 then
                    best, best_d2 = e, d2
                end
            end
        end
        return best
    end

    -- Determine targeting mode; default 0 = priority
    local mode = (spell_cfg and tonumber(spell_cfg.target_mode)) or target_selector.MODE_PRIORITY

    -- Boss-only / elite-only filters override the mode selection
    if spell_cfg and spell_cfg.boss_only then
        -- Always priority-pick a boss regardless of mode
        if targets.closest_boss and in_range(targets.closest_boss) then return targets.closest_boss end
        local bosses = {}
        for _, e in ipairs(targets.all_enemies or {}) do
            if e and in_range(e) and _is_boss(e) then bosses[#bosses+1] = e end
        end
        return best_of(bosses)
    end

    if spell_cfg and spell_cfg.elite_only then
        if targets.closest_boss and in_range(targets.closest_boss) then return targets.closest_boss end
        if targets.closest_elite and in_range(targets.closest_elite) then return targets.closest_elite end
        if targets.closest_champ and in_range(targets.closest_champ) then return targets.closest_champ end
        local hi = {}
        for _, e in ipairs(targets.all_enemies or {}) do
            if e and in_range(e) and (_is_boss(e) or _is_elite(e) or _is_champion(e)) then hi[#hi+1] = e end
        end
        return best_of(hi)
    end

    -- ----------------------------------------------------------------
    -- MODE: Priority (boss > elite > champion > closest)
    -- ----------------------------------------------------------------
    if mode == target_selector.MODE_PRIORITY then
        if targets.closest_boss and in_range(targets.closest_boss) then return targets.closest_boss end
        if targets.closest_elite and in_range(targets.closest_elite) then return targets.closest_elite end
        if targets.closest_champ and in_range(targets.closest_champ) then return targets.closest_champ end
        if targets.closest and in_range(targets.closest) then return targets.closest end

        local in_r = build_in_range()
        if #in_r == 0 then return nil end
        local bosses, elites, champs = {}, {}, {}
        for _, e in ipairs(in_r) do
            if _is_boss(e) then bosses[#bosses+1] = e
            elseif _is_elite(e) then elites[#elites+1] = e
            elseif _is_champion(e) then champs[#champs+1] = e
            end
        end
        local b = best_of(bosses); if b then return b end
        local el = best_of(elites); if el then return el end
        local c = best_of(champs); if c then return c end
        return best_of(in_r)
    end

    -- ----------------------------------------------------------------
    -- MODE: Closest
    -- ----------------------------------------------------------------
    if mode == target_selector.MODE_CLOSEST then
        if targets.closest and in_range(targets.closest) then return targets.closest end
        return best_of(build_in_range())
    end

    -- ----------------------------------------------------------------
    -- MODE: Lowest HP (execute)
    -- ----------------------------------------------------------------
    if mode == target_selector.MODE_LOWEST_HP then
        local in_r = build_in_range()
        local best, best_hp = nil, math.huge
        for _, e in ipairs(in_r) do
            local hp = _get_current_hp(e)
            if hp < best_hp then
                best_hp = hp
                best = e
            end
        end
        return best
    end

    -- ----------------------------------------------------------------
    -- MODE: Highest HP
    -- ----------------------------------------------------------------
    if mode == target_selector.MODE_HIGHEST_HP then
        local in_r = build_in_range()
        local best, best_hp = nil, -math.huge
        for _, e in ipairs(in_r) do
            local hp = _get_current_hp(e)
            if hp > best_hp then
                best_hp = hp
                best = e
            end
        end
        return best
    end

    -- ----------------------------------------------------------------
    -- MODE: Cleave Center (most enemies within aoe_range of target)
    -- ----------------------------------------------------------------
    if mode == target_selector.MODE_CLEAVE then
        local in_r = build_in_range()
        local aoe_r = (spell_cfg and spell_cfg.aoe_range) or 6.0
        local best, best_count = nil, -1
        for _, e in ipairs(in_r) do
            local ep = _pos(e)
            if ep then
                local cnt = _count_nearby(targets.all_enemies, ep, aoe_r)
                if cnt > best_count then
                    best_count = cnt
                    best = e
                end
            end
        end
        return best
    end

    -- Fallback to closest
    if targets.closest and in_range(targets.closest) then return targets.closest end
    return best_of(build_in_range())
end

function target_selector.count_near(targets, pos, radius)
    if not (targets and targets.all_enemies) then return 0 end
    local r2 = radius * radius
    local c = 0
    for _, enemy in ipairs(targets.all_enemies) do
        local epos = _pos(enemy)
        if epos and _dist2(epos, pos) <= r2 then c = c + 1 end
    end
    return c
end

return target_selector
