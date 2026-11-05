VERSION = "0.1.0"

-- shinny: search the web with Tavily for the selected text and show the
-- results in a split. Run `> help shinny` inside micro for the fine print.

local micro = import("micro")
local config = import("micro/config")
local buffer = import("micro/buffer")
local shell = import("micro/shell")
local util = import("micro/util")
local os = import("os")
local strings = import("strings")

local DEFAULT_ENDPOINT = "https://api.tavily.com/search"
local DEFAULT_DEPTH = "basic"
local MAX_QUERY_BYTES = 380
local MAX_SNIPPET_BYTES = 480
local STATUS_MARKER = "__SHINNY_STATUS__"

-- The query, the key and the endpoint travel through the environment so that
-- the shell never has to quote user text.
local CURL_CMD = 'curl -sS --max-time 45 -X POST "$SHINNY_ENDPOINT"'
	.. ' -H "Content-Type: application/json"'
	.. ' -H "Authorization: Bearer $SHINNY_KEY"'
	.. ' --data-binary "$SHINNY_BODY"'
	.. ' -w "\\n' .. STATUS_MARKER .. ':%{http_code}"'

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

-- json_decode is a small JSON reader so the plugin does not depend on a
-- json library. It is only ever used on Tavily's response.
local function json_decode(input)
	local s = tostr(input)
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
			if pos > len then
				fail("unterminated string")
			end
			local c = s:sub(pos, pos)
			if c == '"' then
				pos = pos + 1
				return table.concat(pieces)
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

local function api_key()
	local env = os.Getenv("TAVILY_API_KEY")
	if env ~= nil and trim(env) ~= "" then
		return trim(env)
	end
	return trim(tostr(option("apikey", "")))
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

local function request_body(query, opts)
	return string.format(
		'{"query":"%s","max_results":%.0f,"include_answer":%s,"search_depth":"%s"}',
		json_escape(query),
		opts.max_results,
		opts.include_answer and "true" or "false",
		json_escape(opts.depth)
	)
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
			return collapse(data.error)
		end
		if data.message ~= nil then
			return collapse(data.message)
		end
	end
	return ""
end

local function render(query, data, opts)
	local out = {}
	local function add(line)
		out[#out + 1] = line
	end

	local results = data.results
	if type(results) ~= "table" then
		results = {}
	end

	add("shinny · " .. collapse(query))
	local meta = string.format("%d result(s) · %s", #results, opts.depth)
	if type(data.response_time) == "number" then
		meta = meta .. string.format(" · %.2fs", data.response_time)
	end
	add(meta)
	add("")

	if opts.include_answer and type(data.answer) == "string" and trim(data.answer) ~= "" then
		add("Answer")
		add(collapse(data.answer))
		add("")
	end

	if #results == 0 then
		add("No results.")
		return table.concat(out, "\n")
	end

	for i, result in ipairs(results) do
		if type(result) ~= "table" then
			result = {}
		end
		local title = collapse(result.title)
		if title == "" then
			title = "(untitled)"
		end
		add(string.format("%d. %s", i, title))
		local url = trim(result.url)
		if url ~= "" then
			add("   " .. url)
		end
		local content = collapse(result.content)
		if content ~= "" then
			add("   " .. shorten(content, MAX_SNIPPET_BYTES))
		end
		if type(result.score) == "number" then
			add(string.format("   score: %.3f", result.score))
		end
		add("")
	end

	return table.concat(out, "\n")
end

local function show_results(query, data, opts)
	local bp = micro.CurPane()
	if bp == nil then
		micro.InfoBar():Error("shinny: no pane to show the results in")
		return
	end
	local buf = buffer.NewBuffer(render(query, data, opts), "")
	buf:SetName("shinny: " .. shorten(query, 40))
	bp:VSplitBuf(buf)
end

local function finish(query, opts, output)
	local status, payload = split_output(output)
	if status == nil then
		micro.InfoBar():Error("shinny: could not run curl — " .. shorten(collapse(payload), 140))
		return
	end
	if status == 0 then
		micro.InfoBar():Error("shinny: could not reach Tavily — check your network")
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
	local ok, data = pcall(json_decode, payload)
	if not ok or type(data) ~= "table" then
		micro.InfoBar():Error("shinny: unexpected response from Tavily")
		return
	end
	if data.error ~= nil then
		micro.InfoBar():Error("shinny: " .. shorten(collapse(data.error), 160))
		return
	end
	show_results(query, data, opts)
	local count = 0
	if type(data.results) == "table" then
		count = #data.results
	end
	micro.InfoBar():Message(string.format("shinny: %d result(s)", count))
end

local function start_search(query)
	local key = api_key()
	if key == "" then
		micro.InfoBar():Error("shinny: no Tavily API key — run > set shinny.apikey <key>")
		return
	end

	query = clamp(query, MAX_QUERY_BYTES)
	if query == "" then
		micro.InfoBar():Error("shinny: nothing to search for")
		return
	end

	local opts = search_options()
	local endpoint = trim(tostr(option("endpoint", DEFAULT_ENDPOINT)))
	if endpoint == "" then
		endpoint = DEFAULT_ENDPOINT
	end

	os.Setenv("SHINNY_ENDPOINT", endpoint)
	os.Setenv("SHINNY_KEY", key)
	os.Setenv("SHINNY_BODY", request_body(query, opts))

	local ok, err = pcall(shell.JobStart, CURL_CMD, nil, nil, function(output)
		os.Setenv("SHINNY_KEY", "")
		os.Setenv("SHINNY_BODY", "")
		local ran, problem = pcall(finish, query, opts, output)
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

	micro.InfoBar():Message("shinny: searching…")
end

-- shinny is the command: `> shinny` searches the selection, `> shinny foo bar`
-- searches the given words.
function shinny(bp, args)
	local query = trim(join_args(args))
	if query == "" then
		query = selected_text(bp)
	end
	if query == "" then
		micro.InfoBar():Error("shinny: select some text first, or run > shinny <query>")
		return
	end
	start_search(query)
end

function init()
	config.RegisterGlobalOption("shinny", "apikey", "")
	config.RegisterGlobalOption("shinny", "maxresults", 5)
	config.RegisterGlobalOption("shinny", "depth", "basic")
	config.RegisterGlobalOption("shinny", "includeanswer", true)
	config.RegisterGlobalOption("shinny", "endpoint", DEFAULT_ENDPOINT)

	config.MakeCommand("shinny", shinny, config.NoComplete)
	config.AddRuntimeFile("shinny", config.RTHelp, "help/shinny.md")
end
