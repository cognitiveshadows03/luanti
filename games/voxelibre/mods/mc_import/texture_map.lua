--[[
	texture_map.lua - maps Minecraft (Bedrock / Java) texture paths onto the
	names the bundled game actually uses.

	Bedrock resource packs name things "textures/blocks/stone.png"; VoxeLibre and
	the wider Luanti ecosystem use flat names like "default_stone.png". Anything
	not listed here is still copied verbatim into the generated pack (so it can
	be referenced by name) and is reported as "copied but unmapped".
]]

return {
	-- ---- blocks -----------------------------------------------------------
	["textures/blocks/stone"]              = "default_stone",
	["textures/blocks/cobblestone"]        = "default_cobble",
	["textures/blocks/dirt"]               = "default_dirt",
	["textures/blocks/grass_side"]         = "default_grass_side",
	["textures/blocks/grass_top"]          = "default_grass",
	["textures/blocks/grass_path_side"]    = "default_grass_side",
	["textures/blocks/sand"]               = "default_sand",
	["textures/blocks/gravel"]             = "default_gravel",
	["textures/blocks/sandstone_top"]      = "default_sandstone",
	["textures/blocks/sandstone_normal"]   = "default_sandstone",
	["textures/blocks/bedrock"]            = "default_bedrock",
	["textures/blocks/obsidian"]           = "default_obsidian",
	["textures/blocks/brick"]              = "default_brick",
	["textures/blocks/glass"]              = "default_glass",
	["textures/blocks/snow"]               = "default_snow",
	["textures/blocks/ice"]                = "default_ice",
	["textures/blocks/clay"]               = "default_clay",
	["textures/blocks/water_still"]        = "default_water",
	["textures/blocks/lava_still"]         = "default_lava",
	["textures/blocks/coal_block"]         = "default_coal_block",
	["textures/blocks/iron_block"]         = "default_steel_block",
	["textures/blocks/gold_block"]         = "default_gold_block",
	["textures/blocks/diamond_block"]      = "default_diamond_block",
	["textures/blocks/emerald_block"]      = "default_mese_block",
	["textures/blocks/tnt_side"]           = "default_tnt_side",
	["textures/blocks/tnt_top"]            = "default_tnt_top",
	["textures/blocks/tnt_bottom"]         = "default_tnt_bottom",
	["textures/blocks/bookshelf"]          = "default_bookshelf",
	["textures/blocks/furnace_side"]       = "default_furnace_side",
	["textures/blocks/furnace_top"]        = "default_furnace_top",
	["textures/blocks/ladder"]             = "default_ladder",
	["textures/blocks/stonebrick"]         = "default_stone_brick",
	["textures/blocks/mossy_cobblestone"]  = "default_mossycobble",
	["textures/blocks/leaves_oak"]         = "default_leaves",
	["textures/blocks/leaves_oak_opaque"]  = "default_leaves_simple",
	["textures/blocks/log_oak"]            = "default_tree",
	["textures/blocks/log_oak_top"]        = "default_tree_top",
	["textures/blocks/planks_oak"]         = "default_wood",
	["textures/blocks/sapling_oak"]        = "default_sapling",

	-- ---- items ------------------------------------------------------------
	["textures/items/apple"]               = "default_apple",
	["textures/items/coal"]                = "default_coal_lump",
	["textures/items/diamond"]             = "default_diamond",
	["textures/items/iron_ingot"]          = "default_steel_ingot",
	["textures/items/gold_ingot"]          = "default_gold_ingot",
	["textures/items/clay_ball"]           = "default_clay_lump",
	["textures/items/brick"]               = "default_clay_brick",
	["textures/items/paper"]               = "default_paper",
	["textures/items/book_normal"]         = "default_book",
	["textures/items/stick"]               = "default_stick",
	["textures/items/flint"]               = "default_flint",
	["textures/items/gunpowder"]           = "default_gunpowder",
	["textures/items/diamond_pickaxe"]     = "default_tool_diamondpick",
	["textures/items/diamond_axe"]         = "default_tool_diamondaxe",
	["textures/items/diamond_shovel"]      = "default_tool_diamondshovel",
	["textures/items/diamond_sword"]       = "default_tool_diamondsword",
	["textures/items/iron_pickaxe"]        = "default_tool_steelpick",
	["textures/items/iron_axe"]            = "default_tool_steelaxe",
	["textures/items/iron_shovel"]         = "default_tool_steelshovel",
	["textures/items/iron_sword"]          = "default_tool_steelsword",
	["textures/items/gold_pickaxe"]        = "default_tool_goldpick",
	["textures/items/gold_axe"]            = "default_tool_goldaxe",
	["textures/items/gold_sword"]          = "default_tool_goldsword",
	["textures/items/wood_pickaxe"]        = "default_tool_woodpick",
	["textures/items/wood_axe"]            = "default_tool_woodaxe",
	["textures/items/wood_sword"]          = "default_tool_woodsword",
	["textures/items/stone_pickaxe"]       = "default_tool_stonepick",
	["textures/items/stone_axe"]           = "default_tool_stoneaxe",
	["textures/items/stone_sword"]         = "default_tool_stonesword",

	-- ---- environment / ui -------------------------------------------------
	["textures/environment/sun"]           = "sun.png",
	["textures/environment/moon_phases"]   = "moon.png",
	["textures/ui/cross_hair"]             = "crosshair.png",
}
