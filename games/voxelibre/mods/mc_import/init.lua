--[[
	mc_import - import Minecraft Bedrock content into Luanti.

	Minecraft stores its add-ons as ZIP containers, which are pure data:

	  .mcpack / .mcaddon  resource packs (textures, sounds, UI) and behavior
	                      packs (blocks, items, loot, recipes as JSON)
	  .mcworld            a world plus the packs it uses

	This mod reads those containers and converts what is genuinely convertible.
	It is deliberately explicit about what fails, because a mod whose content
	only exists as Bedrock's script API cannot be converted at all.

	Usage, in-game:
		/mcimport <path>          import a pack or world
		/mcimport scan            import everything in the import folder
		/mcimport packs           list what has been imported

	The import folder is <world path>/mc_import/ and is created on first use.
	Everything imported also lands there, so results are easy to find.
]]

local modpath = core.get_modpath("mc_import")
local zip = dofile(modpath .. "/zip.lua")
local bedrock = dofile(modpath .. "/bedrock.lua")

local worldpath = core.get_worldpath()
local IMPORT_DIR = worldpath .. "/mc_import"

-- core.get_user_path() is mainmenu-only, so derive the user directory from the
-- world path (<user>/worlds/<name>) the way the engine lays it out.
local USER_ROOT = worldpath:gsub("[/\\]worlds[/\\][^/\\]+$", "")
local TEXTURE_ROOT = USER_ROOT .. "/textures"

local imported_log = {}

-- core.dir_exists() does not exist in the server Lua API; probe the parent.
local function path_exists(p)
	local f = io.open(p, "rb")
	if f then f:close(); return true end
	local parent, base = p:match("^(.*)[/\\]([^/\\]+)$")
	if not parent or not base then return false end
	for _, list in ipairs({false, true}) do
		for _, name in ipairs(core.get_dir_list(parent, list) or {}) do
			if name == base then return true end
		end
	end
	return false
end

local function ensure_import_dir()
	if not path_exists(IMPORT_DIR) then core.mkdir(IMPORT_DIR) end
end

local function new_report(task)
	return {
		task = task,
		mapped = {},
		unmapped = {},
		skipped = {},
		notes = {},
		textures_mapped = 0,
		textures_copied = 0,
		textures_failed = 0,
		blocks_registered = 0,
	}
end

local function report_text(r)
	local out = {"=== MC import: " .. r.task .. " ==="}
	local function section(title, list, cap)
		if #list == 0 then return end
		out[#out + 1] = title .. " (" .. #list .. ")"
		for i = 1, math.min(#list, cap or 12) do
			out[#out + 1] = "  - " .. list[i]
		end
		if #list > (cap or 12) then
			out[#out + 1] = "  ... and " .. (#list - (cap or 12)) .. " more"
		end
	end
	if #r.notes > 0 then section("Notes", r.notes, 20) end
	if r.textures_mapped > 0 or r.textures_copied > 0 then
		out[#out + 1] = ("Textures: %d mapped, %d kept under original name, %d failed")
			:format(r.textures_mapped, r.textures_copied, r.textures_failed)
	end
	if r.blocks_registered > 0 then
		out[#out + 1] = ("Blocks registered: %d"):format(r.blocks_registered)
	end
	section("Mapped", r.mapped, 8)
	section("Copied but unmapped", r.unmapped, 8)
	section("Not convertible", r.skipped, 20)
	out[#out + 1] = "Full report written next to the imported files."
	return table.concat(out, "\n")
end

local function save_report(r)
	ensure_import_dir()
	local path = IMPORT_DIR .. "/report_" .. tostring(r.task:gsub("[^%w]", "_")) .. ".txt"
	local fh = io.open(path, "w")
	if fh then
		fh:write(report_text(r))
		fh:close()
	end
	return path
end

-- ---------------------------------------------------------------------------
-- one container
-- ---------------------------------------------------------------------------
local function import_file(path, report)
	local z, err = zip.open(path)
	if not z then
		report.skipped[#report.skipped + 1] = path .. ": " .. tostring(err)
		return false
	end

	-- .mcworld / .mctemplate: world settings + embedded packs
	if z:exists("level.dat") then
		local lvl = z:read("level.dat")
		if lvl then
			local root, lerr = bedrock.read_level_dat(lvl)
			if root then
				local name = root.LevelName or "unnamed world"
				local seed = root.RandomSeed or root.seed or "?"
				local gm = root.GameType or "?"
				local diff = root.Difficulty or "?"
				local gamemode = ({[0]="survival",[1]="creative",[2]="adventure"})[gm] or tostring(gm)
				report.notes[#report.notes + 1] = ("world name: %s"):format(name)
				report.notes[#report.notes + 1] = ("world seed: %s"):format(tostring(seed))
				report.notes[#report.notes + 1] = ("gamemode: %s, difficulty: %s")
					:format(gamemode, tostring(diff))
				report.notes[#report.notes + 1] =
					"terrain is NOT converted: Bedrock stores chunks in a LevelDB " ..
					"with its own palette format, which Luanti cannot read. " ..
					"Recreate the world with the seed above for a similar landscape."
			else
				report.notes[#report.notes + 1] = "level.dat present but unreadable: " ..
					tostring(lerr)
			end
		end
		if z:exists("db/CURRENT") or z:exists("db/MANIFEST-000001") then
			report.notes[#report.notes + 1] = "world database detected (LevelDB) - see note above"
		end
	end

	local packs = bedrock.inspect(z)
	if #packs == 0 then
		-- A bare resource pack zip with no manifest: treat as textures.
		packs = {{name = "textures", kind = "resources", prefix = ""}}
		report.notes[#report.notes + 1] = "no manifest.json; treating as a plain texture pack"
	end

	local did_something = false
	for _, pack in ipairs(packs) do
		local base = tostring(path):match("([^/\\]+)%.%w+$") or "imported"
		local pack_name = base .. "_" .. pack.name
		if pack.kind == "resources" then
			-- Output goes under <world>/mc_import/, the only place the server Lua
			-- sandbox permits writes (worldmods/ and game/ are blocked on
			-- purpose so mods cannot install code).
			local out_dir = IMPORT_DIR .. "/out/" .. base ..
				("/" .. pack.name):gsub("[^%w_%-]", "_"):lower()
			local ok = bedrock.import_resource_pack(z, pack_name, report, out_dir)
			if ok then
				report.notes[#report.notes + 1] = "texture pack written to " .. out_dir ..
					" (copy its contents into " .. USER_ROOT .. "/textures/<name>/ to use it)"
				did_something = true
			end
		elseif pack.kind == "data" then
			local mod_dir = IMPORT_DIR .. "/out/" .. base .. "/" .. ("mod_" .. pack.name)
				:gsub("[^%w_%-]", "_"):lower()
			local ok = bedrock.import_behavior_pack(z, pack_name, report, mod_dir)
			if ok then
				report.notes[#report.notes + 1] = "mod written to " .. mod_dir ..
					" (copy it into a worldmods/ or mods/ folder to load it)"
				did_something = true
			end
		elseif pack.kind == "script" then
			report.skipped[#report.skipped + 1] =
				"pack '" .. tostring(pack.name) .. "' is script-driven " ..
				"(JavaScript API): compiled game logic cannot be converted"
		end
	end

	return did_something
end

-- ---------------------------------------------------------------------------
-- player-facing commands
-- ---------------------------------------------------------------------------
core.register_chatcommand("mcimport", {
	params = "<path> | scan | packs",
	description = "Import a Minecraft .mcpack/.mcaddon/.mcworld file",
	func = function(name, param)
		param = (param or ""):gsub("^%s+", ""):gsub("%s+$", "")

		if param == "packs" then
			if #imported_log == 0 then
				return true, "Nothing imported yet this session."
			end
			return true, table.concat(imported_log, "\n")
		end

		if param == "scan" then
			ensure_import_dir()
			local found = 0
			local ok_count = 0
			local dir = core.get_dir_list(IMPORT_DIR, false)
			for _, f in ipairs(dir or {}) do
				if f:lower():match("%.mcpack$") or f:lower():match("%.mcaddon$")
						or f:lower():match("%.mcworld$") or f:lower():match("%.mctemplate$") then
					found = found + 1
					local report = new_report(f)
					if import_file(IMPORT_DIR .. "/" .. f, report) then ok_count = ok_count + 1 end
					save_report(report)
					imported_log[#imported_log + 1] = f .. ": " ..
						(ok_count > 0 and "imported" or "nothing convertible")
					core.log("action", "[mc_import] " .. report_text(report))
				end
			end
			if found == 0 then
				return true, "No .mcpack/.mcaddon/.mcworld files in " .. IMPORT_DIR
			end
			return true, ("Scanned %d file(s): %d imported. See the log for details.")
				:format(found, ok_count)
		end

		if param == "" then
			return false, "Usage: /mcimport <path to .mcpack/.mcaddon/.mcworld> | scan | packs"
		end

		local report = new_report(param)
		local any = import_file(param, report)
		local text = report_text(report)
		core.log("action", "[mc_import] " .. text)
		save_report(report)
		imported_log[#imported_log + 1] = param .. ": " .. (any and "imported" or "nothing convertible")
		return true, text
	end,
})

-- Create the drop folder and pick up anything already waiting in it, so a
-- player can drop files in, restart, and be done.
core.after(0, function()
	ensure_import_dir()

	local pending = {}
	for _, f in ipairs(core.get_dir_list(IMPORT_DIR, false) or {}) do
		local lower = f:lower()
		if lower:match("%.mcpack$") or lower:match("%.mcaddon$")
				or lower:match("%.mcworld$") or lower:match("%.mctemplate$") then
			pending[#pending + 1] = f
		end
	end

	if #pending == 0 then
		core.log("action", "[mc_import] Drop .mcpack/.mcaddon/.mcworld files in " ..
			IMPORT_DIR .. " and run /mcimport scan")
		return
	end

	core.log("action", ("[mc_import] auto-importing %d file(s) from %s")
		:format(#pending, IMPORT_DIR))
	for _, f in ipairs(pending) do
		local report = new_report(f)
		local ok = import_file(IMPORT_DIR .. "/" .. f, report)
		core.log("action", "[mc_import] " .. report_text(report))
		save_report(report)
		imported_log[#imported_log + 1] = f .. ": " .. (ok and "imported" or "nothing convertible")
	end
end)
