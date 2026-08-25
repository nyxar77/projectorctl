-- The persistent file is always a private laptop-only baseline. Presentation
-- layouts live in XDG_RUNTIME_DIR, so they cannot survive a reboot or login.
local projectorLayoutPaths = {
	os.getenv("HOME") .. "/.cache/hypr/projector-private-layout.lua",
}
local projectorRuntimeDir = os.getenv("XDG_RUNTIME_DIR")
if projectorRuntimeDir then
	table.insert(projectorLayoutPaths, projectorRuntimeDir .. "/projector-layout.lua")
end

for _, path in ipairs(projectorLayoutPaths) do
	local ok, layout = pcall(dofile, path)
	if ok and type(layout) == "table" then
		for _, rule in ipairs(layout) do
			hl.monitor(rule)
		end
	end
end

-- This stays usable with every display black and does not depend on the panel.
hl.bind("CTRL + ALT + F12", hl.dsp.exec_cmd("projectorctl recover"), { locked = true })
