VERSION = "0.7.2"

-- shinny: web search (Tavily or DeepSeek) for the selection, plus a per-file
-- LLM chat that can edit the buffer you are working in.
-- Run `> help shinny` inside micro for the fine print.

local micro = import("micro")
local config = import("micro/config")
local buffer = import("micro/buffer")
local shell = import("micro/shell")
local util = import("micro/util")
local os = import("os")
local strings = import("strings")
local ioutil = import("io/ioutil")
local fmt = import("fmt")

local DEFAULT_ENDPOINT = "https://api.tavily.com/search"
local DEFAULT_DS_SEARCH = "https://api.deepseek.com/v1/tools/search"
local DEFAULT_DS_CHAT = "https://api.deepseek.com/chat/completions"
local DEFAULT_MODEL = "deepseek-flash"
local DEFAULT_EFFORT = "high"
local DEFAULT_DEPTH = "basic"
local DEFAULT_PREFIX = "什么是"
local MAX_QUERY_BYTES = 380
local MAX_DS_QUERY_CHARS = 128
local MAX_SNIPPET_BYTES = 480
local STATUS_MARKER = "__SHINNY_STATUS__"
local CHAT_PREFIX = "shinny chat · "
local CHAT_INPUT_PREFIX = "shinny chat input · "
local INPUT_PROMPT = "> "
local STATE_PATH = config.ConfigDir .. "/shinny.json"

-- `shinny-prefix`, `shinny-suffix` and `shinny-backend` persist here.
local runtime = {
	prefix = DEFAULT_PREFIX,
	suffix = "",
	backend = "tavily",
	model = DEFAULT_MODEL,
	thinking = true,
	effort = DEFAULT_EFFORT,
	loaded = false,
}

-- The raw body of the last request, for `> shinny-raw`.
local last_response = nil
local last_query = ""
-- Rendered results of the last search, shown to the chat as context.
local last_search_text = ""
local last_search_query = ""

-- Per-file chat state, keyed by the chat buffer name.
local chats = {}
local chats_by_input = {}
local chats_by_key = {}
local TICK = 0
local WATCHDOG_STARTED = false
local PROCESS_TOKEN = (tostring({}):match("0x(%x+)") or tostring(math.random(100000, 999999)))

local function tostr(v)
	if v == nil then
		return ""
	end
	if type(v) == "boolean" then
		return v and "true" or "false"
	end
	return tostring(v)
end

local function trim(s)
	return strings.TrimSpace(tostr(s))
end

local function collapse(s)
	return (trim((tostr(s):gsub("%s+", " "))))
end

-- utf8_prefix returns the longest prefix of s that is no longer than limit
-- bytes and does not end in the middle of a multibyte character.
local function utf8_prefix(s, limit)
	if #s <= limit then
		return s
	end
	local cut = s:sub(1, limit)
	local i = #cut
	while i > 0 do
		local b = cut:byte(i)
		if b < 0x80 or b >= 0xC0 then
			break
		end
		i = i - 1
	end
	if i == 0 then
		return cut
	end
	local lead = cut:byte(i)
	local width = 1
	if lead >= 0xF0 then
		width = 4
	elseif lead >= 0xE0 then
		width = 3
	elseif lead >= 0xC0 then
		width = 2
	end
	if #cut - i + 1 < width then
		return cut:sub(1, i - 1)
	end
	return cut
end

local function clamp(s, limit)
	s = tostr(s)
	if #s <= limit then
		return s
	end
	local cut = utf8_prefix(s, limit)
	cut = cut:gsub("%s+%S*$", "")
	if cut == "" then
		cut = utf8_prefix(s, limit)
	end
	return cut
end

local function shorten(s, limit)
	s = tostr(s)
	if #s <= limit then
		return s
	end
	return clamp(s, limit) .. "…"
end

-- utf8_sub keeps at most maxchars characters (not bytes).
local function utf8_sub(s, maxchars)
	s = tostr(s)
	local n = 0
	for i = 1, #s do
		local b = s:byte(i)
		if b < 0x80 or b >= 0xC0 then
			n = n + 1
			if n > maxchars then
				return utf8_prefix(s, i - 1)
			end
		end
	end
	return s
end

local JSON_ESCAPES = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function json_escape(s)
	return (tostr(s):gsub('[%c"\\]', function(c)
		local esc = JSON_ESCAPES[c]
		if esc then
			return esc
		end
		return string.format("\\u%04x", c:byte())
	end))
end

local function utf8_char(code)
	if code < 0x80 then
		return string.char(code)
	elseif code < 0x800 then
		return string.char(
			0xC0 + math.floor(code / 0x40),
			0x80 + (code % 0x40)
		)
	elseif code < 0x10000 then
		return string.char(
			0xE0 + math.floor(code / 0x1000),
			0x80 + (math.floor(code / 0x40) % 0x40),
			0x80 + (code % 0x40)
		)
	end
	return string.char(
		0xF0 + math.floor(code / 0x40000),
		0x80 + (math.floor(code / 0x1000) % 0x40),
		0x80 + (math.floor(code / 0x40) % 0x40),
		0x80 + (code % 0x40)
	)
end

-- join_pieces concatenates in small batches: gopher-lua's table.concat
-- overflows its registry when given thousands of elements at once.
local function join_pieces(pieces)
	if #pieces <= 128 then
		return table.concat(pieces)
	end
	local chunks = {}
	for i = 1, #pieces, 128 do
		local part = {}
		for j = i, math.min(i + 127, #pieces) do
			part[#part + 1] = pieces[j]
		end
		chunks[#chunks + 1] = table.concat(part)
	end
	return table.concat(chunks)
end

-- json_decode is a small JSON reader so the plugin does not depend on a
-- json library. It is only used on API responses and the state file.
local function json_decode(input)
	local s = tostr(input)
	if s:sub(1, 3) == "\239\187\191" then
		s = s:sub(4)
	end
	local pos = 1
	local len = #s

	local function fail(msg)
		error(string.format("invalid JSON near byte %d: %s", pos, msg), 0)
	end

	local function skip_ws()
		while pos <= len do
			local b = s:byte(pos)
			if b == 32 or b == 9 or b == 10 or b == 13 then
				pos = pos + 1
			else
				break
			end
		end
	end

	local function parse_string()
		pos = pos + 1 -- opening quote
		local pieces = {}
		while true do
			local run = s:match('^[^"\\]+', pos)
			if run then
				pieces[#pieces + 1] = run
				pos = pos + #run
			end
			local c = s:sub(pos, pos)
			if c == "" then
				fail("unterminated string")
			elseif c == '"' then
				pos = pos + 1
				return join_pieces(pieces)
			elseif c == "\\" then
				local esc = s:sub(pos + 1, pos + 1)
				pos = pos + 2
				if esc == '"' or esc == "\\" or esc == "/" then
					pieces[#pieces + 1] = esc
				elseif esc == "b" then
					pieces[#pieces + 1] = "\b"
				elseif esc == "f" then
					pieces[#pieces + 1] = "\f"
				elseif esc == "n" then
					pieces[#pieces + 1] = "\n"
				elseif esc == "r" then
					pieces[#pieces + 1] = "\r"
				elseif esc == "t" then
					pieces[#pieces + 1] = "\t"
				elseif esc == "u" then
					local hex = s:sub(pos, pos + 3)
					if not hex:match("^%x%x%x%x$") then
						fail("bad \\u escape")
					end
					local code = tonumber(hex, 16)
					pos = pos + 4
					if code >= 0xD800 and code <= 0xDBFF and s:sub(pos, pos + 5):match("^\\u%x%x%x%x$") then
						local low = tonumber(s:sub(pos + 2, pos + 5), 16)
						if low >= 0xDC00 and low <= 0xDFFF then
							code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
							pos = pos + 6
						end
					end
					pieces[#pieces + 1] = utf8_char(code)
				else
					fail("bad escape")
				end
			else
				pieces[#pieces + 1] = c
				pos = pos + 1
			end
		end
	end

	local function parse_number()
		local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
		if not num or num == "" then
			fail("bad number")
		end
		pos = pos + #num
		local n = tonumber(num)
		if n == nil then
			fail("bad number")
		end
		return n
	end

	local parse_value

	local function parse_array()
		pos = pos + 1
		local arr = {}
		skip_ws()
		if s:sub(pos, pos) == "]" then
			pos = pos + 1
			return arr
		end
		while true do
			skip_ws()
			arr[#arr + 1] = parse_value()
			skip_ws()
			local c = s:sub(pos, pos)
			if c == "," then
				pos = pos + 1
			elseif c == "]" then
				pos = pos + 1
				return arr
			else
				fail("expected ',' or ']'")
			end
		end
	end

	local function parse_object()
		pos = pos + 1
		local obj = {}
		skip_ws()
		if s:sub(pos, pos) == "}" then
			pos = pos + 1
			return obj
		end
		while true do
			skip_ws()
			if s:sub(pos, pos) ~= '"' then
				fail("expected object key")
			end
			local key = parse_string()
			skip_ws()
			if s:sub(pos, pos) ~= ":" then
				fail("expected ':'")
			end
			pos = pos + 1
			skip_ws()
			obj[key] = parse_value()
			skip_ws()
			local c = s:sub(pos, pos)
			if c == "," then
				pos = pos + 1
			elseif c == "}" then
				pos = pos + 1
				return obj
			else
				fail("expected ',' or '}'")
			end
		end
	end

	function parse_value()
		skip_ws()
		if pos > len then
			fail("unexpected end of input")
		end
		local c = s:sub(pos, pos)
		if c == "{" then
			return parse_object()
		elseif c == "[" then
			return parse_array()
		elseif c == '"' then
			return parse_string()
		elseif c == "t" and s:sub(pos, pos + 3) == "true" then
			pos = pos + 4
			return true
		elseif c == "f" and s:sub(pos, pos + 4) == "false" then
			pos = pos + 5
			return false
		elseif c == "n" and s:sub(pos, pos + 3) == "null" then
			pos = pos + 4
			return nil
		end
		return parse_number()
	end

	skip_ws()
	local value = parse_value()
	skip_ws()
	if pos <= len then
		fail("trailing data")
	end
	return value
end

local function option(name, default)
	local v = config.GetGlobalOption("shinny." .. name)
	if v == nil then
		return default
	end
	return v
end

local function option_number(name, default)
	local n = tonumber(tostr(option(name, default)))
	if n == nil then
		return default
	end
	return n
end

local function option_bool(name, default)
	local v = option(name, default)
	if type(v) == "boolean" then
		return v
	end
	local s = tostr(v)
	return s == "true" or s == "on" or s == "1" or s == "yes"
end

local function current_prefix()
	return tostr(option("prefix", DEFAULT_PREFIX))
end

local function current_suffix()
	return tostr(option("suffix", ""))
end

local function current_backend()
	local b = trim(tostr(option("backend", "tavily")))
	if b ~= "deepseek" then
		return "tavily"
	end
	return "deepseek"
end

-- ---------------------------------------------------------------------------
-- state file
-- ---------------------------------------------------------------------------

local function load_state()
	local ok, data = pcall(ioutil.ReadFile, STATE_PATH)
	if not ok or data == nil then
		return
	end
	local ok2, text = pcall(function()
		return fmt.Sprintf("%s", data)
	end)
	if not ok2 or trim(text) == "" then
		return
	end
	local ok3, obj = pcall(json_decode, text)
	if not ok3 or type(obj) ~= "table" then
		return
	end
	if type(obj.prefix) == "string" then
		runtime.prefix = obj.prefix
	end
	if type(obj.suffix) == "string" then
		runtime.suffix = obj.suffix
	end
	if type(obj.backend) == "string" and obj.backend ~= "" then
		runtime.backend = obj.backend
	end
	if type(obj.model) == "string" and obj.model ~= "" then
		runtime.model = obj.model
	end
	if type(obj.thinking) == "boolean" then
		runtime.thinking = obj.thinking
	elseif type(obj.thinking) == "string" then
		runtime.thinking = obj.thinking == "true"
	end
	if type(obj.effort) == "string" and obj.effort ~= "" then
		runtime.effort = obj.effort
	end
	runtime.loaded = true
end

local function save_state()
	local text = string.format(
		'{\n    "prefix": "%s",\n    "suffix": "%s",\n    "backend": "%s",\n    "model": "%s",\n    "thinking": %s,\n    "effort": "%s"\n}\n',
		json_escape(runtime.prefix),
		json_escape(runtime.suffix),
		json_escape(runtime.backend),
		json_escape(runtime.model),
		tostr(runtime.thinking),
		json_escape(runtime.effort)
	)
	local ok, err = pcall(ioutil.WriteFile, STATE_PATH, text, 384)
	if not ok then
		micro.InfoBar():Error("shinny: 无法保存 " .. STATE_PATH .. " — " .. tostr(err))
	end
end

local function apply_state()
	if not runtime.loaded then
		return
	end
	pcall(config.SetGlobalOption, "shinny.prefix", runtime.prefix)
	pcall(config.SetGlobalOption, "shinny.suffix", runtime.suffix)
	pcall(config.SetGlobalOption, "shinny.backend", runtime.backend)
	pcall(config.SetGlobalOption, "shinny.chatmodel", runtime.model)
	pcall(config.SetGlobalOption, "shinny.thinking", tostr(runtime.thinking))
	pcall(config.SetGlobalOption, "shinny.effort", runtime.effort)
end

local function set_setting(name, value, option_name)
	runtime[name] = value
	save_state()
	pcall(config.SetGlobalOption, "shinny." .. (option_name or name), tostr(value))
end

-- ---------------------------------------------------------------------------
-- small helpers over micro objects
-- ---------------------------------------------------------------------------

local function curl_cmd(timeout)
	return 'curl -sS --max-time ' .. tostring(timeout) .. ' -X POST "$SHINNY_ENDPOINT"'
		.. ' -H "Content-Type: application/json"'
		.. ' -H "Authorization: Bearer $SHINNY_KEY"'
		.. ' --data-binary "$SHINNY_BODY"'
		.. ' -w "\\n' .. STATUS_MARKER .. ':%{http_code}"'
end

local function split_output(output)
	output = tostr(output)
	local idx = output:find(STATUS_MARKER, 1, true)
	if not idx then
		return nil, trim(output)
	end
	local payload = trim(output:sub(1, idx - 1))
	local code = output:match(STATUS_MARKER .. ":(%d+)")
	if code == nil then
		return nil, payload
	end
	return tonumber(code), payload
end

local function error_detail(payload)
	local ok, data = pcall(json_decode, payload)
	if ok and type(data) == "table" then
		local detail = data.detail
		if type(detail) == "table" and detail.error ~= nil then
			return collapse(detail.error)
		elseif type(detail) == "string" then
			return collapse(detail)
		end
		if data.error ~= nil then
			if type(data.error) == "table" and data.error.message ~= nil then
				return collapse(data.error.message)
			end
			return collapse(data.error)
		end
		if data.message ~= nil then
			return collapse(data.message)
		end
	end
	return ""
end

local function selected_text(bp)
	if bp == nil then
		return ""
	end
	local ok, sel = pcall(function()
		return bp.Cursor:GetSelection()
	end)
	if not ok or sel == nil then
		return ""
	end
	if type(sel) == "string" then
		return trim(sel)
	end
	local ok2, text = pcall(util.String, sel)
	if not ok2 or text == nil then
		return ""
	end
	return trim(text)
end

local function join_args(args)
	if args == nil then
		return ""
	end
	local parts = {}
	for i = 1, #args do
		parts[#parts + 1] = tostr(args[i])
	end
	return table.concat(parts, " ")
end

local function is_chat_name(name)
	name = tostr(name)
	return name:sub(1, #CHAT_PREFIX) == CHAT_PREFIX
end

local function is_input_name(name)
	name = tostr(name)
	return name:sub(1, #CHAT_INPUT_PREFIX) == CHAT_INPUT_PREFIX
end

local function is_shinny_buffer(name)
	name = tostr(name)
	return name:sub(1, 6) == "shinny"
end

local function buffer_text(buf)
	local ok, n = pcall(function()
		return buf:LinesNum()
	end)
	if ok and type(n) == "number" and n > 0 then
		local lines = {}
		for i = 0, n - 1 do
			lines[#lines + 1] = buf:Line(i)
		end
		return table.concat(lines, "\n")
	end
	local lines = {}
	for i = 0, 5000 do
		local ok2, line = pcall(function()
			return buf:Line(i)
		end)
		if not ok2 then
			break
		end
		lines[#lines + 1] = line
	end
	return table.concat(lines, "\n")
end

local function set_filetype(buf, ft, softwrap)
	if buf == nil then
		return
	end
	pcall(function()
		buf:SetOption("filetype", ft)
	end)
	if softwrap then
		pcall(function()
			buf:SetOption("softwrap", "true")
		end)
	end
end

local function open_buffers()
	local list = {}
	local seen = {}
	pcall(function()
		local tabs = micro.Tabs()
		for i = 1, #tabs.List do
			local tab = tabs.List[i]
			for j = 1, #tab.Panes do
				local pane = tab.Panes[j]
				local okb, b = pcall(function()
					return pane.Buf
				end)
				if okb and b ~= nil then
					local okn, name = pcall(function()
						return b:GetName()
					end)
					if okn and name and not seen[name] and not is_shinny_buffer(name) then
						seen[name] = true
						list[#list + 1] = b
					end
				end
			end
		end
	end)
	return list
end

local function find_pane_by_name(name)
	name = tostr(name)
	local found = nil
	pcall(function()
		local tabs = micro.Tabs()
		for i = 1, #tabs.List do
			local tab = tabs.List[i]
			for j = 1, #tab.Panes do
				local pane = tab.Panes[j]
				local okb, b = pcall(function()
					return pane.Buf
				end)
				if okb and b ~= nil then
					local okn, n = pcall(function()
						return b:GetName()
					end)
					if okn and n == name then
						found = pane
						tabs:SetActive(i - 1)
						tab:SetActive(j - 1)
						return
					end
				end
			end
		end
	end)
	return found
end

-- ---------------------------------------------------------------------------
-- search
-- ---------------------------------------------------------------------------

local function api_key(backend_name)
	if backend_name == "deepseek" then
		local env = trim(os.Getenv("DEEPSEEK_API_KEY"))
		if env ~= "" then
			return env
		end
		return trim(tostr(option("deepseekkey", "")))
	end
	local env = trim(os.Getenv("TAVILY_API_KEY"))
	if env ~= "" then
		return env
	end
	return trim(tostr(option("apikey", "")))
end

local function search_options()
	local depth = trim(tostr(option("depth", DEFAULT_DEPTH)))
	if depth ~= "basic" and depth ~= "advanced" then
		depth = DEFAULT_DEPTH
	end
	local max_results = math.floor(option_number("maxresults", 5))
	if max_results < 1 then
		max_results = 1
	elseif max_results > 20 then
		max_results = 20
	end
	return {
		max_results = max_results,
		depth = depth,
		include_answer = option_bool("includeanswer", true),
	}
end

local function build_search(ctx)
	local opts = search_options()
	if ctx.backend == "deepseek" then
		local count = math.floor(option_number("maxresults", 5))
		if count < 1 then
			count = 1
		elseif count > 50 then
			count = 50
		end
		local q = utf8_sub(ctx.full, MAX_DS_QUERY_CHARS)
		ctx.count = count
		ctx.query = q
		ctx.endpoint = trim(tostr(option("deepseektoolsurl", DEFAULT_DS_SEARCH)))
		if ctx.endpoint == "" then
			ctx.endpoint = DEFAULT_DS_SEARCH
		end
		ctx.body = string.format(
			'{"query":"%s","count":%d,"need_content":false}',
			json_escape(q),
			count
		)
		return true
	end
	ctx.query = clamp(ctx.full, MAX_QUERY_BYTES)
	ctx.endpoint = trim(tostr(option("endpoint", DEFAULT_ENDPOINT)))
	if ctx.endpoint == "" then
		ctx.endpoint = DEFAULT_ENDPOINT
	end
	ctx.body = string.format(
		'{"query":"%s","max_results":%.0f,"include_answer":%s,"search_depth":"%s"}',
		json_escape(ctx.query),
		opts.max_results,
		opts.include_answer and "true" or "false",
		json_escape(opts.depth)
	)
	ctx.opts = opts
	return true
end

local function extract_results(backend_name, data)
	local out = {}
	local list = data.results
	if type(list) ~= "table" then
		return out
	end
	for _, r in ipairs(list) do
		if type(r) == "table" then
			local item = {
				title = collapse(r.title),
				url = trim(r.url),
				score = nil,
				site = nil,
			}
			if backend_name == "deepseek" then
				local snippet = trim(r.snippet)
				if snippet == "" then
					snippet = trim(r.summary)
				end
				item.snippet = collapse(snippet)
				if type(r.rerank_score) == "number" then
					item.score = r.rerank_score
				end
				if type(r.site_name) == "string" then
					item.site = r.site_name
				end
			else
				item.snippet = collapse(r.content)
				if type(r.score) == "number" then
					item.score = r.score
				end
			end
			out[#out + 1] = item
		end
	end
	return out
end

local function render_search(ctx, data)
	local out = {}
	local function add(line)
		out[#out + 1] = line
	end

	local results = extract_results(ctx.backend, data)
	local meta = string.format("%s · %d result(s)", ctx.backend, #results)
	if ctx.backend == "tavily" then
		meta = meta .. " · " .. ctx.opts.depth
	end
	if type(data.response_time) == "number" then
		meta = meta .. string.format(" · %.2fs", data.response_time)
	end

	add("shinny · " .. collapse(ctx.full))
	add(meta)
	add(string.format(
		"前缀「%s」 · 后缀「%s」",
		ctx.prefix == "" and "无" or ctx.prefix,
		ctx.suffix == "" and "无" or ctx.suffix
	))
	add("")

	if ctx.backend == "tavily" and ctx.opts.include_answer and type(data.answer) == "string" and trim(data.answer) ~= "" then
		add("Answer")
		add(collapse(data.answer))
		add("")
	end

	if #results == 0 then
		add("No results.")
		return table.concat(out, "\n")
	end

	for i, r in ipairs(results) do
		add(string.format("%d. %s", i, r.title ~= "" and r.title or "(untitled)"))
		if r.url ~= "" then
			add("   " .. r.url)
		end
		if r.snippet ~= "" then
			add("   " .. shorten(r.snippet, MAX_SNIPPET_BYTES))
		end
		if r.site ~= nil and r.site ~= "" then
			add("   site: " .. r.site)
		end
		if type(r.score) == "number" then
			add(string.format("   score: %.3f", r.score))
		end
		add("")
	end

	return table.concat(out, "\n")
end

local SEARCH_TAB_NAME = "shinny: search results"

local function find_tab_with_buffer(name)
	local tabs = micro.Tabs()
	for i = 1, #tabs.List do
		local tab = tabs.List[i]
		local count = 1
		pcall(function()
			count = #tab.Panes
		end)
		for j = 1, count do
			local pane = tab.Panes[j]
			if pane ~= nil then
				local bufname = ""
				pcall(function()
					bufname = tostr(pane.Buf:GetName())
				end)
				if bufname == name then
					return tabs, i, pane.Buf
				end
			end
		end
	end
	return nil
end

local function fill_results_buffer(buf, text)
	local n = 0
	pcall(function()
		n = buf:LinesNum()
	end)
	if n > 0 then
		local last = ""
		pcall(function()
			last = tostr(buf:Line(n - 1))
		end)
		pcall(function()
			buf:Remove(buffer.Loc(0, 0), buffer.Loc(#last, n - 1))
		end)
	end
	buf:Insert(buffer.Loc(0, 0), text)
	pcall(function()
		buf:SetName(SEARCH_TAB_NAME)
	end)
	set_filetype(buf, "shinnyresults", true)
end

local function show_results(ctx, text)
	local bp = micro.CurPane()
	if bp == nil then
		micro.InfoBar():Error("shinny: no pane to show the results in")
		return
	end

	local tabs, idx, buf = find_tab_with_buffer(SEARCH_TAB_NAME)
	if buf ~= nil then
		fill_results_buffer(buf, text)
		pcall(function()
			tabs:SetActive(idx - 1)
		end)
		micro.InfoBar():Message("shinny: 搜索结果已更新")
		return
	end

	local ok = pcall(function()
		bp:AddTab()
	end)
	if ok then
		tabs = micro.Tabs()
		local tab = tabs.List[#tabs.List]
		local pane = tab and tab.Panes[1]
		if pane ~= nil and pane.Buf ~= nil then
			fill_results_buffer(pane.Buf, text)
			micro.InfoBar():Message("shinny: 搜索结果已打开")
			return
		end
	end

	-- fallback for older micro: reuse one split
	local pane = find_pane_by_name(SEARCH_TAB_NAME)
	if pane == nil then
		local b = buffer.NewBuffer("", "")
		b:SetName(SEARCH_TAB_NAME)
		set_filetype(b, "shinnyresults", true)
		pane = bp:VSplitBuf(b)
	end
	if pane ~= nil and pane.Buf ~= nil then
		fill_results_buffer(pane.Buf, text)
		micro.InfoBar():Message("shinny: 搜索结果已更新")
	end
end

local function finish_search(ctx, output)
	local status, payload = split_output(output)
	last_query = ctx.full
	last_response = payload

	if status == nil then
		if trim(payload) == "" then
			micro.InfoBar():Error("shinny: curl produced no output — is curl installed?")
		else
			micro.InfoBar():Error("shinny: could not run curl — " .. shorten(collapse(payload), 140))
		end
		return
	end
	if status == 0 then
		micro.InfoBar():Error("shinny: could not reach " .. ctx.backend .. " — check your network")
		return
	end
	if status < 200 or status >= 300 then
		local detail = error_detail(payload)
		if detail == "" then
			detail = "HTTP " .. tostr(status)
		end
		micro.InfoBar():Error("shinny: " .. shorten(detail, 160))
		return
	end
	if trim(payload) == "" then
		micro.InfoBar():Error(string.format("shinny: empty response (%s, HTTP %d) — > shinny-raw", ctx.backend, status))
		return
	end
	local ok, data = pcall(json_decode, payload)
	if not ok then
		micro.InfoBar():Error("shinny: bad JSON — " .. shorten(collapse(data), 70) .. " — > shinny-raw")
		return
	end
	if type(data) ~= "table" then
		micro.InfoBar():Error("shinny: unexpected response (" .. type(data) .. ") — > shinny-raw")
		return
	end
	if data.error ~= nil and ctx.backend == "tavily" then
		micro.InfoBar():Error("shinny: " .. shorten(collapse(data.error), 160))
		return
	end

	local text = render_search(ctx, data)
	last_search_text = text
	last_search_query = ctx.full
	show_results(ctx, text)

	local count = 0
	if type(data.results) == "table" then
		count = #data.results
	end
	micro.InfoBar():Message(string.format("shinny: %s · %d result(s)", ctx.backend, count))
end

local function start_search(base)
	local backend_name = current_backend()
	local key = api_key(backend_name)
	if key == "" then
		if backend_name == "deepseek" then
			micro.InfoBar():Error("shinny: 没有 DeepSeek key — 运行 > set shinny.deepseekkey <key>")
		else
			micro.InfoBar():Error("shinny: 没有 Tavily key — 运行 > set shinny.apikey <key>")
		end
		return
	end

	local ctx = {
		base = base,
		prefix = current_prefix(),
		suffix = current_suffix(),
		backend = backend_name,
	}
	ctx.full = ctx.prefix .. base .. ctx.suffix
	build_search(ctx)

	os.Setenv("SHINNY_ENDPOINT", ctx.endpoint)
	os.Setenv("SHINNY_KEY", key)
	os.Setenv("SHINNY_BODY", ctx.body)

	local ok, err = pcall(shell.JobStart, curl_cmd(45), nil, nil, function(output)
		os.Setenv("SHINNY_KEY", "")
		os.Setenv("SHINNY_BODY", "")
		local ran, problem = pcall(finish_search, ctx, output)
		if not ran then
			micro.InfoBar():Error("shinny: internal error — " .. shorten(collapse(problem), 140))
		end
	end)

	if not ok then
		os.Setenv("SHINNY_KEY", "")
		os.Setenv("SHINNY_BODY", "")
		micro.InfoBar():Error("shinny: " .. shorten(collapse(err), 160))
		return
	end

	micro.InfoBar():Message(string.format(
		"shinny: %s「%s」 (前缀「%s」 后缀「%s」)",
		ctx.backend,
		shorten(ctx.full, 60),
		ctx.prefix == "" and "无" or ctx.prefix,
		ctx.suffix == "" and "无" or ctx.suffix
	))
end

-- ---------------------------------------------------------------------------
-- chat context
-- ---------------------------------------------------------------------------

local function build_context(chat)
	local parts = {}
	local function add(line)
		parts[#parts + 1] = line
	end

	add("你是运行在 micro 编辑器里的编程助手。用户正在编辑文件，你可以看到下面列出的上下文。")
	add("回答用中文，简洁、直接。")

	local src = chat.src_pane
	local src_name = nil
	if src ~= nil then
		local ok = pcall(function()
			src_name = src.Buf:GetName()
		end)
		if not ok then
			src = nil
			src_name = nil
		end
	end

	if src_name then
		add("")
		add("当前文件: " .. src_name)
		add(string.format("光标位置: 第 %d 行, 第 %d 列", src.Cursor.Y + 1, src.Cursor.X + 1))
		local okline, line = pcall(function()
			return src.Buf:Line(src.Cursor.Y)
		end)
		if okline then
			add("光标所在行: " .. line)
		end
		local selection = selected_text(src)
		if selection ~= "" then
			add("选中文本:")
			add(utf8_prefix(selection, 3000))
		else
			add("选中文本: （无）")
		end
	end

	if last_search_text ~= "" then
		add("")
		add("最近一次搜索结果（查询「" .. last_search_query .. "」）:")
		add(utf8_prefix(last_search_text, 6000))
	end

	add("")
	add("打开的文件:")
	local budget = option_number("chatcontext", 24000)
	local used = 0
	local files = open_buffers()
	for _, b in ipairs(files) do
		if used >= budget then
			break
		end
		local name = "?"
		pcall(function()
			name = b:GetName()
		end)
		local text = buffer_text(b)
		local cap = budget - used
		if name == src_name then
			cap = math.min(cap, 12000)
		else
			cap = math.min(cap, 4000)
		end
		if #text > cap then
			text = utf8_prefix(text, cap) .. "\n…（已截断）"
		end
		used = used + #text
		add("")
		add("### 文件: " .. name .. (name == src_name and "（当前文件）" or ""))
		add(text)
	end

	add("")
	add("修改文件的规则：")
	add("当用户要求修改当前文件时，在回答里嵌入下面格式的块（可以有多个）：")
	add("<<<SHINNY_EDIT selection>>>")
	add("替换当前选区的新文本")
	add("<<<SHINNY_EDIT_END>>>")
	add("target 可以是 selection（替换选区）、cursor（插入到光标处）、line（替换光标所在行）。")
	add("编辑块不要放在 markdown 代码围栏里；不需要修改文件时不要输出编辑块。")

	return table.concat(parts, "\n")
end

-- ---------------------------------------------------------------------------
-- chat edits
-- ---------------------------------------------------------------------------

local function valid_pane(pane)
	if pane == nil then
		return false
	end
	local ok = pcall(function()
		local _ = pane.Buf:GetName()
	end)
	return ok
end

local function apply_edit(chat, target, text)
	local pane = chat.src_pane
	if not valid_pane(pane) then
		return false, "原文件已关闭，无法修改"
	end
	local buf = pane.Buf
	local ok, result = pcall(function()
		local cur = buf:GetActiveCursor()
		if target == "selection" then
			local had = cur:HasSelection()
			if had then
				cur:DeleteSelection()
				cur:ResetSelection()
			end
			buf:Insert(buffer.Loc(cur.X, cur.Y), text)
			if had then
				return "已替换选区"
			end
			return "没有选区，已插入到光标处"
		elseif target == "cursor" then
			buf:Insert(buffer.Loc(cur.X, cur.Y), text)
			return "已在光标处插入"
		elseif target == "line" then
			local y = cur.Y
			local line = buf:Line(y)
			buf:Remove(buffer.Loc(0, y), buffer.Loc(#line, y))
			buf:Insert(buffer.Loc(0, y), text)
			return string.format("已替换第 %d 行", y + 1)
		end
		error("unknown target: " .. tostr(target), 0)
	end)
	if not ok then
		return false, tostr(result)
	end
	return true, tostr(result)
end

-- apply_edits strips edit blocks out of the model response and applies them.
local function apply_edits(chat, response)
	response = tostr(response):gsub("\r\n", "\n")
	local notes = {}

	local function handle(target, text)
		text = text:gsub("^\n", "")
		local ok, note = apply_edit(chat, target, text)
		if ok then
			notes[#notes + 1] = note
		else
			notes[#notes + 1] = "修改失败（" .. target .. "）：" .. note
		end
		return ""
	end

	local cleaned = response:gsub(
		"<<<SHINNY_EDIT%s*([%a_]+)%s*>>>\n?(.-)\n?<<<SHINNY_EDIT_END>>>",
		handle
	)
	cleaned = cleaned:gsub("<<<SHINNY_EDIT.-SHINNY_EDIT_END>>>", "")

	return trim(cleaned), notes
end

-- ---------------------------------------------------------------------------
-- chat
-- ---------------------------------------------------------------------------

local function chat_label(name)
	name = tostr(name)
	if name == "" or name == "No name" then
		return "untitled"
	end
	return name:match("([^/\\]+)$") or name
end

local chat_settings

local function normalize_effort(value)
	value = trim(tostr(value)):lower()
	if value == "minimal" then
		return "low"
	elseif value == "medium" or value == "xhigh" then
		return "high"
	end
	if value ~= "low" and value ~= "high" and value ~= "max" then
		return DEFAULT_EFFORT
	end
	return value
end

function chat_settings()
	local model = trim(tostr(option("chatmodel", DEFAULT_MODEL)))
	if model == "" then
		model = DEFAULT_MODEL
	end
	return {
		model = model,
		thinking = option_bool("thinking", true),
		effort = normalize_effort(option("effort", DEFAULT_EFFORT)),
	}
end

local function est_tokens(s)
	s = tostr(s)
	local cjk = 0
	for i = 1, #s do
		if s:byte(i) >= 0xE0 then
			cjk = cjk + 1
		end
	end
	local rest = #s - cjk * 3
	if rest < 0 then
		rest = 0
	end
	return cjk + math.ceil(rest / 4)
end

local function fmt_tokens(n)
	n = tonumber(n) or 0
	if n >= 1000 then
		return string.format("%.1fk", n / 1000)
	end
	return tostring(math.floor(n))
end

local function encode_json(v)
	local t = type(v)
	if t == "string" then
		return '"' .. json_escape(v) .. '"'
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			return "null"
		end
		if v == math.floor(v) and math.abs(v) < 1e15 then
			return string.format("%.0f", v)
		end
		return string.format("%.10g", v)
	elseif t == "boolean" then
		return v and "true" or "false"
	elseif t == "table" then
		local n = #v
		if n > 0 then
			local parts = {}
			for i = 1, n do
				parts[#parts + 1] = encode_json(v[i])
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts = {}
		for k, val in pairs(v) do
			if type(k) == "string" then
				parts[#parts + 1] = '"' .. json_escape(k) .. '":' .. encode_json(val)
			end
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "null"
end

local function chat_dir()
	return config.ConfigDir .. "/shinny/chats"
end

local function hash_key(key)
	local sum = 0
	for i = 1, #key do
		sum = (sum * 31 + key:byte(i)) % 1000000007
	end
	return sum
end

local function chat_file(chat)
	local base = tostr(chat.label):gsub("[^%w_.-]", "_")
	return chat_dir() .. "/" .. base .. "-" .. tostring(hash_key(chat.key)) .. ".json"
end

local function save_chat(chat)
	local data = {
		version = 1,
		key = chat.key,
		usage = chat.usage or {},
		messages = chat.messages,
	}
	local ok, text = pcall(encode_json, data)
	if not ok then
		return
	end
	pcall(os.MkdirAll, chat_dir(), 448)
	pcall(ioutil.WriteFile, chat_file(chat), text, 384)
end

local function load_chat(chat)
	local ok, data = pcall(ioutil.ReadFile, chat_file(chat))
	if not ok or data == nil then
		return
	end
	local ok2, text = pcall(function()
		return fmt.Sprintf("%s", data)
	end)
	if not ok2 then
		return
	end
	local ok3, obj = pcall(json_decode, text)
	if not ok3 or type(obj) ~= "table" then
		return
	end
	if type(obj.messages) == "table" then
		local msgs = {}
		for _, m in ipairs(obj.messages) do
			if type(m) == "table" and type(m.role) == "string" then
				msgs[#msgs + 1] = m
			end
		end
		chat.messages = msgs
	end
	if type(obj.usage) == "table" then
		chat.usage = obj.usage
	end
end

local function text_end_loc(text)
	text = tostr(text)
	if text == "" then
		return buffer.Loc(0, 0)
	end
	local y, last = 0, 0
	for p in text:gmatch("\n()") do
		y = y + 1
		last = p
	end
	return buffer.Loc(#text - last, y)
end

local function scroll_chat(chat)
	if chat.pane == nil then
		return
	end
	local loc = text_end_loc(chat.text)
	loc = buffer.Loc(0, loc.Y)
	pcall(function()
		chat.pane:GotoLoc(loc)
	end)
end

local function buffer_end_loc(buf)
	local ok, n = pcall(function()
		return buf:LinesNum()
	end)
	if ok and type(n) == "number" and n > 0 then
		local last = buf:Line(n - 1)
		return buffer.Loc(#last, n - 1)
	end
	return buffer.Loc(0, 0)
end

function replace_chat_text(chat, text)
	local buf = chat.buf
	if buf == nil then
		return
	end
	local old = chat.text or ""
	if #old > 0 then
		pcall(function()
			buf:Remove(buffer.Loc(0, 0), buffer_end_loc(buf))
		end)
	end
	buf:Insert(buffer.Loc(0, 0), text)
	chat.text = text
	scroll_chat(chat)
end

local function stream_append(chat, text)
	if chat.buf == nil or not chat.streaming or text == "" then
		return
	end
	local loc = text_end_loc(chat.text)
	chat.buf:Insert(loc, text)
	chat.text = chat.text .. text
	scroll_chat(chat)
end

local SYSTEM_PROMPT = [[
你是运行在 micro 编辑器里的编程助手。回答用中文，简洁、直接。

你可以调用工具修改用户正在编辑的文件：
- replace_selection(text): 用 text 替换当前选区
- insert_at_cursor(text): 在光标处插入 text
- replace_line(text): 用 text 替换光标所在行
- read_file(path): 读取一个文件（用于查看未打开的文件）

规则：
1. 需要修改文件时调用工具，不要输出补丁让用户自己粘贴。
2. 一次工具调用只做一件事；拿到工具结果后继续，直到给出最终回答。
3. 只有用户明确要求修改时才调用写工具；不确定内容时先读上下文或 read_file。
4. 修改完成后用一两句话说明你做了什么。
]]

local TOOLS_JSON = [[
[
  {"type":"function","function":{"name":"replace_selection","description":"Replace the current selection in the active file.","parameters":{"type":"object","properties":{"text":{"type":"string","description":"The new text for the selection"}},"required":["text"]}}},
  {"type":"function","function":{"name":"insert_at_cursor","description":"Insert text at the cursor in the active file.","parameters":{"type":"object","properties":{"text":{"type":"string","description":"The text to insert"}},"required":["text"]}}},
  {"type":"function","function":{"name":"replace_line","description":"Replace the line under the cursor in the active file.","parameters":{"type":"object","properties":{"text":{"type":"string","description":"The new line content"}},"required":["text"]}}},
  {"type":"function","function":{"name":"read_file","description":"Read a file and return its contents.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Path of the file to read"}},"required":["path"]}}}
]
]]

local B64CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode(data)
	local out = {}
	local buf = {}
	local i = 1
	local n = #data
	while i <= n do
		local b1 = data:byte(i)
		local b2 = data:byte(i + 1)
		local b3 = data:byte(i + 2)
		local c1 = math.floor(b1 / 4)
		local c2 = (b1 % 4) * 16 + (b2 ~= nil and math.floor(b2 / 16) or 0)
		local c3 = b2 ~= nil and ((b2 % 16) * 4 + (b3 ~= nil and math.floor(b3 / 64) or 0)) or 0
		local c4 = b3 ~= nil and (b3 % 64) or 0
		buf[#buf + 1] = B64CHARS:sub(c1 + 1, c1 + 1)
		buf[#buf + 1] = B64CHARS:sub(c2 + 1, c2 + 1)
		buf[#buf + 1] = b2 ~= nil and B64CHARS:sub(c3 + 1, c3 + 1) or "="
		buf[#buf + 1] = b3 ~= nil and B64CHARS:sub(c4 + 1, c4 + 1) or "="
		if #buf >= 4096 then
			out[#out + 1] = table.concat(buf)
			buf = {}
		end
		i = i + 3
	end
	if #buf > 0 then
		out[#out + 1] = table.concat(buf)
	end
	return table.concat(out)
end

local function image_mime(data, name)
	if data:sub(1, 8) == "\137PNG\r\n\26\n" then
		return "image/png"
	end
	if data:sub(1, 2) == "\255\216" then
		return "image/jpeg"
	end
	if data:sub(1, 3) == "GIF" then
		return "image/gif"
	end
	if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
		return "image/webp"
	end
	local ext = tostr(name):lower():match("%.([%w]+)$")
	local map = { png = "image/png", jpg = "image/jpeg", jpeg = "image/jpeg", gif = "image/gif", webp = "image/webp" }
	return map[ext]
end

local function image_detail()
	local d = trim(tostr(option("imagedetail", "auto"))):lower()
	if d ~= "low" and d ~= "high" and d ~= "original" and d ~= "auto" then
		return "auto"
	end
	return d
end

local function basename(path)
	return tostr(path):match("([^/\\]+)$") or tostr(path)
end

local function attach_image(chat, img)
	if type(chat.pending_images) ~= "table" then
		chat.pending_images = {}
	end
	chat.pending_images[#chat.pending_images + 1] = img
	local pending = chat.pending_images
	chat.messages = chat.messages
	-- re-render the pending attachment hint
	if chat.buf ~= nil and not chat.streaming then
		replace_chat_text(chat, render_chat(chat, false))
	end
	micro.InfoBar():Message(string.format("shinny: 已附加 %s（%d KB，共 %d 张）", img.name, math.floor((img.bytes or 0) / 1024), #pending))
end

local function build_context_block(chat)
	local parts = {}
	local function add(line)
		parts[#parts + 1] = line
	end

	add("# 当前上下文")

	local src = chat.src_pane
	local src_name = nil
	if src ~= nil then
		local ok = pcall(function()
			src_name = src.Buf:GetName()
		end)
		if not ok then
			src = nil
			src_name = nil
		end
	end

	if src_name then
		add("当前文件: " .. src_name)
		add(string.format("光标位置: 第 %d 行, 第 %d 列", src.Cursor.Y + 1, src.Cursor.X + 1))
		local okline, line = pcall(function()
			return src.Buf:Line(src.Cursor.Y)
		end)
		if okline then
			add("光标所在行: " .. line)
		end
		local selection = selected_text(src)
		if selection ~= "" then
			add("选中文本:")
			add(utf8_prefix(selection, 3000))
		else
			add("选中文本: （无）")
		end
	end

	if last_search_text ~= "" then
		add("")
		add("最近一次搜索结果（查询「" .. last_search_query .. "」）:")
		add(utf8_prefix(last_search_text, 6000))
	end

	add("")
	add("打开的文件:")
	local budget = option_number("chatcontext", 24000)
	local used = 0
	local files = open_buffers()
	for _, b in ipairs(files) do
		if used >= budget then
			break
		end
		local name = "?"
		pcall(function()
			name = b:GetName()
		end)
		local text = buffer_text(b)
		local cap = budget - used
		if name == src_name then
			cap = math.min(cap, 12000)
		else
			cap = math.min(cap, 4000)
		end
		if #text > cap then
			text = utf8_prefix(text, cap) .. "\n…（已截断）"
		end
		used = used + #text
		add("")
		add("### 文件: " .. name .. (name == src_name and "（当前文件）" or ""))
		add(text)
	end

	return table.concat(parts, "\n")
end

-- Keep only the newest turns that fit the token budget. The first message of
-- the window is always a user message so tool calls stay paired.
local function window_messages(chat)
	local budget = math.max(2000, option_number("chattokenbudget", 24000))
	local msgs = chat.messages
	local total = 0
	local start = #msgs + 1
	for i = #msgs, 1, -1 do
		local m = msgs[i]
		local t = est_tokens(m.content or "") + est_tokens(m.reasoning_content or "")
		if type(m.images) == "table" then
			t = t + #m.images * 1024
		end
		if total + t > budget and start <= #msgs then
			break
		end
		total = total + t
		start = i
	end
	while start <= #msgs and msgs[start].role ~= "user" do
		start = start + 1
	end
	local out = {}
	for i = start, #msgs do
		out[#out + 1] = msgs[i]
	end
	return out
end

local function build_request(chat)
	local settings = chat_settings()
	local msgs = {}
	local function add(x)
		msgs[#msgs + 1] = x
	end

	add('{"role":"system","content":"' .. json_escape(SYSTEM_PROMPT) .. '"}')
	for _, m in ipairs(window_messages(chat)) do
		if m.role == "user" then
			if type(m.images) == "table" and #m.images > 0 then
				local blocks = { '{"type":"text","text":"' .. json_escape(m.content or "") .. '"}' }
				for _, img in ipairs(m.images) do
					blocks[#blocks + 1] = '{"type":"image_url","image_url":{"url":"'
						.. json_escape(img.url or "")
						.. '","detail":"'
						.. json_escape(img.detail or "auto")
						.. '"}}'
				end
				add('{"role":"user","content":[' .. table.concat(blocks, ",") .. "]}")
			else
				add('{"role":"user","content":"' .. json_escape(m.content or "") .. '"}')
			end
		elseif m.role == "assistant" then
			local parts = { '"role":"assistant"' }
			local content = m.content or ""
			if content ~= "" then
				parts[#parts + 1] = '"content":"' .. json_escape(content) .. '"'
			else
				parts[#parts + 1] = '"content":null'
			end
			if m.reasoning_content ~= nil and m.reasoning_content ~= "" then
				parts[#parts + 1] = '"reasoning_content":"' .. json_escape(m.reasoning_content) .. '"'
			end
			if type(m.tool_calls) == "table" and #m.tool_calls > 0 then
				parts[#parts + 1] = '"tool_calls":' .. encode_json(m.tool_calls)
			end
			add("{" .. table.concat(parts, ",") .. "}")
		elseif m.role == "tool" then
			add('{"role":"tool","tool_call_id":"' .. json_escape(m.tool_call_id or "") .. '","content":"' .. json_escape(m.content or "") .. '"}')
		end
	end

	local parts = {
		'"model":"' .. json_escape(settings.model) .. '"',
		'"messages":[' .. table.concat(msgs, ",") .. ']',
		'"stream":true',
		'"stream_options":{"include_usage":true}',
		'"tools":' .. TOOLS_JSON,
	}
	if settings.thinking then
		parts[#parts + 1] = '"thinking":{"type":"enabled"}'
		parts[#parts + 1] = '"reasoning_effort":"' .. json_escape(settings.effort) .. '"'
	else
		parts[#parts + 1] = '"thinking":{"type":"disabled"}'
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

local function merge_usage(chat, usage)
	if type(usage) ~= "table" then
		return
	end
	local u = chat.usage or {}
	u.prompt = (u.prompt or 0) + (tonumber(usage.prompt_tokens) or 0)
	u.completion = (u.completion or 0) + (tonumber(usage.completion_tokens) or 0)
	u.hit = (u.hit or 0) + (tonumber(usage.prompt_cache_hit_tokens) or 0)
	u.miss = (u.miss or 0) + (tonumber(usage.prompt_cache_miss_tokens) or 0)
	local details = usage.completion_tokens_details
	if type(details) == "table" then
		u.reasoning = (u.reasoning or 0) + (tonumber(details.reasoning_tokens) or 0)
	end
	chat.usage = u
end

local function usage_line(chat)
	local u = chat.usage
	if type(u) ~= "table" or (u.prompt or 0) == 0 then
		return nil
	end
	local pct = 0
	if (u.prompt or 0) > 0 then
		pct = math.floor((u.hit or 0) * 100 / u.prompt)
	end
	return string.format("in %s (cache %d%%) · out %s", fmt_tokens(u.prompt), pct, fmt_tokens(u.completion))
end

local function indent_text(text)
	return (tostr(text):gsub("\n", "\n  "))
end

function render_chat(chat, streaming)
	local out = {}
	local function add(line)
		out[#out + 1] = line
	end
	local settings = chat_settings()
	local thinking_label = settings.thinking and ("thinking " .. settings.effort) or "no thinking"
	local rule = string.rep("─", 30)

	add(rule)
	add(" shinny chat")
	local nfiles = #open_buffers()
	add(" " .. chat.label .. " · " .. (nfiles == 1 and "1 file" or (nfiles .. " files")))
	add(" " .. settings.model .. " · " .. thinking_label)
	local usage = usage_line(chat)
	if usage ~= nil then
		add(" tokens " .. usage)
	end
	add(rule)
	add("")

	if #chat.messages == 0 and not streaming then
		add(" 在下方输入栏（>）输入问题，Enter 发送。")
		add(" 例：解释光标处的代码")
		add("     把选区改写成更专业的语言 / 把这行改成英文")
		add("")
	end

	for _, m in ipairs(chat.messages) do
		if m.role == "user" then
			add("› you")
			add("  " .. indent_text(m.display or m.content or ""))
			if type(m.images) == "table" then
				for _, img in ipairs(m.images) do
					add("  🖼 " .. tostr(img.name or img.url))
				end
			end
			add("")
		elseif m.role == "assistant" then
			local content = m.display or m.content or ""
			if content ~= "" or type(m.tool_calls) ~= "table" or #m.tool_calls == 0 then
				add("› shinny")
				if content ~= "" then
					add("  " .. indent_text(content))
				end
				if option_bool("showthinking", false) and m.reasoning_content ~= nil and m.reasoning_content ~= "" then
					add("  ⋯ thinking")
					add("    " .. indent_text(shorten(m.reasoning_content, 2000)))
				end
				add("")
			end
		elseif m.role == "tool" then
			add("  ⚙ " .. tostr(m.display or "tool"))
			add("")
		end
	end

	if type(chat.pending_images) == "table" and #chat.pending_images > 0 then
		local names = {}
		for _, img in ipairs(chat.pending_images) do
			names[#names + 1] = tostr(img.name)
		end
		add("  🖼 待发送: " .. table.concat(names, ", "))
		add("")
	end

	if streaming then
		add("› shinny")
		add("  ")
	else
		add(rule)
		add(" Enter 发送 · Alt-i 聚焦 · Esc 停止 · Ctrl-Z 撤销")
	end
	return table.concat(out, "\n")
end

local function chat_key()
	local env = trim(os.Getenv("DEEPSEEK_API_KEY"))
	if env ~= "" then
		return env
	end
	return trim(tostr(option("deepseekkey", "")))
end

local function execute_tool(chat, call)
	local fn = call["function"] or {}
	local name = tostr(fn.name)
	local args = {}
	pcall(function()
		args = json_decode(tostr(fn.arguments))
	end)
	if type(args) ~= "table" then
		args = {}
	end

	if name == "replace_selection" or name == "insert_at_cursor" or name == "replace_line" then
		local target = "selection"
		if name == "insert_at_cursor" then
			target = "cursor"
		elseif name == "replace_line" then
			target = "line"
		end
		local ok, note = apply_edit(chat, target, tostr(args.text or ""))
		local result = ok and tostr(note) or ("error: " .. tostr(note))
		return result, result
	elseif name == "read_file" then
		local path = trim(tostr(args.path or ""))
		if path == "" then
			return "error: missing path", "缺少 path"
		end
		local ok, data = pcall(ioutil.ReadFile, path)
		if not ok or data == nil then
			return "error: cannot read " .. path, "读取失败"
		end
		local text = ""
		pcall(function()
			text = fmt.Sprintf("%s", data)
		end)
		return utf8_prefix(tostr(text), 8000), "已读取 " .. shorten(path, 40)
	end
	return "error: unknown tool " .. name, "未知工具"
end

local start_request
local handle_stream_chunk
local handle_stream_exit
local finalize_cancel

local STREAM_CMD = 'curl -sS -N --max-time 180 -X POST "$SHINNY_ENDPOINT"'
	.. ' -H "Content-Type: application/json"'
	.. ' -H "Authorization: Bearer $SHINNY_KEY"'
	.. ' --data-binary @"$SHINNY_BODY_FILE"'
	.. ' -w "\\n' .. STATUS_MARKER .. ':%{http_code}"'

local function accumulate_tool_calls(chat, list)
	for _, d in ipairs(list) do
		local idx = (tonumber(d.index) or 0) + 1
		local tc = chat.stream.tools[idx]
		if tc == nil then
			tc = { id = "", type = "function", ["function"] = { name = "", arguments = "" } }
			chat.stream.tools[idx] = tc
		end
		if type(d.id) == "string" then
			tc.id = d.id
		end
		if type(d.type) == "string" then
			tc.type = d.type
		end
		local fn = d["function"]
		if type(fn) == "table" then
			if type(fn.name) == "string" then
				tc["function"].name = tc["function"].name .. fn.name
			end
			if type(fn.arguments) == "string" then
				tc["function"].arguments = tc["function"].arguments .. fn.arguments
			end
		end
	end
end

function start_request(chat)
	local key = chat_key()
	if key == "" then
		chat.streaming = false
		micro.InfoBar():Error("shinny: 没有 DeepSeek key — 运行 > set shinny.deepseekkey <key>")
		return
	end
	local body = build_request(chat)
	local url = trim(tostr(option("chaturl", DEFAULT_DS_CHAT)))
	if url == "" then
		url = DEFAULT_DS_CHAT
	end

	chat.stream = { content = "", reasoning = "", tools = {}, usage = nil }
	chat.streaming = true
	chat.canceled = false
	chat.timeout = false
	chat.last_activity = TICK
	chat.sbuf = ""
	chat.raw = ""
	chat.think_bucket = 0
	chat.text = render_chat(chat, true)
	replace_chat_text(chat, chat.text)

	REQ_SEQ = (REQ_SEQ or 0) + 1
	chat.req_seq = REQ_SEQ
	local body_path = chat_dir() .. "/request-" .. PROCESS_TOKEN .. "-" .. tostring(hash_key(chat.key)) .. "-" .. tostring(REQ_SEQ) .. ".json"
	pcall(os.MkdirAll, chat_dir(), 448)
	local wrote = pcall(ioutil.WriteFile, body_path, body, 384)
	if not wrote then
		chat.streaming = false
		micro.InfoBar():Error("shinny: 无法写入请求体 " .. body_path)
		replace_chat_text(chat, render_chat(chat, false))
		return
	end
	chat.body_path = body_path
	os.Setenv("SHINNY_ENDPOINT", url)
	os.Setenv("SHINNY_KEY", key)
	os.Setenv("SHINNY_BODY", "")
	os.Setenv("SHINNY_BODY_FILE", body_path)
	micro.InfoBar():Message("shinny: streaming…")

	local ok, job = pcall(shell.JobStart, STREAM_CMD, function(chunk)
		handle_stream_chunk(chat, chunk)
	end, nil, function(output)
		os.Setenv("SHINNY_KEY", "")
		os.Setenv("SHINNY_BODY", "")
		handle_stream_exit(chat, output)
	end)

	if not ok then
		chat.streaming = false
		if chat.body_path ~= nil then
			pcall(os.Remove, chat.body_path)
			chat.body_path = nil
		end
		os.Setenv("SHINNY_KEY", "")
		os.Setenv("SHINNY_BODY", "")
		chat.messages[#chat.messages + 1] = {
			role = "assistant",
			content = "（无法启动请求：" .. shorten(collapse(tostr(job)), 300) .. "）",
			display = "（无法启动请求：" .. shorten(collapse(tostr(job)), 300) .. "）",
		}
		replace_chat_text(chat, render_chat(chat, false))
		return
	end
	chat.job = job
end

function handle_stream_chunk(chat, chunk)
	chat.last_activity = TICK
	chat.sbuf = (chat.sbuf or "") .. tostr(chunk)
	chat.raw = (chat.raw or "") .. tostr(chunk)
	while true do
		local nl = chat.sbuf:find("\n", 1, true)
		if not nl then
			break
		end
		local line = chat.sbuf:sub(1, nl - 1)
		chat.sbuf = chat.sbuf:sub(nl + 1)
		line = line:gsub("\r$", "")
		if line:sub(1, 5) == "data:" then
			local payload = trim(line:sub(6))
			if payload == "[DONE]" then
				chat.stream.done = true
				if chat.job ~= nil then
					pcall(shell.JobStop, chat.job)
					chat.job = nil
				end
				micro.After(0, function()
					if chat.streaming then
						handle_stream_exit(chat, "")
					end
				end)
			elseif payload ~= "" then
				local ok, data = pcall(json_decode, payload)
				if ok and type(data) == "table" then
					if type(data.usage) == "table" then
						chat.stream.usage = data.usage
					end
					local choices = data.choices
					if type(choices) == "table" and type(choices[1]) == "table" then
						local delta = choices[1].delta
						if type(delta) == "table" then
							if type(delta.reasoning_content) == "string" and delta.reasoning_content ~= "" then
								chat.stream.reasoning = chat.stream.reasoning .. delta.reasoning_content
								local bucket = math.floor(#chat.stream.reasoning / 200)
								if bucket ~= chat.think_bucket then
									chat.think_bucket = bucket
									micro.InfoBar():Message("shinny: thinking… " .. tostring(#chat.stream.reasoning))
								end
							end
							if type(delta.content) == "string" and delta.content ~= "" then
								chat.stream.content = chat.stream.content .. delta.content
								stream_append(chat, delta.content)
							end
							if type(delta.tool_calls) == "table" then
								accumulate_tool_calls(chat, delta.tool_calls)
							end
						end
					end
				end
			end
		end
	end
end

function finalize_timeout(chat)
	if chat.body_path ~= nil then
		pcall(os.Remove, chat.body_path)
		chat.body_path = nil
	end
	local partial = chat.stream and chat.stream.content or ""
	local note = "（响应超时，已保留部分内容）"
	local content = partial ~= "" and (partial .. "\n\n" .. note) or note
	chat.messages[#chat.messages + 1] = {
		role = "assistant",
		content = content,
		display = content,
		reasoning_content = chat.stream and chat.stream.reasoning or nil,
	}
	save_chat(chat)
	replace_chat_text(chat, render_chat(chat, false))
	micro.InfoBar():Message("shinny: 响应超时，已保留部分内容")
end

local function watch_chats()
	TICK = TICK + 1
	for _, chat in pairs(chats) do
		if chat.streaming and chat.job ~= nil then
			local last = chat.last_activity or TICK
			if TICK - last >= 6 then
				chat.timeout = true
				local job = chat.job
				chat.job = nil
				if job ~= nil then
					pcall(shell.JobStop, job)
				end
				micro.After(0, function()
					if chat.streaming then
						chat.streaming = false
						finalize_timeout(chat)
					end
				end)
			end
		end
	end
	micro.After(5000000000, watch_chats)
end

function finalize_cancel(chat)
	local partial = chat.stream and chat.stream.content or ""
	local content = partial ~= "" and (partial .. "\n\n（已停止）") or "（已停止）"
	chat.messages[#chat.messages + 1] = {
		role = "assistant",
		content = content,
		display = content,
		reasoning_content = chat.stream and chat.stream.reasoning or nil,
	}
	save_chat(chat)
	replace_chat_text(chat, render_chat(chat, false))
	micro.InfoBar():Message("shinny: 已停止")
end

function handle_stream_exit(chat, output)
	chat.job = nil
	if chat.body_path ~= nil then
		pcall(os.Remove, chat.body_path)
		chat.body_path = nil
	end
	if not chat.streaming then
		return
	end
	if chat.timeout then
		chat.streaming = false
		finalize_timeout(chat)
		return
	end
	local status = nil
	if output ~= nil then
		local m = tostr(output):match(STATUS_MARKER .. ":(%d+)")
		status = tonumber(m or "")
	end
	local partial = chat.stream.content or ""
	local tools = chat.stream.tools or {}
	chat.streaming = false

	if chat.canceled then
		finalize_cancel(chat)
		return
	end

	local retryable = (status == nil or status == 0 or status == 429 or (status ~= nil and status >= 500))
	if retryable and partial == "" and #tools == 0 then
		chat.retries = (chat.retries or 0) + 1
		if chat.retries <= 2 then
			micro.InfoBar():Message(string.format("shinny: 请求失败，重试 %d/2…", chat.retries))
			micro.After(1200000000 * chat.retries, function()
				if not chat.streaming then
					start_request(chat)
				end
			end)
			return
		end
	end

	if (status == nil or status < 200 or status >= 300) and partial == "" and #tools == 0 and (chat.stream.reasoning or "") == "" then
		local detail = error_detail(chat.raw or "")
		if detail == "" then
			detail = status ~= nil and ("HTTP " .. tostr(status)) or "流式响应为空"
		end
		chat.messages[#chat.messages + 1] = {
			role = "assistant",
			content = "（请求失败：" .. shorten(detail, 300) .. "）",
			display = "（请求失败：" .. shorten(detail, 300) .. "）",
		}
		save_chat(chat)
		replace_chat_text(chat, render_chat(chat, false))
		return
	end

	chat.retries = 0
	merge_usage(chat, chat.stream.usage)

	if #tools > 0 then
		chat.messages[#chat.messages + 1] = {
			role = "assistant",
			content = partial,
			display = partial,
			reasoning_content = chat.stream.reasoning,
			tool_calls = tools,
		}
		for _, call in ipairs(tools) do
			local name = tostr((call["function"] or {}).name)
			local result, note = execute_tool(chat, call)
			chat.messages[#chat.messages + 1] = {
				role = "tool",
				tool_call_id = call.id,
				content = result,
				display = name .. " · " .. note,
			}
		end
		save_chat(chat)
		chat.round = (chat.round or 0) + 1
		replace_chat_text(chat, render_chat(chat, false))
		if chat.round >= 4 then
			chat.messages[#chat.messages + 1] = {
				role = "assistant",
				content = "（工具调用次数达到上限）",
				display = "（工具调用次数达到上限）",
			}
			save_chat(chat)
			replace_chat_text(chat, render_chat(chat, false))
			return
		end
		start_request(chat)
		return
	end

	local content = partial
	local notes = {}
	if content ~= "" then
		local cleaned
		cleaned, notes = apply_edits(chat, content)
		content = cleaned
	end
	if content == "" and (chat.stream.reasoning or "") ~= "" then
		content = "（只返回了思考内容，没有最终回答）"
	end
	local display = content
	if #notes > 0 then
		display = (display ~= "" and display .. "\n\n" or "") .. "▸ 已应用到文件：" .. table.concat(notes, "；")
	end
	chat.messages[#chat.messages + 1] = {
		role = "assistant",
		content = content,
		display = display,
		reasoning_content = chat.stream.reasoning,
	}
	save_chat(chat)
	replace_chat_text(chat, render_chat(chat, false))
	micro.InfoBar():Message("shinny: 完成")
end

local function send_chat(chat, question)
	if chat.streaming then
		micro.InfoBar():Error("shinny: 上一个问题还在处理中")
		return false
	end
	local key = chat_key()
	if key == "" then
		micro.InfoBar():Error("shinny: 没有 DeepSeek key — 运行 > set shinny.deepseekkey <key>")
		return false
	end

	local context = build_context_block(chat)
	local api_content = context .. "\n\n[用户问题]\n" .. question
	local msg = {
		role = "user",
		content = api_content,
		display = question,
	}
	if type(chat.pending_images) == "table" and #chat.pending_images > 0 then
		msg.images = chat.pending_images
	end
	chat.pending_images = {}
	chat.messages[#chat.messages + 1] = msg
	chat.round = 0
	chat.retries = 0
	chat.canceled = false
	save_chat(chat)
	start_request(chat)
	return true
end

local function chat_label(name)
	name = tostr(name)
	if name == "" or name == "No name" then
		return "untitled"
	end
	return name:match("([^/\\]+)$") or name
end

local function reset_input(chat)
	local buf = chat.ibuf
	if buf == nil then
		return
	end
	local text = buffer_text(buf)
	pcall(function()
		buf:Remove(buffer.Loc(0, 0), text_end_loc(text))
	end)
	buf:Insert(buffer.Loc(0, 0), INPUT_PROMPT)
	local loc = buffer.Loc(#INPUT_PROMPT, 0)
	pcall(function()
		buf:GetActiveCursor():GotoLoc(loc)
	end)
	if chat.ipane ~= nil then
		pcall(function()
			chat.ipane:GotoLoc(loc)
		end)
	end
	resize_chat_input(chat)
end

local function read_input(chat)
	if chat.ibuf == nil then
		return ""
	end
	local text = buffer_text(chat.ibuf)
	text = text:gsub("^%s*>%s?", "")
	return trim(text)
end

local function focus_input(chat)
	local pane = find_pane_by_name(chat.input_name)
	if pane ~= nil then
		chat.ipane = pane
	end
	return pane
end

local function close_chat_ui(chat)
	if chat == nil then
		return
	end
	if chat.ipane ~= nil then
		pcall(function()
			chat.ipane:ForceQuit()
		end)
	end
	if chat.pane ~= nil then
		pcall(function()
			chat.pane:ForceQuit()
		end)
	end
	chat.buf = nil
	chat.ibuf = nil
	chat.pane = nil
	chat.ipane = nil
	chat.text = ""
end

local function chats_in_tab(bp)
	local out = {}
	local seen = {}
	local tab = bp:Tab()
	if tab == nil then
		return out
	end
	local count = 0
	pcall(function()
		count = #tab.Panes
	end)
	for i = 1, count do
		local pane = tab.Panes[i]
		if pane ~= nil and pane.Buf ~= nil then
			local name = ""
			pcall(function()
				name = tostr(pane.Buf:GetName())
			end)
			local chat = chats[name] or chats_by_input[name]
			if chat ~= nil and not seen[chat] then
				seen[chat] = true
				out[#out + 1] = chat
			end
		end
	end
	return out
end

local function switch_chat_ui(bp, keep)
	local tab = bp:Tab()
	local count = 0
	if tab ~= nil then
		pcall(function()
			count = #tab.Panes
		end)
	end
	local keep_in_tab = keep.pane ~= nil
	if keep.pane ~= nil and count > 0 then
		keep_in_tab = false
		for i = 1, count do
			local pane = tab.Panes[i]
			if pane == keep.pane then
				keep_in_tab = true
				break
			end
		end
	end
	for _, other in ipairs(chats_in_tab(bp)) do
		if other ~= keep then
			if other.streaming then
				micro.InfoBar():Error("shinny: 另一个会话还在生成，先按 Esc 停止")
				return false
			end
			close_chat_ui(other)
		end
	end
	if keep.pane ~= nil and count > 0 and not keep_in_tab then
		if keep.streaming then
			return false
		end
		close_chat_ui(keep)
	end
	return true
end

function resize_chat_input(chat)
	if chat == nil or chat.ipane == nil or chat.ibuf == nil then
		return
	end
	local lines = 1
	pcall(function()
		lines = chat.ibuf:LinesNum()
	end)
	if type(lines) ~= "number" or lines < 1 then
		lines = 1
	end
	if lines > 8 then
		lines = 8
	end
	local h = 0
	pcall(function()
		h = chat.ipane:Tab().H
	end)
	if type(h) ~= "number" or h <= lines + 2 then
		return
	end
	if chat.last_input_lines == lines and chat.last_input_h == h then
		return
	end
	chat.last_input_lines = lines
	chat.last_input_h = h
	pcall(function()
		chat.ipane:ResizePane(h - (lines + 1))
	end)
end

local function watch_input_panes()
	for _, chat in pairs(chats_by_input) do
		pcall(resize_chat_input, chat)
	end
	micro.After(250000000, watch_input_panes)
end

local function start_input_watch()
	if INPUT_WATCH then
		return
	end
	INPUT_WATCH = true
	micro.After(250000000, watch_input_panes)
end

local function rightmost_pane(bp)
	local tab = bp:Tab()
	if tab == nil then
		return bp
	end
	local count = 0
	pcall(function()
		count = #tab.Panes
	end)
	local best = bp
	local bestx = -1
	for i = 1, count do
		local pane = tab.Panes[i]
		if pane ~= nil then
			local ok, v = pcall(function()
				return pane:GetView()
			end)
			if ok and v ~= nil and type(v.X) == "number" and v.X > bestx then
				bestx = v.X
				best = pane
			end
		end
	end
	return best
end

local function ensure_chat_panes(bp, chat)
	local tpane = find_pane_by_name(chat.name)
	local ipane = find_pane_by_name(chat.input_name)

	if tpane == nil then
		local tbuf = buffer.NewBuffer("", "")
		tbuf:SetName(chat.name)
		chat.buf = tbuf
		chat.text = ""
		local dock = rightmost_pane(bp)
		tpane = dock:VSplitIndex(tbuf, true)
		chat.pane = tpane
	end
	chat.pane = tpane

	if ipane == nil then
		if chat.ibuf == nil then
			chat.ibuf = buffer.NewBuffer(INPUT_PROMPT, "")
			chat.ibuf:SetName(chat.input_name)
		end
		ipane = tpane:HSplitIndex(chat.ibuf, true)
		chat.ipane = ipane
		reset_input(chat)
		resize_chat_input(chat)
	end

	if chat.buf == nil then
		chat.buf = tpane.Buf
	end
	set_filetype(chat.buf, "shinnychat", true)
	set_filetype(chat.ibuf, "shinnyinput", true)
	chat.text = chat.text or ""
	replace_chat_text(chat, render_chat(chat, chat.streaming))
	focus_input(chat)
end

local function insert_input_newline(bp)
	if bp == nil then
		return
	end
	local cursor = bp.Cursor
	local y = cursor.Y
	bp.Buf:Insert(buffer.Loc(cursor.X, y), "\n")
	pcall(function()
		cursor:GotoLoc(buffer.Loc(0, y + 1))
	end)
	local chat = chats_by_input[tostr(bp.Buf:GetName())]
	if chat ~= nil then
		resize_chat_input(chat)
	end
end

function preInsertNewline(bp)
	if bp == nil then
		return true
	end
	local chat = chats_by_input[tostr(bp.Buf:GetName())]
	if chat == nil then
		return true
	end
	if chat.esc_pending then
		chat.esc_pending = false
		insert_input_newline(bp)
		return false
	end
	if chat.streaming then
		micro.InfoBar():Error("shinny: 上一个问题还在处理中")
		return false
	end
	local text = read_input(chat)
	if text == "" then
		micro.InfoBar():Message("shinny: 输入问题后按 Enter 发送")
		return false
	end
	if send_chat(chat, text) then
		reset_input(chat)
	end
	return false
end

local pad_after_cancel

function preEscape(bp)
	if bp == nil then
		return true
	end
	local name = tostr(bp.Buf:GetName())
	local chat = chats[name] or chats_by_input[name]
	if chat ~= nil and chat.streaming then
		chat.canceled = true
		if chat.job ~= nil then
			pcall(shell.JobStop, chat.job)
		end
		micro.After(400000000, function()
			if chat.streaming and chat.canceled then
				pad_after_cancel(chat)
			end
		end)
		return false
	end
	if chat ~= nil and chats_by_input[name] ~= nil then
		chat.esc_pending = true
		micro.After(300000000, function()
			chat.esc_pending = false
		end)
	end
	return true
end

function pad_after_cancel(chat)
	if chat.streaming then
		chat.streaming = false
		finalize_cancel(chat)
	end
end

local function chat_for(bp)
	local name = bp.Buf:GetName()
	if is_chat_name(name) then
		return chats[name]
	end

	local key
	if name == "" or name == "No name" then
		key = "untitled:" .. tostr(bp:ID())
	else
		key = name
	end
	local known = chats_by_key[key]
	if known ~= nil then
		known.src_pane = bp
		if known.input_name == nil then
			known.input_name = CHAT_INPUT_PREFIX .. known.name:sub(#CHAT_PREFIX + 1)
		end
		chats_by_input[known.input_name] = known
		return known
	end

	local label = chat_label(name)
	local chat_name = CHAT_PREFIX .. label
	local chat = chats[chat_name]
	if chat ~= nil and chat.key ~= key then
		local i = 2
		repeat
			chat_name = CHAT_PREFIX .. label .. " (" .. i .. ")"
			chat = chats[chat_name]
			i = i + 1
		until chat == nil or chat.key == key
	end

	local input_name = CHAT_INPUT_PREFIX .. chat_name:sub(#CHAT_PREFIX + 1)
	if chat == nil then
		chat = {
			name = chat_name,
			input_name = input_name,
			key = key,
			label = label,
			messages = {},
			usage = {},
			buf = nil,
			pane = nil,
			ibuf = nil,
			ipane = nil,
			src_pane = bp,
			streaming = false,
			pending_images = {},
			text = "",
			round = 0,
			retries = 0,
		}
		chats[chat_name] = chat
		chats_by_key[key] = chat
		load_chat(chat)
	else
		chat.src_pane = bp
		if chat.input_name == nil then
			chat.input_name = input_name
		end
	end
	chats_by_input[chat.input_name] = chat
	return chat
end

-- ---------------------------------------------------------------------------
-- commands
-- ---------------------------------------------------------------------------

local function render_help()
	local settings = chat_settings()
	local prefix = current_prefix()
	local suffix = current_suffix()
	local lines = {}
	local function add(line)
		lines[#lines + 1] = tostr(line)
	end

	add("# shinny 帮助")
	add("")
	add("## 快捷键")
	add("")
	add("- `Alt-s` — 搜索选区（等同 `> shinny`）")
	add("- `Alt-i` — 打开 / 聚焦当前文件的 chat 输入栏")
	add("- `Esc` — 生成过程中停止")
	add("- `Alt-r` — 在新 tab 打开 / 刷新当前 Markdown 的渲染预览")
	add("- `Shift+Enter` — 输入栏内换行（终端需映射为 Alt-Enter，见 README）")
	add("")
	add("## 搜索")
	add("")
	add("- 选中文字后按 `Alt-s`，实际查询 = 前缀 + 文字 + 后缀")
	add("- 也可以 `> shinny <query>` 直接搜索")
	add("- 搜索后端：`" .. current_backend() .. "`；用 `> shinny-backend tavily|deepseek` 切换")
	add("")
	add("## Chat")
	add("")
	add("- `Alt-i` 在右侧打开 chat 分屏；会话由光标所在文件决定（不同文件相互隔离）")
	add("- 在输入栏输入问题，`Enter` 发送；再按 `Alt-i` 回到输入栏")
	add("- 流式输出；回答和思考过程分开处理，思考内容可选显示")
	add("- 输入栏 Enter 发送，Shift+Enter 换行（终端映射为 Alt-Enter 后生效）")
	add("- 在另一个文件按 Alt-i 会把右侧分屏切换成那个文件的会话")
	add("- Chat 能看到所有打开的文件、光标位置、选区和最近一次搜索结果")
	add("- 模型通过 function calling 直接修改文件（`Ctrl-Z` 可撤销）")
	add("- 会话按文件保存到 `~/.config/micro/shinny/chats`，重启可恢复")
	add("- 底部会显示 token 用量和 cache 命中率")
	add("- `> shinny-preview` 用 `rich` 渲染当前 buffer 或最后一条回答（新 tab）")
	add("- 支持图片输入（PNG / JPEG / GIF / WebP）：`> shinny-image ~/shot.png`，或直接 `> shinny-image` 读剪贴板；图片随下一条消息发送")
	add("")
	add("## 命令")
	add("")
	add("- `shinny [query]` — 搜索选区或指定文字")
	add("- `shinny-prefix [text]` — 查看/设置前缀（`-` 清除）")
	add("- `shinny-suffix [text]` — 查看/设置后缀（`-` 清除）")
	add("- `shinny-backend [tavily|deepseek]` — 查看/切换搜索后端")
	add("- `shinny-chat` — 打开当前文件的 chat，等同 `Alt-i`")
	add("- `shinny-model [name]` — 查看/切换模型")
	add("- `shinny-thinking [on|off]` — 查看/切换思考模式")
	add("- `shinny-effort [low|high|max]` — 查看/设置思考强度")
	add("- `shinny-chat-new` — 清空当前文件的会话")
	add("- `shinny-usage` — 显示 token / cache 用量")
	add("- `shinny-preview` — 把当前 Markdown 或最后一条回答渲染到新 tab")
	add("- `shinny-chat-stop` — 停止正在生成的回复")
	add("- `shinny-image [path]` — 附加图片到下一问（不带参数读剪贴板）")
	add("- `shinny-image-url <url>` — 附加公网图片 URL")
	add("- `shinny-image-detail <level>` — low / high / original / auto")
	add("- `shinny-image-clear` — 清空待发送图片")
	add("- `shinny-raw` — 打开上一次请求的原始响应")
	add("- `shinny-help` — 显示这份帮助")
	add("")
	add("## 当前设置")
	add("")
	add("- 前缀：`" .. (prefix == "" and "无" or prefix) .. "`")
	add("- 后缀：`" .. (suffix == "" and "无" or suffix) .. "`")
	add("- 搜索后端：`" .. current_backend() .. "`")
	add("- Chat 模型：`" .. settings.model .. "`")
	add("- 思考模式：`" .. (settings.thinking and ("on · " .. settings.effort) or "off") .. "`")
	add("- Tavily key：" .. (api_key("tavily") ~= "" and "已配置" or "未配置"))
	add("- DeepSeek key：" .. (api_key("deepseek") ~= "" and "已配置" or "未配置"))
	add("- 结果数量：`" .. tostr(math.floor(option_number("maxresults", 5))) .. "`")
	add("- 上下文预算：`" .. tostr(math.floor(option_number("chattokenbudget", 24000))) .. "` tokens")
	add("- 图片 detail：" .. image_detail() .. "（上限 " .. tostr(math.floor(option_number("imagemaxmb", 12))) .. " MB/张）")
	add("")
	add("## 常用选项")
	add("")
	add("`shinny.prefix`、`shinny.suffix`、`shinny.backend`、`shinny.apikey`、")
	add("`shinny.deepseekkey`、`shinny.chatmodel`、`shinny.thinking`、`shinny.effort`、")
	add("`shinny.maxresults`、`shinny.chatcontext`、`shinny.chattokenbudget`、`shinny.showthinking`、`shinny.imagedetail`、`shinny.imagemaxmb`")
	add("")
	add("完整文档：`> help shinny`")
	return table.concat(lines, "\n") .. "\n"
end

function shinny_help(bp, args)
	local pane = micro.CurPane()
	if pane == nil then
		pane = bp
	end
	if pane == nil then
		micro.InfoBar():Error("shinny: 没有可以显示帮助的窗格")
		return
	end
	local buf = buffer.NewBuffer(render_help(), "")
	buf:SetName("shinny help")
	set_filetype(buf, "markdown", true)
	pane:VSplitBuf(buf)
end

function shinny(bp, args)
	local query = trim(join_args(args))
	if query == "" then
		query = selected_text(bp)
	end
	if query == "" then
		micro.InfoBar():Error("shinny: 先选中一些文字，或者运行 > shinny <query>")
		return
	end
	start_search(query)
end

function shinny_raw(bp)
	if last_response == nil then
		micro.InfoBar():Error("shinny: 还没有请求过")
		return
	end
	local pane = micro.CurPane()
	if pane == nil then
		micro.InfoBar():Error("shinny: 没有可以显示的分屏")
		return
	end
	local buf = buffer.NewBuffer(last_response, "")
	buf:SetName("shinny raw: " .. shorten(last_query, 32))
	pane:VSplitBuf(buf)
end

local function setting_command(name, label, args)
	local text = trim(join_args(args))
	if text == "" then
		local current = tostr(option(name, ""))
		micro.InfoBar():Message(string.format("shinny: %s = 「%s」", label, current == "" and "无" or current))
		return
	end
	if text == "-" then
		text = ""
	end
	set_setting(name, text)
	micro.InfoBar():Message(string.format("shinny: %s 已设为「%s」", label, text == "" and "无" or text))
end

function shinny_prefix(bp, args)
	setting_command("prefix", "前缀", args)
end

function shinny_suffix(bp, args)
	setting_command("suffix", "后缀", args)
end

function shinny_backend(bp, args)
	local value = trim(join_args(args))
	if value == "" then
		micro.InfoBar():Message("shinny: backend = " .. current_backend() .. "（tavily | deepseek）")
		return
	end
	value = value:lower()
	if value ~= "tavily" and value ~= "deepseek" then
		micro.InfoBar():Error("shinny: backend 只能是 tavily 或 deepseek")
		return
	end
	set_setting("backend", value)
	micro.InfoBar():Message("shinny: backend = " .. value)
end

function shinny_model(bp, args)
	local value = trim(join_args(args))
	if value == "" then
		micro.InfoBar():Message("shinny: model = " .. chat_settings().model .. "（deepseek-flash | deepseek-v4-pro）")
		return
	end
	set_setting("model", value, "chatmodel")
	micro.InfoBar():Message("shinny: model = " .. value)
end

function shinny_thinking(bp, args)
	local value = trim(join_args(args)):lower()
	if value == "" then
		local settings = chat_settings()
		micro.InfoBar():Message(
			"shinny: thinking = " .. (settings.thinking and ("on · effort " .. settings.effort) or "off")
		)
		return
	end
	local on
	if value == "on" or value == "true" or value == "1" then
		on = true
	elseif value == "off" or value == "false" or value == "0" then
		on = false
	else
		micro.InfoBar():Error("shinny: thinking 只能是 on 或 off")
		return
	end
	set_setting("thinking", on)
	micro.InfoBar():Message("shinny: thinking = " .. (on and "on" or "off"))
end

function shinny_effort(bp, args)
	local value = trim(join_args(args)):lower()
	if value == "" then
		micro.InfoBar():Message("shinny: effort = " .. chat_settings().effort .. "（low | high | max）")
		return
	end
	if value == "minimal" then
		value = "low"
	elseif value == "medium" or value == "xhigh" then
		value = "high"
	end
	if value ~= "low" and value ~= "high" and value ~= "max" then
		micro.InfoBar():Error("shinny: effort 只能是 low | high | max")
		return
	end
	set_setting("effort", value)
	micro.InfoBar():Message("shinny: effort = " .. value)
end

local function chat_at(bp)
	if bp == nil then
		return nil
	end
	local name = tostr(bp.Buf:GetName())
	if is_chat_name(name) or is_input_name(name) then
		return chats[name] or chats_by_input[name]
	end
	return chat_for(bp)
end

local function require_chat(bp)
	local chat = chat_at(bp)
	if chat == nil then
		micro.InfoBar():Error("shinny: 没有活动 chat")
	end
	return chat
end

local function add_image_file(chat, path, display_name)
	local maxmb = option_number("imagemaxmb", 12)
	local limit = maxmb * 1024 * 1024
	local ok, data = pcall(ioutil.ReadFile, path)
	if not ok or data == nil then
		micro.InfoBar():Error("shinny: 读不到图片 " .. tostr(path))
		return
	end
	local text = ""
	pcall(function()
		text = fmt.Sprintf("%s", data)
	end)
	data = tostr(text)
	if #data > limit then
		micro.InfoBar():Error(string.format("shinny: 图片 %.1f MB 超过上限 %d MB", #data / 1048576, maxmb))
		return
	end
	local mime = image_mime(data, path)
	if mime == nil then
		micro.InfoBar():Error("shinny: 只支持 JPEG / PNG / GIF / WebP")
		return
	end
	attach_image(chat, {
		kind = "file",
		name = display_name or basename(path),
		url = "data:" .. mime .. ";base64," .. base64_encode(data),
		detail = image_detail(),
		bytes = #data,
	})
end

function shinny_image(bp, args)
	local chat = require_chat(bp)
	if chat == nil then
		return
	end
	local path = trim(join_args(args))
	if path == "" then
		local data = nil
		local ok, out = pcall(shell.ExecCommand, "wl-paste", "--type", "image/png")
		if ok and out ~= nil and out ~= "" then
			data = out
		else
			local ok2, out2 = pcall(shell.ExecCommand, "xclip", "-selection", "clipboard", "-t", "image/png", "-o")
			if ok2 and out2 ~= nil and out2 ~= "" then
				data = out2
			end
		end
		if data == nil then
			micro.InfoBar():Error("shinny: 剪贴板里没有图片，或改用 > shinny-image <path>")
			return
		end
		local mime = image_mime(data, "clipboard.png")
		if mime == nil then
			micro.InfoBar():Error("shinny: 剪贴板内容不是支持的图片格式")
			return
		end
		if #data > option_number("imagemaxmb", 12) * 1024 * 1024 then
			micro.InfoBar():Error("shinny: 剪贴板图片太大")
			return
		end
		attach_image(chat, {
			kind = "clipboard",
			name = "clipboard.png",
			url = "data:" .. mime .. ";base64," .. base64_encode(data),
			detail = image_detail(),
			bytes = #data,
		})
		return
	end
	if path:sub(1, 2) == "~/" then
		path = tostr(os.Getenv("HOME")) .. path:sub(2)
	end
	add_image_file(chat, path)
end

function shinny_image_url(bp, args)
	local chat = require_chat(bp)
	if chat == nil then
		return
	end
	local url = trim(join_args(args))
	if url == "" then
		micro.InfoBar():Error("shinny: 用法 > shinny-image-url <https://...>")
		return
	end
	if #url > 8192 or not url:match("^https?://") then
		micro.InfoBar():Error("shinny: 需要 http(s) 图片 URL，且不超过 8192 字符")
		return
	end
	attach_image(chat, { kind = "url", name = shorten(url, 60), url = url, detail = image_detail(), bytes = 0 })
end

function shinny_image_clear(bp, args)
	local chat = require_chat(bp)
	if chat == nil then
		return
	end
	chat.pending_images = {}
	if chat.buf ~= nil and not chat.streaming then
		replace_chat_text(chat, render_chat(chat, false))
	end
	micro.InfoBar():Message("shinny: 已清空待发送图片")
end

function shinny_image_detail(bp, args)
	local value = trim(join_args(args)):lower()
	if value == "" then
		micro.InfoBar():Message("shinny: image detail = " .. image_detail())
		return
	end
	if value ~= "low" and value ~= "high" and value ~= "original" and value ~= "auto" then
		micro.InfoBar():Error("shinny: detail 只能是 low | high | original | auto")
		return
	end
	set_setting("imagedetail", value)
	micro.InfoBar():Message("shinny: image detail = " .. value)
end

function shinny_chat_new(bp, args)
	local chat = chat_at(bp)
	if chat == nil then
		micro.InfoBar():Error("shinny: 没有活动 chat")
		return
	end
	if chat.streaming and chat.job ~= nil then
		pcall(shell.JobStop, chat.job)
		chat.streaming = false
	end
	chat.messages = {}
	chat.usage = {}
	chat.round = 0
	pcall(os.Remove, chat_file(chat))
	replace_chat_text(chat, render_chat(chat, false))
	micro.InfoBar():Message("shinny: 新会话")
end

function shinny_usage(bp, args)
	local chat = chat_at(bp)
	if chat == nil then
		micro.InfoBar():Error("shinny: 没有活动 chat")
		return
	end
	local line = usage_line(chat)
	if line == nil then
		micro.InfoBar():Message("shinny: 还没有用量数据")
		return
	end
	micro.InfoBar():Message("shinny: " .. line)
end

function shinny_chat_stop(bp, args)
	local chat = chat_at(bp)
	if chat == nil or not chat.streaming then
		micro.InfoBar():Message("shinny: 当前没有正在生成的回复")
		return
	end
	chat.canceled = true
	if chat.job ~= nil then
		pcall(shell.JobStop, chat.job)
	end
	micro.InfoBar():Message("shinny: 正在停止…")
end

function shinny_chat_newline(bp, args)
	if bp == nil then
		return
	end
	local name = tostr(bp.Buf:GetName())
	if name:sub(1, 1) == ">" then
		return
	end
	if is_chat_name(name) then
		return
	end
	if chats_by_input[name] ~= nil then
		insert_input_newline(bp)
		return
	end
	local cursor = bp.Cursor
	local ok, line = pcall(function()
		return bp.Buf:Line(cursor.Y)
	end)
	if not ok then
		return
	end
	local indent = tostr(line):match("^%s*") or ""
	pcall(function()
		bp.Buf:Insert(buffer.Loc(cursor.X, cursor.Y), "\n" .. indent)
		cursor:GotoLoc(buffer.Loc(#indent, cursor.Y + 1))
	end)
end

local PREVIEW_PREFIX = "shinny preview · "

local function read_text_file(path)
	local ok, data = pcall(ioutil.ReadFile, path)
	if not ok or data == nil then
		return nil
	end
	local text = ""
	pcall(function()
		text = fmt.Sprintf("%s", data)
	end)
	return tostr(text)
end

local function render_markdown(path)
	local ok, out = pcall(shell.ExecCommand, "python3", "-m", "rich.markdown", path)
	if not ok or out == nil or tostr(out) == "" then
		return nil
	end
	local text = tostr(out)
	text = text:gsub("\27%[[%d;]*m", "")
	return text
end

local function find_preview_tab()
	local tabs = micro.Tabs()
	for i = 1, #tabs.List do
		local tab = tabs.List[i]
		local count = 1
		pcall(function()
			count = #tab.Panes
		end)
		for j = 1, count do
			local pane = tab.Panes[j]
			if pane ~= nil then
				local name = ""
				pcall(function()
					name = tostr(pane.Buf:GetName())
				end)
				if name:sub(1, #PREVIEW_PREFIX) == PREVIEW_PREFIX then
					return tabs, i, pane.Buf
				end
			end
		end
	end
	return nil
end

local function set_preview_buffer(buf, name, rendered)
	pcall(function()
		buf:SetOption("readonly", false)
	end)
	local old = buffer_text(buf)
	if #old > 0 then
		pcall(function()
			buf:Remove(buffer.Loc(0, 0), buffer_end_loc(buf))
		end)
	end
	buf:Insert(buffer.Loc(0, 0), rendered)
	pcall(function()
		buf:SetName(name)
	end)
	set_filetype(buf, "markdown", true)
	pcall(function()
		buf:SetOption("readonly", true)
	end)
end

local function show_preview(bp, label, rendered)
	local name = PREVIEW_PREFIX .. label
	local tabs, idx, buf = find_preview_tab()
	if buf ~= nil then
		set_preview_buffer(buf, name, rendered)
		pcall(function()
			tabs:SetActive(idx - 1)
		end)
		micro.InfoBar():Message("shinny: 预览已更新")
		return
	end

	local ok = pcall(function()
		bp:AddTab()
	end)
	if ok then
		tabs = micro.Tabs()
		local tab = tabs.List[#tabs.List]
		local pane = tab and tab.Panes[1]
		if pane ~= nil and pane.Buf ~= nil then
			set_preview_buffer(pane.Buf, name, rendered)
			micro.InfoBar():Message("shinny: 预览已打开")
			return
		end
	end

	-- fallback: split (older micro without AddTab)
	local pane = find_pane_by_name(name)
	if pane == nil then
		local b = buffer.NewBuffer("", "")
		b:SetName(name)
		pane = bp:VSplitIndex(b, true)
	end
	if pane ~= nil and pane.Buf ~= nil then
		set_preview_buffer(pane.Buf, name, rendered)
		micro.InfoBar():Message("shinny: 预览已更新")
	end
end

function shinny_preview(bp, args)
	if bp == nil then
		micro.InfoBar():Error("shinny: 没有活动窗格")
		return
	end

	local name = tostr(bp.Buf:GetName())
	local text = nil
	local label = nil
	local chat = chats[name] or chats_by_input[name]
	if chat ~= nil and (is_chat_name(name) or is_input_name(name)) then
		for i = #chat.messages, 1, -1 do
			local m = chat.messages[i]
			if m.role == "assistant" then
				text = m.display or m.content or ""
				label = "chat answer"
				break
			end
		end
		if text == nil or text == "" then
			micro.InfoBar():Error("shinny: 还没有回答可预览")
			return
		end
	else
		local arg = trim(join_args(args))
		if arg ~= "" then
			if arg:sub(1, 2) == "~/" then
				arg = tostr(os.Getenv("HOME")) .. arg:sub(2)
			end
			text = read_text_file(arg)
			if text == nil then
				micro.InfoBar():Error("shinny: 读不到文件 " .. arg)
				return
			end
			label = basename(arg)
		else
			text = buffer_text(bp.Buf)
			label = chat_label(name)
		end
		if text == "" then
			micro.InfoBar():Error("shinny: 当前 buffer 是空的")
			return
		end
	end

	local dir = config.ConfigDir .. "/shinny"
	pcall(os.MkdirAll, dir, 448)
	local path = dir .. "/preview.md"
	local ok = pcall(ioutil.WriteFile, path, text, 384)
	if not ok then
		micro.InfoBar():Error("shinny: 无法写入预览临时文件")
		return
	end

	local rendered = render_markdown(path)
	if rendered == nil or rendered == "" then
		rendered = text
		micro.InfoBar():Message("shinny: rich 不可用，显示 Markdown 原文")
	end
	local target = bp
	if chat ~= nil then
		target = chat.src_pane or chat.pane or bp
	end
	show_preview(target, label, rendered)
end

function shinny_chat(bp, args)
	if bp == nil then
		micro.InfoBar():Error("shinny: 没有活动窗格")
		return
	end

	local name = bp.Buf:GetName()
	if is_input_name(name) then
		local chat = chats_by_input[name]
		if chat ~= nil then
			focus_input(chat)
		end
		return
	end
	if is_chat_name(name) then
		local chat = chats[name]
		if chat ~= nil then
			focus_input(chat)
		end
		return
	end

	local chat = chat_for(bp)
	if chat == nil then
		micro.InfoBar():Error("shinny: 无法创建 chat")
		return
	end
	if not switch_chat_ui(bp, chat) then
		return
	end
	ensure_chat_panes(bp, chat)
	focus_input(chat)
end

function init()
	load_state()

	config.RegisterGlobalOption("shinny", "prefix", DEFAULT_PREFIX)
	config.RegisterGlobalOption("shinny", "suffix", "")
	config.RegisterGlobalOption("shinny", "backend", "tavily")
	config.RegisterGlobalOption("shinny", "maxresults", 5)
	config.RegisterGlobalOption("shinny", "depth", "basic")
	config.RegisterGlobalOption("shinny", "includeanswer", true)
	config.RegisterGlobalOption("shinny", "apikey", "")
	config.RegisterGlobalOption("shinny", "endpoint", DEFAULT_ENDPOINT)
	config.RegisterGlobalOption("shinny", "deepseekkey", "")
	config.RegisterGlobalOption("shinny", "deepseektoolsurl", DEFAULT_DS_SEARCH)
	config.RegisterGlobalOption("shinny", "chaturl", DEFAULT_DS_CHAT)
	config.RegisterGlobalOption("shinny", "chatmodel", DEFAULT_MODEL)
	config.RegisterGlobalOption("shinny", "thinking", true)
	config.RegisterGlobalOption("shinny", "effort", DEFAULT_EFFORT)
	config.RegisterGlobalOption("shinny", "chatcontext", 24000)
	config.RegisterGlobalOption("shinny", "chattokenbudget", 24000)
	config.RegisterGlobalOption("shinny", "showthinking", false)
	config.RegisterGlobalOption("shinny", "imagedetail", "auto")
	config.RegisterGlobalOption("shinny", "imagemaxmb", 12)

	apply_state()

	config.MakeCommand("shinny", shinny, config.NoComplete)
	config.MakeCommand("shinny-raw", shinny_raw, config.NoComplete)
	config.MakeCommand("shinny-prefix", shinny_prefix, config.NoComplete)
	config.MakeCommand("shinny-suffix", shinny_suffix, config.NoComplete)
	config.MakeCommand("shinny-backend", shinny_backend, config.NoComplete)
	config.MakeCommand("shinny-chat", shinny_chat, config.NoComplete)
	config.MakeCommand("shinny-help", shinny_help, config.NoComplete)
	config.MakeCommand("shinny-chat-new", shinny_chat_new, config.NoComplete)
	config.MakeCommand("shinny-usage", shinny_usage, config.NoComplete)
	config.MakeCommand("shinny-chat-stop", shinny_chat_stop, config.NoComplete)
	config.MakeCommand("shinny-image", shinny_image, config.NoComplete)
	config.MakeCommand("shinny-image-url", shinny_image_url, config.NoComplete)
	config.MakeCommand("shinny-image-clear", shinny_image_clear, config.NoComplete)
	config.MakeCommand("shinny-image-detail", shinny_image_detail, config.NoComplete)
	config.MakeCommand("shinny-chat-newline", shinny_chat_newline, config.NoComplete)
	config.MakeCommand("shinny-preview", shinny_preview, config.NoComplete)
	config.MakeCommand("shinny-model", shinny_model, config.NoComplete)
	config.MakeCommand("shinny-thinking", shinny_thinking, config.NoComplete)
	config.MakeCommand("shinny-effort", shinny_effort, config.NoComplete)
	config.AddRuntimeFile("shinny", config.RTHelp, "help/shinny.md")
	config.AddRuntimeFile("shinny", config.RTSyntax, "syntax/shinnychat.yaml")
	config.AddRuntimeFile("shinny", config.RTSyntax, "syntax/shinnyinput.yaml")
	config.AddRuntimeFile("shinny", config.RTSyntax, "syntax/shinnyresults.yaml")

	config.TryBindKey("Alt-i", "command:shinny-chat", false)
	config.TryBindKey("Alt-Enter", "command:shinny-chat-newline", false)
	config.TryBindKey("Alt-r", "command:shinny-preview", false)
	start_input_watch()
	if not WATCHDOG_STARTED then
		WATCHDOG_STARTED = true
		micro.After(5000000000, watch_chats)
	end
end
