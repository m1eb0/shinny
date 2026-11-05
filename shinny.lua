VERSION = "0.2.2"

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

local function show_results(ctx, text)
	local bp = micro.CurPane()
	if bp == nil then
		micro.InfoBar():Error("shinny: no pane to show the results in")
		return
	end
	local buf = buffer.NewBuffer(text, "")
	buf:SetName("shinny: " .. shorten(ctx.full, 40))
	bp:VSplitBuf(buf)
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

local function render_chat(chat)
	local out = {}
	local function add(line)
		out[#out + 1] = line
	end
	local settings = chat_settings()
	local thinking_label = settings.thinking and ("thinking " .. settings.effort) or "no thinking"
	local rule = string.rep("─", 30)

	add(rule)
	add(" shinny chat · " .. chat.label)
	add(string.format(" %s · %s · %d files", settings.model, thinking_label, #open_buffers()))
	add(rule)
	add("")

	if #chat.messages == 0 then
		add(" 在下方输入栏（>）输入问题，Enter 发送。")
		add(" 例：解释光标处的代码")
		add("     把选区改写成更专业的语言 / 把这行改成英文")
		add("")
	end

	for _, m in ipairs(chat.messages) do
		add(m.role == "user" and "› you" or "› shinny")
		add("  " .. (tostr(m.content):gsub("\n", "\n  ")))
		add("")
	end

	if chat.busy then
		add("› shinny")
		add("  正在思考…")
		add("")
	end

	add(rule)
	add(" Enter 发送 · Alt-i 聚焦 · Ctrl-Z 撤销")
	return table.concat(out, "\n")
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

local function set_chat_text(chat, text)
	local buf = chat.buf
	if buf == nil then
		return
	end
	local old = chat.text or ""
	if #old > 0 then
		pcall(function()
			buf:Remove(buffer.Loc(0, 0), text_end_loc(old))
		end)
	end
	buf:Insert(buffer.Loc(0, 0), text)
	chat.text = text

	local end_loc = text_end_loc(text)
	local loc = buffer.Loc(0, end_loc.Y)
	pcall(function()
		buf:GetActiveCursor():GotoLoc(loc)
	end)
	if chat.pane ~= nil then
		pcall(function()
			chat.pane:GotoLoc(loc)
		end)
	end
end

local function chat_key()
	local env = trim(os.Getenv("DEEPSEEK_API_KEY"))
	if env ~= "" then
		return env
	end
	return trim(tostr(option("deepseekkey", "")))
end

local function normalize_effort(value)
	value = trim(tostr(value)):lower()
	if value == "minimal" or value == "medium" or value == "xhigh" then
		return value == "minimal" and "low" or "high"
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

local function chat_body(chat, context)
	local settings = chat_settings()
	local msgs = {}
	local function add(role, content)
		msgs[#msgs + 1] = string.format('{"role":"%s","content":"%s"}', role, json_escape(content))
	end
	add("system", context)
	local start = math.max(1, #chat.messages - 12)
	for i = start, #chat.messages do
		add(chat.messages[i].role, chat.messages[i].content)
	end

	local parts = {
		'"model":"' .. json_escape(settings.model) .. '"',
		'"messages":[' .. table.concat(msgs, ",") .. ']',
		'"stream":false',
	}
	if settings.thinking then
		parts[#parts + 1] = '"thinking":{"type":"enabled"}'
		parts[#parts + 1] = '"reasoning_effort":"' .. json_escape(settings.effort) .. '"'
	else
		parts[#parts + 1] = '"thinking":{"type":"disabled"}'
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

local function append_message(chat, role, content)
	chat.messages[#chat.messages + 1] = { role = role, content = tostr(content) }
	set_chat_text(chat, render_chat(chat))
end

local function finish_chat(chat, output)
	local status, payload = split_output(output)
	if status == nil then
		append_message(chat, "assistant", "（请求没有返回：curl 没有输出）")
		return
	end
	if status < 200 or status >= 300 then
		local detail = error_detail(payload)
		if detail == "" then
			detail = "HTTP " .. tostr(status)
		end
		append_message(chat, "assistant", "（请求失败：" .. shorten(detail, 300) .. "）")
		return
	end
	local ok, data = pcall(json_decode, payload)
	if not ok or type(data) ~= "table" then
		last_response = payload
		append_message(chat, "assistant", "（响应不是 JSON，运行 > shinny-raw 查看）")
		return
	end
	last_response = payload

	local content = nil
	local choices = data.choices
	if type(choices) == "table" and choices[1] and type(choices[1]) == "table" then
		local message = choices[1].message
		if type(message) == "table" then
			content = message.content
		end
	end
	if type(content) ~= "string" or trim(content) == "" then
		local detail = error_detail(payload)
		if detail == "" then
			detail = "没有拿到回复内容"
		end
		append_message(chat, "assistant", "（" .. shorten(detail, 300) .. "）")
		return
	end

	local cleaned, notes = apply_edits(chat, content)
	local shown = cleaned
	if #notes > 0 then
		shown = (shown ~= "" and shown .. "\n\n" or "") .. "[已应用到文件] " .. table.concat(notes, "；")
	end
	append_message(chat, "assistant", shown)
	micro.InfoBar():Message("shinny: 回复完成")
end

local function send_chat(chat, question)
	if chat.busy then
		micro.InfoBar():Error("shinny: 上一个问题还在处理中")
		return false
	end
	local key = chat_key()
	if key == "" then
		micro.InfoBar():Error("shinny: 没有 DeepSeek key — 运行 > set shinny.deepseekkey <key>")
		return false
	end

	chat.busy = true
	append_message(chat, "user", question)

	local body = chat_body(chat, build_context(chat))
	local url = trim(tostr(option("chaturl", DEFAULT_DS_CHAT)))
	if url == "" then
		url = DEFAULT_DS_CHAT
	end

	os.Setenv("SHINNY_ENDPOINT", url)
	os.Setenv("SHINNY_KEY", key)
	os.Setenv("SHINNY_BODY", body)
	micro.InfoBar():Message("shinny: thinking…")

	local ok, err = pcall(shell.JobStart, curl_cmd(120), nil, nil, function(output)
		os.Setenv("SHINNY_KEY", "")
		os.Setenv("SHINNY_BODY", "")
		chat.busy = false
		local ran, problem = pcall(finish_chat, chat, output)
		if not ran then
			append_message(chat, "assistant", "（内部错误：" .. shorten(collapse(problem), 300) .. "）")
		end
	end)

	if not ok then
		chat.busy = false
		os.Setenv("SHINNY_KEY", "")
		os.Setenv("SHINNY_BODY", "")
		append_message(chat, "assistant", "（无法启动请求：" .. shorten(collapse(err), 300) .. "）")
		return true
	end
	return true
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

local function ensure_chat_panes(bp, chat)
	local tpane = find_pane_by_name(chat.name)
	local ipane = find_pane_by_name(chat.input_name)

	if tpane == nil then
		local tbuf = buffer.NewBuffer("", "")
		tbuf:SetName(chat.name)
		chat.buf = tbuf
		chat.text = ""
		tpane = bp:VSplitIndex(tbuf, true)
		chat.pane = tpane
	end

	if ipane == nil then
		if chat.ibuf == nil then
			chat.ibuf = buffer.NewBuffer(INPUT_PROMPT, "")
			chat.ibuf:SetName(chat.input_name)
		end
		ipane = tpane:HSplitIndex(chat.ibuf, true)
		chat.ipane = ipane
		reset_input(chat)
		local tab = bp:Tab()
		local ok, h = pcall(function()
			return tab.H
		end)
		if ok and type(h) == "number" and h > 10 then
			pcall(function()
				ipane:ResizePane(h - 6)
			end)
		end
	end

	if chat.buf == nil then
		chat.buf = tpane.Buf
	end
	set_chat_text(chat, render_chat(chat))
	focus_input(chat)
end

function preInsertNewline(bp)
	if bp == nil then
		return true
	end
	local chat = chats_by_input[tostr(bp.Buf:GetName())]
	if chat == nil then
		return true
	end
	if chat.busy then
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
			buf = nil,
			pane = nil,
			ibuf = nil,
			ipane = nil,
			src_pane = bp,
			busy = false,
			text = "",
		}
		chats[chat_name] = chat
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

	apply_state()

	config.MakeCommand("shinny", shinny, config.NoComplete)
	config.MakeCommand("shinny-raw", shinny_raw, config.NoComplete)
	config.MakeCommand("shinny-prefix", shinny_prefix, config.NoComplete)
	config.MakeCommand("shinny-suffix", shinny_suffix, config.NoComplete)
	config.MakeCommand("shinny-backend", shinny_backend, config.NoComplete)
	config.MakeCommand("shinny-chat", shinny_chat, config.NoComplete)
	config.MakeCommand("shinny-model", shinny_model, config.NoComplete)
	config.MakeCommand("shinny-thinking", shinny_thinking, config.NoComplete)
	config.MakeCommand("shinny-effort", shinny_effort, config.NoComplete)
	config.AddRuntimeFile("shinny", config.RTHelp, "help/shinny.md")

	config.TryBindKey("Alt-i", "command:shinny-chat", false)
end
