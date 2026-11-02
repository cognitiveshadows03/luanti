--[[
	zip.lua - minimal, dependency-free ZIP reader for Luanti's Lua sandbox.

	Luanti's Lua has no zip or deflate support at all, and Minecraft pack files
	(.mcpack / .mcaddon / .mcworld / resource packs) are all ordinary ZIP
	archives. This module provides the minimum needed to read them:

	  * end-of-central-directory + central directory parsing,
	  * stored (method 0) and deflated (method 8) entries,
	  * raw DEFLATE inflate, written as a translation of Mark Adler's public
	    domain "puff" reference decoder.

	It is deliberately small and allocation-light so it still behaves on a
	low-end phone: entries are inflated one at a time and never held together.

	Usage:
		local zip = dofile("zip.lua")
		local z = zip.open("/path/to/pack.mcpack")
		for _, name in ipairs(z:names()) do ... end
		local bytes = z:read("manifest.json")
]]

local zip = {}

-- ---------------------------------------------------------------------------
-- 32-bit helpers. Luanti ships LuaJIT so `bit` is available; the arithmetic
-- fallback keeps this working under plain Lua 5.1 too.
-- ---------------------------------------------------------------------------
local ok, bitlib = pcall(require, "bit")
local band, bor, bxor, lshift, rshift

if ok and bitlib then
	band, bor, bxor = bitlib.band, bitlib.bor, bitlib.bxor
	lshift, rshift = bitlib.lshift, bitlib.rshift
else
	local function toint(x)
		x = x % 0x100000000
		if x >= 0x80000000 then x = x - 0x100000000 end
		return x
	end
	band = function(a, b)
		local r, bitv = 0, 1
		for _ = 1, 32 do
			local x, y = a % 2, b % 2
			if x == 1 and y == 1 then r = r + bitv end
			a, b, bitv = (a - x) / 2, (b - y) / 2, bitv * 2
		end
		return toint(r)
	end
	bor = function(a, b)
		local r, bitv = 0, 1
		for _ = 1, 32 do
			local x, y = a % 2, b % 2
			if x == 1 or y == 1 then r = r + bitv end
			a, b, bitv = (a - x) / 2, (b - y) / 2, bitv * 2
		end
		return toint(r)
	end
	bxor = function(a, b)
		local r, bitv = 0, 1
		for _ = 1, 32 do
			local x, y = a % 2, b % 2
			if x ~= y then r = r + bitv end
			a, b, bitv = (a - x) / 2, (b - y) / 2, bitv * 2
		end
		return toint(r)
	end
	lshift = function(a, n) return toint(a * 2 ^ n) end
	rshift = function(a, n) return toint(math.floor(a / 2 ^ n)) end
end

-- ---------------------------------------------------------------------------
-- Little-endian readers over a byte string
-- ---------------------------------------------------------------------------
local byte, sub, char = string.byte, string.sub, string.char

local function u8(s, i) return byte(s, i) end
local function u16(s, i) return byte(s, i) + byte(s, i + 1) * 256 end
local function u32(s, i)
	return byte(s, i) + byte(s, i + 1) * 256 + byte(s, i + 2) * 65536 +
		byte(s, i + 3) * 16777216
end

-- ---------------------------------------------------------------------------
-- DEFLATE (RFC 1951)
-- ---------------------------------------------------------------------------

-- Canonical Huffman table, in the style of puff: counts per code length plus
-- the symbols ordered by code.
local function build_huffman(lengths, n)
	local count = {}
	for i = 1, 15 do count[i] = 0 end
	for i = 1, n do
		local l = lengths[i]
		if l then count[l] = (count[l] or 0) + 1 end
	end
	local left = 1
	for len = 1, 15 do
		left = left * 2 - count[len]
		if left < 0 then return nil, "over-subscribed Huffman code" end
	end
	local offs = {}
	offs[1] = 0
	for len = 1, 14 do
		offs[len + 1] = offs[len] + count[len]
	end
	local symbol = {}
	for i = 1, n do
		local l = lengths[i]
		if l and l ~= 0 then
			symbol[offs[l]] = i - 1
			offs[l] = offs[l] + 1
		end
	end
	return {count = count, symbol = symbol}
end

local function bitreader(data)
	return {data = data, pos = 1, bitbuf = 0, bitcnt = 0}
end

local function bits(s, need)
	local val = s.bitbuf
	while s.bitcnt < need do
		local b = byte(s.data, s.pos)
		if not b then return nil, "unexpected end of deflate stream" end
		s.pos = s.pos + 1
		val = val + b * 2 ^ s.bitcnt
		s.bitcnt = s.bitcnt + 8
	end
	s.bitbuf = math.floor(val / 2 ^ need)
	s.bitcnt = s.bitcnt - need
	return val % 2 ^ need
end

local function decode_sym(s, h)
	local code, first, index = 0, 0, 0
	for len = 1, 15 do
		local b, err = bits(s, 1)
		if not b then return nil, err end
		code = code + b
		local count = h.count[len] or 0
		if code - count < first then
			local sym = h.symbol[index + (code - first)]
			if sym == nil then return nil, "invalid Huffman symbol" end
			return sym
		end
		index = index + count
		first = (first + count) * 2
		code = code * 2
	end
	return nil, "ran out of Huffman codes"
end

local LEN_BASE = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
local LEN_EXTRA = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
local DIST_BASE = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
local DIST_EXTRA = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}

local function inflate_block_data(s, out, lencode, distcode)
	while true do
		local sym, err = decode_sym(s, lencode)
		if not sym then return nil, err end
		if sym < 256 then
			out[#out + 1] = char(sym)
		elseif sym == 256 then
			return out
		else
			sym = sym - 256
			if sym < 1 or sym > 29 then return nil, "invalid length symbol" end
			local extra = LEN_EXTRA[sym] or 0
			local len = LEN_BASE[sym]
			if extra > 0 then
				local v, e = bits(s, extra)
				if not v then return nil, e end
				len = len + v
			end

			local dsym, derr = decode_sym(s, distcode)
			if not dsym then return nil, derr end
			if dsym < 0 or dsym > 29 then return nil, "invalid distance symbol" end
			local dextra = DIST_EXTRA[dsym + 1] or 0
			local dist = DIST_BASE[dsym + 1]
			if dextra > 0 then
				local v, e = bits(s, dextra)
				if not v then return nil, e end
				dist = dist + v
			end
			if dist > #out then return nil, "distance too far back" end
			local start = #out - dist
			for i = 0, len - 1 do
				out[#out + 1] = out[start + i + 1]
			end
		end
	end
end

local function fixed_tables()
	local lengths = {}
	for i = 1, 144 do lengths[i] = 8 end
	for i = 145, 256 do lengths[i] = 9 end
	for i = 257, 280 do lengths[i] = 7 end
	for i = 281, 288 do lengths[i] = 8 end
	local lencode = build_huffman(lengths, 288)
	local dlengths = {}
	for i = 1, 30 do dlengths[i] = 5 end
	local distcode = build_huffman(dlengths, 30)
	return lencode, distcode
end

local FIXED_LEN, FIXED_DIST = fixed_tables()

local ORDER = {17,18,19,16,17 + 0} -- placeholder replaced below
-- RFC 1951 3.2.7 code-length alphabet ordering
local CL_ORDER = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}

local function inflate_block_dynamic(s, out)
	local hlit, err = bits(s, 5) if not hlit then return nil, err end
	local hdist; hdist, err = bits(s, 5) if not hdist then return nil, err end
	local hclen; hclen, err = bits(s, 4) if not hclen then return nil, err end
	hlit, hdist, hclen = hlit + 257, hdist + 1, hclen + 4

	local lengths = {}
	for i = 1, 19 do lengths[i] = 0 end
	for i = 1, hclen do
		local v, e = bits(s, 3)
		if not v then return nil, e end
		lengths[CL_ORDER[i] + 1] = v
	end
	local clcode, cerr = build_huffman(lengths, 19)
	if not clcode then return nil, cerr end

	local total = hlit + hdist
	local lens = {}
	local i = 1
	while i <= total do
		local sym, e = decode_sym(s, clcode)
		if not sym then return nil, e end
		if sym < 16 then
			lens[i] = sym
			i = i + 1
		else
			local repeat_count, value
			if sym == 16 then
				if i == 1 then return nil, "repeat with no previous length" end
				value = lens[i - 1]
				local v, e2 = bits(s, 2)
				if not v then return nil, e2 end
				repeat_count = 3 + v
			elseif sym == 17 then
				value = 0
				local v, e2 = bits(s, 3)
				if not v then return nil, e2 end
				repeat_count = 3 + v
			else
				value = 0
				local v, e2 = bits(s, 7)
				if not v then return nil, e2 end
				repeat_count = 11 + v
			end
			if i + repeat_count - 1 > total then
				return nil, "code length repeat overruns"
			end
			for _ = 1, repeat_count do
				lens[i] = value
				i = i + 1
			end
		end
	end

	local litlens = {}
	for j = 1, hlit do litlens[j] = lens[j] end
	local distlens = {}
	for j = 1, hdist do distlens[j] = lens[hlit + j] end

	local lencode, lerr = build_huffman(litlens, hlit)
	if not lencode then return nil, lerr end
	local distcode, derr = build_huffman(distlens, hdist)
	if not distcode then return nil, derr end

	return inflate_block_data(s, out, lencode, distcode)
end

--- Inflate a raw DEFLATE stream. Returns the decompressed string.
function zip.inflate(data)
	local s = bitreader(data)
	local out = {}
	while true do
		local final, err = bits(s, 1)
		if not final then return nil, err end
		local btype; btype, err = bits(s, 2)
		if not btype then return nil, err end

		if btype == 0 then
			-- stored: discard to byte boundary
			local drop = s.bitcnt % 8
			if drop > 0 then
				local v, e = bits(s, drop)
				if not v then return nil, e end
			end
			local len = u16(s.data, s.pos)
			local nlen = u16(s.data, s.pos + 2)
			if band(bxor(len, nlen), 0xFFFF) ~= 0xFFFF then
				return nil, "stored block length check failed"
			end
			s.pos = s.pos + 4
			local chunk = sub(s.data, s.pos, s.pos + len - 1)
			if #chunk ~= len then return nil, "stored block truncated" end
			out[#out + 1] = chunk
			s.pos = s.pos + len
		elseif btype == 1 then
			local okb, e = inflate_block_data(s, out, FIXED_LEN, FIXED_DIST)
			if not okb then return nil, e end
		elseif btype == 2 then
			local okb, e = inflate_block_dynamic(s, out)
			if not okb then return nil, e end
		else
			return nil, "invalid deflate block type"
		end

		if final == 1 then break end
	end
	return table.concat(out)
end

--- Decompress a zlib stream (2-byte header + deflate + adler32).
function zip.inflate_zlib(data)
	if #data < 6 then return nil, "zlib stream too short" end
	local cmf, flg = byte(data, 1), byte(data, 2)
	if band(cmf, 0x0F) ~= 8 then return nil, "not a zlib stream" end
	if (cmf * 256 + flg) % 31 ~= 0 then return nil, "bad zlib header check" end
	if band(flg, 0x20) ~= 0 then return nil, "zlib preset dictionary unsupported" end
	return zip.inflate(sub(data, 3))
end

-- ---------------------------------------------------------------------------
-- ZIP container
-- ---------------------------------------------------------------------------

local EOCD_SIG    = 0x06054b50
local CD_SIG      = 0x02014b50
local LOCAL_SIG   = 0x04034b50

local ZipFile = {}
ZipFile.__index = ZipFile

--- Open a zip file from disk. Returns a handle or nil, err.
function zip.open(path)
	local fh, ferr = io.open(path, "rb")
	if not fh then return nil, "cannot open " .. tostring(path) .. ": " .. tostring(ferr) end
	local data = fh:read("*a")
	fh:close()
	if not data or #data < 22 then return nil, "file too small to be a zip" end

	-- Find the end-of-central-directory record, scanning back over the comment.
	local eocd
	local lowest = math.max(1, #data - 65557)
	for i = #data - 21, lowest, -1 do
		if u32(data, i) == EOCD_SIG then
			eocd = i
			break
		end
	end
	if not eocd then return nil, "no end-of-central-directory record (not a zip?)" end

	local total_entries = u16(data, eocd + 10)
	local cd_size = u32(data, eocd + 12)
	local cd_offset = u32(data, eocd + 16)

	local self = setmetatable({
		data = data,
		path = path,
		entries = {},   -- name -> {offset, csize, usize, method}
		order = {},
		comment = sub(data, eocd + 22, eocd + 21 + u16(data, eocd + 20)),
	}, ZipFile)

	local p = cd_offset + 1
	for _ = 1, total_entries do
		if u32(data, p) ~= CD_SIG then
			return nil, "corrupt central directory"
		end
		local method = u16(data, p + 10)
		local csize = u32(data, p + 20)
		local usize = u32(data, p + 24)
		local name_len = u16(data, p + 28)
		local extra_len = u16(data, p + 30)
		local comment_len = u16(data, p + 32)
		local local_off = u32(data, p + 42)
		local name = sub(data, p + 46, p + 45 + name_len)

		self.entries[name] = {
			offset = local_off, csize = csize, usize = usize, method = method,
		}
		self.order[#self.order + 1] = name

		p = p + 46 + name_len + extra_len + comment_len
	end

	return self
end

function ZipFile:names()
	return self.order
end

function ZipFile:exists(name)
	return self.entries[name] ~= nil
end

--- Read and decompress one entry. Returns the bytes, or nil, err.
function ZipFile:read(name)
	local e = self.entries[name]
	if not e then return nil, "no such entry: " .. tostring(name) end
	local data = self.data
	local p = e.offset + 1
	if u32(data, p) ~= LOCAL_SIG then return nil, "bad local header for " .. name end
	local name_len = u16(data, p + 26)
	local extra_len = u16(data, p + 28)
	local start = p + 30 + name_len + extra_len
	local raw = sub(data, start, start + e.csize - 1)
	if #raw ~= e.csize then return nil, "truncated entry " .. name end

	if e.method == 0 then
		return raw
	elseif e.method == 8 then
		local out, err = zip.inflate(raw)
		if not out then return nil, "inflate failed for " .. name .. ": " .. tostring(err) end
		return out
	elseif e.method == 12 then
		return nil, "bzip2 entries are not supported (" .. name .. ")"
	else
		return nil, "unsupported compression method " .. e.method .. " (" .. name .. ")"
	end
end

--- Read an entry as UTF-8 text with BOM handling.
function ZipFile:read_text(name)
	local bytes, err = self:read(name)
	if not bytes then return nil, err end
	if sub(bytes, 1, 3) == "\239\187\191" then bytes = sub(bytes, 4) end
	return bytes
end

return zip
