-- buddy/types.lua — Companion (buddy) type tables

local M = {}

M.RARITIES = { "common", "uncommon", "rare", "epic", "legendary" }

M.SPECIES = {
    "duck", "goose", "blob", "cat", "dragon", "octopus", "owl", "penguin",
    "turtle", "snail", "ghost", "axolotl", "capybara", "cactus", "robot",
    "rabbit", "mushroom", "chonk",
}

M.EYES = { "·", "✦", "×", "◉", "@", "°" }

M.HATS = {
    "none", "crown", "tophat", "propeller", "halo", "wizard", "beanie", "tinyduck",
}

M.STAT_NAMES = { "DEBUGGING", "PATIENCE", "CHAOS", "WISDOM", "SNARK" }

M.RARITY_WEIGHTS = {
    common = 60,
    uncommon = 25,
    rare = 10,
    epic = 4,
    legendary = 1,
}

M.RARITY_FLOOR = {
    common = 5,
    uncommon = 15,
    rare = 25,
    epic = 35,
    legendary = 50,
}

M.RARITY_STARS = {
    common = "★",
    uncommon = "★★",
    rare = "★★★",
    epic = "★★★★",
    legendary = "★★★★★",
}

M.RARITY_COLORS = {
    common = "inactive",
    uncommon = "success",
    rare = "permission",
    epic = "autoAccept",
    legendary = "warning",
}

return M
