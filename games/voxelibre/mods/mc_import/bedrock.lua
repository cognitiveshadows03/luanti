--[[
	bedrock.lua - turns Bedrock Edition pack containers into Luanti content.

	Supported inputs (all are ordinary ZIP archives):

	  .mcpack     a single Bedrock pack (resource or behavior)
	  .mcaddon    one or more packs, resource and/or behavior
	  .mcworld    a world: level.dat + LevelDB + embedded packs
	  .mctemplate a world template, same layout as .mcworld
	  .zip        any resource pack (Java or Bedrock layout)

	What it produces:

	  * resource packs   -> a Luanti texture pack in <user>/textures/<name>/
	  * behavior packs   -> a Luanti mod in <world>/worldmods/<name>/ with the
	                        simple cube blocks it could understand
	  * worlds           -> the embedded packs are imported, and the world's
	                        name/seed/gamemode are reported

	What it cannot do is convert world terrain: Bedrock stores chunks in a
	LevelDB with its own palette/subchunk format, and there is no LevelDB reader
	in Luanti's Lua. That is reported honestly rather than silently skipped.
]]

local zip = dofile(core.get_modpath("mc_import") .. "/zip.lua")
local texture_map = dofile(core.get_modpath("mc_import") .. "/texture_map.lua")

local bedrock = {}

-- ---------------------------------------------------------------------------
-- tiny JSON helpers (Bedrock manifests are simple; core.parse_json exists)
-- ---------------------------------------------------------------------------
local function parse_json(text)
	if not text then return nil end
	local ok, res = pcall(core.parse_json, text)
	if ok then return res end
	return nil
end

-- ---------------------------------------------------------------------------
-- gzip containers (level.dat is gzip'd NBT)
-- ---------------------------------------------------------------------------
function bedrock.gunzip(data)
	if #data < 18 then return nil, "gzip too short" end
	if string.byte(data, 1) ~= 0x1f or string.byte(data, 2) ~= 0x8b then
		return nil, "not gzip"
	end
	local flg = string.byte(data, 4)
	local p = 11 -- 10 byte header + 1
	if flg % 2 == 1 then -- FEXTRA
		local xlen = string.byte(data, p) + string.byte(data, p + 1) * 256
		p = p + 2 + xlen
	end
	if math.floor(flg / 2) % 2 == 1 then -- FNAME
		while p <= #data and string.byte(data, p) ~= 0 do p = p + 1 end
		p = p + 1
	end
	if math.floor(flg / 4) % 2 == 1 then -- FCOMMENT
		while p <= #data and string.byte(data, p) ~= 0 do p = p + 1 end
		p = p + 1
	end
	if math.floor(flg / 8) % 2 == 1 then p = p + 2 end -- FHCRC
	return zip.inflate(data:sub(p))
end

-- ---------------------------------------------------------------------------
-- minimal NBT reader, enough to pull level.dat header fields
-- ---------------------------------------------------------------------------
--[[
	level.dat is NBT: a tagged binary tree with nested compounds. A general
	reader is easy to get subtly wrong (and a mis-parse silently produces
	garbage), so instead we scan for the handful of top-level keys we actually
	need. Each key appears as [tag byte][u16 name length][name bytes][value], and
	because we locate them by their literal name we never have to walk the whole
	tree.
]]
local NBT_TYPE = {BYTE = 1, SHORT = 2, INT = 3, LONG = 4, FLOAT = 5, DOUBLE = 6,
	BYTE_ARRAY = 7, STRING = 8, LIST = 9, COMPOUND = 10, INT_ARRAY = 11}

local function find_tag_value(raw, key)
	-- pattern: u16 length + key, preceded by the tag byte
	local needle = string.char(0, #key) .. key
	local at = 1
	while true do
		local p = raw:find(needle, at, true)
		if not p then return nil end
		if p >= 2 then
			local tag = raw:byte(p - 1)
			if tag >= 1 and tag <= 12 then
				return tag, p + #needle
			end
		end
		at = p + 1
	end
end

local function read_payload(raw, tag, pos)
	if tag == NBT_TYPE.STRING then
		local n = raw:byte(pos) * 256 + raw:byte(pos + 1)
		return raw:sub(pos + 2, pos + 1 + n)
	elseif tag == NBT_TYPE.BYTE then
		local v = raw:byte(pos)
		if v >= 128 then v = v - 256 end
		return v
	-- NBT integers are big-endian
	elseif tag == NBT_TYPE.SHORT then
		local a, b = raw:byte(pos, pos + 1)
		local v = a * 256 + b
		if v >= 32768 then v = v - 65536 end
		return v
	elseif tag == NBT_TYPE.INT then
		local a, b, c, d = raw:byte(pos, pos + 3)
		local v = a * 16777216 + b * 65536 + c * 256 + d
		if v >= 2147483648 then v = v - 4294967296 end
		return v
	elseif tag == NBT_TYPE.LONG then
		local function u32(off)
			local a, b, c, d = raw:byte(pos + off, pos + off + 3)
			return a * 16777216 + b * 65536 + c * 256 + d
		end
		local hi, lo = u32(0), u32(4)
		if hi >= 2147483648 then hi = hi - 4294967296 end
		if hi < 0 then
			return hi * 4294967296 + lo
		end
		return hi * 4294967296 + lo
	end
	return nil
end

--- Read the interesting parts of a level.dat (gzip'd NBT).
function bedrock.read_level_dat(bytes)
	local raw, err = bedrock.gunzip(bytes)
	if not raw then return nil, err end
	if raw:byte(1) ~= NBT_TYPE.COMPOUND then
		return nil, "level.dat root is not a compound"
	end

	local root = {}
	for _, key in ipairs({"LevelName", "RandomSeed", "GameType", "Difficulty"}) do
		local tag, pos = find_tag_value(raw, key)
		if tag then
			local v = read_payload(raw, tag, pos)
			if v ~= nil then root[key] = v end
		end
	end

	if next(root) == nil then
		return nil, "no known keys found in level.dat"
	end
	return root
end

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
local function dir_exists(p)
	local parent, base = p:match("^(.*)[/\\]([^/\\]+)$")
	if not parent or not base then return false end
	-- avoid listing directories outside the sandbox
	local ok, files = pcall(core.get_dir_list, parent, true)
	if ok and files then
		for _, name in ipairs(files) do
			if name == base then return true end
		end
	end
	local ok2, sub = pcall(core.get_dir_list, parent, false)
	if ok2 and sub then
		for _, name in ipairs(sub) do
			if name == base then return true end
		end
	end
	return false
end

--[[
	Create a directory tree.

	The server Lua sandbox rejects mkdir() on anything outside the world
	directory ("Blocked attempted write to home"), so we only ever create the
	components *below* the world path. Callers pass an absolute path that must
	already live inside the world.
]]
local function mkdirs(path)
	local base = core.get_worldpath():gsub("[/\\]+$", "")
	path = path:gsub("[/\\]+$", "")

	if path:sub(1, #base) ~= base then
		-- outside the world: nothing we are allowed to do
		return false, "refusing to create " .. path .. " (outside the world directory)"
	end

	local acc = base
	local rest = path:sub(#base + 1):gsub("^[/\\]+", "")
	for part in rest:gmatch("[^/\\]+") do
		acc = acc .. "/" .. part
		if not dir_exists(acc) then
			local ok, err = pcall(core.mkdir, acc)
			if not ok then return false, tostring(err) end
		end
	end
	return true
end

local function write_file(path, bytes)
	mkdirs(path:match("^(.*)[/\\][^/\\]+$") or ".")
	local fh = io.open(path, "wb")
	if not fh then return false, "cannot write " .. path end
	fh:write(bytes)
	fh:close()
	return true
end

local function sanitize(name)
	name = tostring(name or "imported")
	name = name:gsub("[^%w_%-%. ]", "_"):gsub("%s+", "_")
	return name:lower()
end

-- ---------------------------------------------------------------------------
-- resource packs -> Luanti texture pack
-- ---------------------------------------------------------------------------
--[[
	A Luanti texture pack is a folder of flat-named PNGs. Bedrock packs are
	tree-structured, so every texture is written under its mapped flat name.

	Note on where they go: the server Lua sandbox only permits writes inside the
	world directory, so we cannot drop a pack into <user>/textures/. Instead the
	textures are written into a generated mod under <world>/worldmods/, whose
	textures/ directory the engine searches like any other. That keeps everything
	inside the sandbox and takes effect on the next world start.
]]
function bedrock.import_resource_pack(z, pack_name, report, out_dir)
	local n_mapped, n_copied, n_skip = 0, 0, 0

	-- out_dir is the mod folder; textures live in its textures/ subdirectory
	local tex_dir = out_dir .. "/textures"
	local dir_ok, dir_err = mkdirs(tex_dir)
	if not dir_ok then
		report.skipped[#report.skipped + 1] = "cannot create " .. tex_dir .. ": " .. tostring(dir_err)
		return false
	end

	-- minimal mod so the engine mounts the textures
	write_file(out_dir .. "/mod.conf",
		("name = %s\ndescription = Textures imported from %s\n")
			:format(out_dir:match("[^/\\]+$"), pack_name))
	if not write_file(out_dir .. "/init.lua",
			"-- Generated by the MC Edition pack importer. Only provides textures.\n") then
		return false
	end

	for _, entry in ipairs(z:names()) do
		if entry:sub(-1) ~= "/" and (entry:lower():sub(-4) == ".png") then
			-- Entry paths may carry a pack folder prefix (e.g. inside an
			-- .mcaddon or .mcworld), so anchor on "textures/".
			local anchored = entry:match("(textures/.+)$") or entry
			local base = anchored:gsub("%.png$", "")
			local data = z:read(entry)
			if data then
				local target = texture_map[base]
				if target then
					local dst = tex_dir .. "/" .. (target:gsub("%.png$", "") .. ".png")
					if write_file(dst, data) then
						n_mapped = n_mapped + 1
						report.mapped[#report.mapped + 1] = base .. " -> " .. target
					end
				else
					-- keep the original name so it is at least available
					local flat = base:gsub("[/\\]", "_")
					local dst = tex_dir .. "/" .. flat .. ".png"
					if write_file(dst, data) then
						n_copied = n_copied + 1
						if n_copied <= 400 then
							report.unmapped[#report.unmapped + 1] = base
						end
					end
				end
			else
				n_skip = n_skip + 1
			end
		end
	end

	report.textures_mapped = n_mapped
	report.textures_copied = n_copied
	report.textures_failed = n_skip
	return true
end

-- ---------------------------------------------------------------------------
-- behavior packs -> Luanti mod (simple cube blocks only)
-- ---------------------------------------------------------------------------
local function bedrock_block_to_node(z, def_path, report)
	local text = z:read_text(def_path)
	local def = parse_json(text)
	if not def then
		report.skipped[#report.skipped + 1] = def_path .. " (unparseable JSON)"
		return nil
	end

	-- Bedrock block JSON: { "minecraft:block": { "description": {...},
	--   "components": { "minecraft:material_instances": {...}, ... } } }
	local block = def["minecraft:block"] or def["minecraft:block_def"]
	if not block then
		report.skipped[#report.skipped + 1] = def_path .. " (no minecraft:block)"
		return nil
	end
	local desc = block.description or {}
	local ident = (desc.identifier or ""):gsub("^minecraft:", "")
	if ident == "" then
		report.skipped[#report.skipped + 1] = def_path .. " (no identifier)"
		return nil
	end

	-- material_instances -> texture name
	local comps = block.components or {}
	local mat = comps["minecraft:material_instances"] or {}
	local tex
	for _, face in ipairs({"*", "up", "all", "side"}) do
		local inst = mat[face]
		if type(inst) == "table" and type(inst.texture) == "string" then
			tex = inst.texture
			break
		end
	end
	if not tex then
		report.skipped[#report.skipped + 1] = ident .. " (no material_instances texture)"
		return nil
	end

	-- Resolve the texture the same way the resource-pack importer writes it:
	-- mapped to a Luanti name when we know one, otherwise to the flattened
	-- original path.
	local tex_name = tex:gsub("^.*:", "")   -- drop any namespace
	local mapped = texture_map["textures/blocks/" .. tex_name]
	local tex_flat = mapped or ("textures_blocks_" .. tex_name:gsub("[/\\]", "_"))

	-- Luanti item names are "mod:item"; Bedrock identifiers may contain a colon.
	local node_name = "mcimport:" .. ident:gsub(":", "_")
	return {
		name = node_name,
		def = {
			description = ident,
			tiles = {tex_flat},
			groups = {cracky = 3, stone = 1, oddly_breakable_by_hand = 2},
		},
		texture_hint = tex,
	}
end

function bedrock.import_behavior_pack(z, pack_name, report, mod_dir)
	local nodes = {}

	for _, entry in ipairs(z:names()) do
		local lower = entry:lower()
		if lower:sub(-5) == ".json" and (lower:find("^blocks/") or lower:find("/blocks/")) then
			local node = bedrock_block_to_node(z, entry, report)
			if node then nodes[#nodes + 1] = node end
		end
	end

	if #nodes == 0 then
		report.skipped[#report.skipped + 1] =
			"behavior pack defines no simple cube blocks (script-driven content cannot run)"
		return false
	end

	mkdirs(mod_dir)
	local lua = {
		"-- Generated by the MC Edition Bedrock importer. Do not edit by hand.",
		"-- Source pack: " .. pack_name,
		"",
	}
	for _, n in ipairs(nodes) do
		lua[#lua + 1] = ("core.register_node(%q, {"):format(n.name)
		lua[#lua + 1] = ("\tdescription = %q,"):format(n.def.description)
		lua[#lua + 1] = ("\ttiles = {%q},"):format(n.def.tiles[1])
		lua[#lua + 1] = "\tgroups = {cracky = 3, stone = 1, oddly_breakable_by_hand = 2},"
		lua[#lua + 1] = "})"
		lua[#lua + 1] = ""
	end

	write_file(mod_dir .. "/init.lua", table.concat(lua, "\n"))
	write_file(mod_dir .. "/mod.conf", ("name = %s\ndescription = Imported from %s\n")
		:format(sanitize(pack_name), pack_name))

	report.blocks_registered = #nodes
	return true
end

-- ---------------------------------------------------------------------------
-- container driver
-- ---------------------------------------------------------------------------
--- Inspect which packs a zip contains.
function bedrock.inspect(z)
	local packs = {}
	local manifest = parse_json(z:read_text("manifest.json"))

	if manifest and manifest.modules then
		local kind = "resources"
		for _, m in ipairs(manifest.modules) do
			if m.type == "data" then kind = "data" end
			if m.type == "script" then kind = "script" end
		end
		packs[#packs + 1] = {
			name = (manifest.header and manifest.header.name) or "pack",
			kind = kind,
			-- sub-packs inside an .mcaddon live in subfolders
			prefix = "",
		}
	else
		-- .mcaddon / .mcworld: look for nested manifests
		for _, entry in ipairs(z:names()) do
			if entry:match("^[^/]+/manifest%.json$") then
				local sub = entry:gsub("/manifest%.json$", "")
				local m = parse_json(z:read_text(entry))
				if m then
					local kind = "resources"
					for _, mod in ipairs(m.modules or {}) do
						if mod.type == "data" then kind = "data" end
						if mod.type == "script" then kind = "script" end
					end
					packs[#packs + 1] = {
						name = (m.header and m.header.name) or sub,
						kind = kind,
						prefix = sub,
					}
				end
			end
		end
	end

	return packs
end

return bedrock
