local ui = require("lib.ui")
local root = os.getenv("JENOVA_ROOT") or (debug.getinfo(1, "S").source:match("^@(.*/)") or "./"):gsub("/$", "")
ui.init(root)
ui.on_action("start")
