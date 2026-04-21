-- buddy/companion.lua — Deterministic companion roller
--
-- Bones (rarity, species, eye, hat, shiny, stats) are derived from a
-- seeded Mulberry32 PRNG keyed off `hash(userId .. SALT)`. They never
-- persist: species renames and edits to stored config cannot break or
-- forge stored companions.

local T = require("buddy.types")

local M = {}

local SALT = "friend-2026-401"

-- ── 32-bit helpers (Lua 5.3+) ─────────────────────────────────────────────

local BAND = bit and bit.band or function(a, b) return a & b end
local BOR = bit and bit.bor or function(a, b) return a | b end
local BXOR = bit and bit.bxor or function(a, b) return a ~ b end
local RSHIFT = bit and bit.rshift or function(a, n) return a >> n end
local LSHIFT = bit and bit.lshift or function(a, n) return a << n end

local MASK32 = 0xFFFFFFFF

local function mul32(a, b)
    -- Multiply two 32-bit ints, return low 32 bits.
    local ah = RSHIFT(a, 16)
    local al = BAND(a, 0xFFFF)
    local bh = RSHIFT(b, 16)
    local bl = BAND(b, 0xFFFF)
    local low = al * bl
    local mid = al * bh + ah * bl
    return BAND(low + LSHIFT(BAND(mid, 0xFFFF), 16), MASK32)
end

local function add32(a, b)
    return BAND(a + b, MASK32)
end

-- ── FNV-1a 32-bit hash ────────────────────────────────────────────────────

local function hash_string(s)
    local h = 2166136261
    for i = 1, #s do
        h = BXOR(h, string.byte(s, i))
        h = mul32(h, 16777619)
    end
    return BAND(h, MASK32)
end

-- ── Mulberry32 PRNG ───────────────────────────────────────────────────────

local function mulberry32(seed)
    local a = BAND(seed, MASK32)
    return function()
        a = add32(a, 0x6D2B79F5)
        -- t = Math.imul(a ^ (a >>> 15), 1 | a)
        local t = mul32(BXOR(a, RSHIFT(a, 15)), BOR(1, a))
        -- t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
        t = BXOR(add32(t, mul32(BXOR(t, RSHIFT(t, 7)), BOR(61, t))), t)
        -- return ((t ^ (t >>> 14)) >>> 0) / 4294967296
        return BXOR(t, RSHIFT(t, 14)) / 4294967296
    end
end

-- ── Rolling ───────────────────────────────────────────────────────────────

local function pick(rng, arr)
    return arr[math.floor(rng() * #arr) + 1]
end

local function roll_rarity(rng)
    local total = 0
    for _, r in ipairs(T.RARITIES) do total = total + T.RARITY_WEIGHTS[r] end
    local roll = rng() * total
    for _, r in ipairs(T.RARITIES) do
        roll = roll - T.RARITY_WEIGHTS[r]
        if roll < 0 then return r end
    end
    return "common"
end

local function roll_stats(rng, rarity)
    local floor = T.RARITY_FLOOR[rarity]
    local peak = pick(rng, T.STAT_NAMES)
    local dump = pick(rng, T.STAT_NAMES)
    while dump == peak do dump = pick(rng, T.STAT_NAMES) end

    local stats = {}
    for _, name in ipairs(T.STAT_NAMES) do
        if name == peak then
            stats[name] = math.min(100, floor + 50 + math.floor(rng() * 30))
        elseif name == dump then
            stats[name] = math.max(1, floor - 10 + math.floor(rng() * 15))
        else
            stats[name] = floor + math.floor(rng() * 40)
        end
    end
    return stats
end

local function roll_from(rng)
    local rarity = roll_rarity(rng)
    local bones = {
        rarity = rarity,
        species = pick(rng, T.SPECIES),
        eye = pick(rng, T.EYES),
        hat = rarity == "common" and "none" or pick(rng, T.HATS),
        shiny = rng() < 0.01,
        stats = roll_stats(rng, rarity),
    }
    return {
        bones = bones,
        inspiration_seed = math.floor(rng() * 1e9),
    }
end

-- ── Public API ────────────────────────────────────────────────────────────

local roll_cache -- { key = string, value = Roll }

function M.roll(user_id)
    local key = user_id .. SALT
    if roll_cache and roll_cache.key == key then return roll_cache.value end
    local value = roll_from(mulberry32(hash_string(key)))
    roll_cache = { key = key, value = value }
    return value
end

function M.roll_with_seed(seed)
    return roll_from(mulberry32(hash_string(seed)))
end

function M.companion_user_id(config)
    config = config or {}
    if config.oauth_account and config.oauth_account.account_uuid then
        return config.oauth_account.account_uuid
    end
    return config.user_id or "anon"
end

-- Merge stored soul with freshly-rolled bones so stale fields never leak.
function M.get_companion(config)
    config = config or {}
    local stored = config.companion
    if not stored then return nil end
    local rolled = M.roll(M.companion_user_id(config))
    local out = {}
    for k, v in pairs(stored) do out[k] = v end
    for k, v in pairs(rolled.bones) do out[k] = v end
    return out
end

-- ── Prompt attachment helper (ported from buddy/prompt.ts) ───────────────

function M.companion_intro_text(name, species)
    return string.format(
        "# Companion\n\n" ..
        "A small %s named %s sits beside the user's input box and occasionally comments in a speech bubble. " ..
        "You're not %s — it's a separate watcher.\n\n" ..
        "When the user addresses %s directly (by name), its bubble will answer. " ..
        "Your job in that moment is to stay out of the way: respond in ONE line or less, " ..
        "or just answer any part of the message meant for you. " ..
        "Don't explain that you're not %s — they know. " ..
        "Don't narrate what %s might say — the bubble handles that.",
        species, name, name, name, name, name
    )
end

function M.get_companion_intro_attachment(messages, config)
    if not config or config.companion_muted then return {} end
    local companion = M.get_companion(config)
    if not companion then return {} end

    -- Skip if already announced for this companion in the existing message list.
    for _, msg in ipairs(messages or {}) do
        if msg.type == "attachment"
            and msg.attachment
            and msg.attachment.type == "companion_intro"
            and msg.attachment.name == companion.name
        then
            return {}
        end
    end

    return {
        {
            type = "companion_intro",
            name = companion.name,
            species = companion.species,
        },
    }
end

return M
