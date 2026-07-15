-- projectorctl writes the current layout here, then reloads Hyprland. Monitor
-- rules must be evaluated by the configured Lua file to take effect.
local projectorLayoutPath = os.getenv("HOME") .. "/.cache/hypr/projector-layout.lua"
local projectorLayoutOk, projectorLayout = pcall(dofile, projectorLayoutPath)
if projectorLayoutOk and type(projectorLayout) == "table" then
	for _, rule in ipairs(projectorLayout) do
		hl.monitor(rule)
	end
end
