--!strict
-- Rewrites a Markdown file into the Markdown Tern's renderer draws the way GitHub would show the file:
--   * relative link and image targets become absolute paths (a canvas has no directory of its own);
--   * HTML blocks and the inline HTML READMEs lean on (<img>, <a>, <p align>, <h1>, <details>, <br>, <b>, <kbd>,
--     comments, …) become Markdown, since the renderer prints raw HTML as text; an HTML block flows as one
--     paragraph (badge rows stay on one line) and `align="center"` blocks come back as centered segments;
--   * a sized <img> stays an inline <img> with its width/height, the one tag the renderer sizes itself;
--   * HTML tables come back as table segments whose cells are rendered like a file of their own;
--   * emoji shortcodes become emoji; footnotes become superscript numbers with their notes listed at the end.
-- Fenced code and inline code spans pass through untouched.

local EMOJI: { [string]: string } = require("./emoji")

local M = {}

-- One cell of an HTML table: its content as Markdown, `th` or not, and the attributes the view keeps.
export type Cell = { md: string, head: boolean, colspan: string?, rowspan: string?, align: string? }

-- A run of Markdown, or an HTML table (then `md` is empty), centered or not.
export type Segment = { md: string, center: boolean, table: { { Cell } }? }

local SUPERSCRIPT = { ["0"] = "⁰", ["1"] = "¹", ["2"] = "²", ["3"] = "³", ["4"] = "⁴", ["5"] = "⁵", ["6"] = "⁶", ["7"] = "⁷", ["8"] = "⁸", ["9"] = "⁹" }

local function superscript(n: number): string
	return (string.gsub(tostring(n), "%d", SUPERSCRIPT))
end

local function url_decode(s: string): string
	return (string.gsub(s, "%%(%x%x)", function(h)
		return string.char(tonumber(h, 16) :: number)
	end))
end

-- `path` with `.` and `..` segments folded away.
function M.normalize(path: string): string
	local out = {}
	for seg in string.gmatch(path, "[^/]+") do
		if seg == ".." then
			if #out > 0 then
				table.remove(out)
			end
		elseif seg ~= "." then
			table.insert(out, seg)
		end
	end
	return "/" .. table.concat(out, "/")
end

function M.dirname(path: string): string
	return string.match(path, "^(.*)/[^/]*$") or "/"
end

-- A link target as written resolved against `dir`: relative paths become absolute (fragment kept), anything with
-- a scheme, an absolute path or a bare #fragment comes back unchanged.
function M.resolve(target: string, dir: string): string
	if target == "" or string.match(target, "^%a[%w+.-]*:") or string.sub(target, 1, 1) == "#" or string.sub(target, 1, 1) == "/" then
		return target
	end
	local path, rest = string.match(target, "^([^#?]*)(.*)$")
	return M.normalize(dir .. "/" .. url_decode(path :: string)) .. (rest :: string)
end

-- A destination safe to write back into `(…)`: angle brackets when it holds spaces or parentheses.
local function destination(target: string): string
	if string.find(target, "[%s()]") then
		return "<" .. target .. ">"
	end
	return target
end

-- The inside of `(…)` after `]`: destination, then an optional title.
local function rewrite_destination(inner: string, dir: string): string
	-- `(<a (b)>)` cut at its first `)`: leave it as written.
	if string.match(inner, "^%s*<[^>]*$") then
		return inner
	end
	local target, rest = string.match(inner, "^%s*<([^>]*)>(.*)$")
	if not target then
		target, rest = string.match(inner, "^%s*(%S*)(.*)$")
	end
	local resolved = M.resolve(target :: string, dir)
	if resolved == target then
		return inner
	end
	return destination(resolved) .. (rest :: string)
end

local function attr(tag: string, name: string): string?
	return string.match(tag, "%s" .. name .. "%s*=%s*\"([^\"]*)\"")
		or string.match(tag, "%s" .. name .. "%s*=%s*'([^']*)'")
		or string.match(tag, "%s" .. name .. "%s*=%s*([^%s>\"']+)")
end

-- An <img>'s `width` or `height` as pixels (`"250"`) or a percentage (`"50%"`), from the attribute or the inline
-- style; nil when it gives none.
local function size(tag: string, dim: string): string?
	local n, pct = string.match(attr(tag, dim) or "", "^%s*(%d+%.?%d*)%s*(%%?)")
	if not n then
		n, pct = string.match(attr(tag, "style") or "", "%f[%w%-]" .. dim .. "%s*:%s*(%d+%.?%d*)%s*(%%?)")
	end
	return if n then n .. pct else nil
end

local function file_url(path: string): string
	return "file://" .. string.gsub(path, "[^%w%-%._~/]", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
end

-- Where text being converted sits: a Markdown line, a table row (no line breaks allowed) or an HTML block
-- (block tags break paragraphs).
type Mode = "inline" | "table" | "block"

type State = {
	dir: string,
	comment: boolean,
	links: { string | false },
	notes: { [string]: number },
	order: { string },
}

local INLINE_TAGS: { [string]: string } = {
	b = "**", strong = "**", i = "_", em = "_", del = "~~", s = "~~", strike = "~~",
	code = "`", kbd = "`", tt = "`",
}

-- Tags that start a new paragraph in an HTML block; elsewhere, like every other unknown tag, they vanish and
-- their content stays.
local BLOCK_TAGS = {
	p = true, div = true, center = true, details = true, table = true, tr = true, ul = true, ol = true, li = true,
	blockquote = true, section = true, article = true, header = true, footer = true,
}

local DROP_TAGS = {
	span = true, picture = true, source = true, sup = true, sub = true, ins = true, u = true, small = true,
	big = true, thead = true, tbody = true, td = true, th = true, font = true,
}

-- One tag (`<…>` text) as Markdown.
local function convert_tag(tag: string, st: State, mode: Mode): string
	local closing, name = string.match(tag, "^<(/?)([%a][%w]*)")
	if not name then
		return tag
	end
	name = string.lower(name)
	local block = mode == "block"
	if name == "img" then
		local src = attr(tag, "src")
		if not src then
			return ""
		end
		local alt = string.gsub(attr(tag, "alt") or "", "[%[%]\"]", "")
		local resolved = M.resolve(src, st.dir)
		local width, height = size(tag, "width"), size(tag, "height")
		if not width and not height then
			return "![" .. alt .. "](" .. destination(resolved) .. ")"
		end
		-- Tern's renderer sizes an inline <img> by its width and height attributes.
		local url = if string.sub(resolved, 1, 1) == "/" then file_url(resolved) else resolved
		return "<img src=\"" .. url .. "\""
			.. (if width then " width=\"" .. width .. "\"" else "")
			.. (if height then " height=\"" .. height .. "\"" else "")
			.. " alt=\"" .. alt .. "\">"
	elseif name == "a" then
		if closing == "/" then
			local href = table.remove(st.links)
			return if href then "](" .. destination(href) .. ")" else ""
		end
		local href = attr(tag, "href")
		table.insert(st.links, if href then M.resolve(href, st.dir) else false)
		return if href then "[" else ""
	elseif name == "br" then
		return if mode == "table" then " " else "\n"
	elseif name == "hr" then
		return if mode == "table" then "" else "\n\n---\n\n"
	elseif name == "summary" then
		if not block then
			return "**"
		end
		return if closing == "/" then "**\n\n" else "\n\n**"
	elseif string.match(name, "^h[1-6]$") then
		if closing == "/" then
			return if block then "\n\n" else ""
		end
		return (if block then "\n\n" else "") .. string.rep("#", tonumber(string.sub(name, 2)) :: number) .. " "
	elseif INLINE_TAGS[name] then
		return INLINE_TAGS[name]
	elseif BLOCK_TAGS[name] then
		return if block then "\n\n" else ""
	elseif DROP_TAGS[name] then
		return if name == "td" or name == "th" then " " else ""
	end
	return tag
end

-- Text outside code spans: comments, HTML, footnote references and link destinations.
local function convert_text(text: string, st: State, mode: Mode): string
	local out = {}
	local i = 1
	while i <= #text do
		if st.comment then
			local e = string.find(text, "-->", i, true)
			if not e then
				break
			end
			st.comment = false
			i = e + 3
		else
			local s = string.find(text, "<!--", i, true)
			local chunk = string.sub(text, i, (s or #text + 1) - 1)
			-- `](destination)` first, so the destinations converted tags write are left alone; then footnote
			-- references, then HTML tags.
			chunk = string.gsub(chunk, "%]%(([^%)]*)%)", function(inner)
				return "](" .. rewrite_destination(inner, st.dir) .. ")"
			end)
			chunk = string.gsub(chunk, "%[%^([^%]%s]+)%]", function(id)
				local n = st.notes[id]
				if not n then
					table.insert(st.order, id)
					n = #st.order
					st.notes[id] = n
				end
				return superscript(n)
			end)
			chunk = string.gsub(chunk, ":([%w_+%-]+):", function(code)
				return EMOJI[code]
			end)
			-- Adjacent keycaps (`<kbd>⌘</kbd><kbd>R</kbd>`) would turn into "`⌘``R`", one code span with backticks
			-- in it; a thin space keeps them two.
			chunk = string.gsub(chunk, "(</(%a+)>)(<(%a+)>)", function(close, a, open, b)
				if INLINE_TAGS[string.lower(a)] == "`" and INLINE_TAGS[string.lower(b)] == "`" then
					return close .. "\u{2009}" .. open
				end
				return nil
			end)
			chunk = string.gsub(chunk, "</?[%a][%w]*[^>]*>", function(tag)
				return convert_tag(tag, st, mode)
			end)
			table.insert(out, chunk)
			if not s then
				break
			end
			st.comment = true
			i = s + 4
		end
	end
	return table.concat(out)
end

-- Text outside fenced code with its code spans passed through.
local function convert(line: string, st: State, mode: Mode): string
	local out = {}
	local i = 1
	while i <= #line do
		local s, e = string.find(line, "`+", i)
		if not s or st.comment then
			table.insert(out, convert_text(string.sub(line, i), st, mode))
			break
		end
		local ticks = string.sub(line, s :: number, e :: number)
		local close = string.find(line, ticks, (e :: number) + 1, true)
		table.insert(out, convert_text(string.sub(line, i, (s :: number) - 1), st, mode))
		if not close then
			table.insert(out, string.sub(line, s :: number))
			break
		end
		table.insert(out, string.sub(line, s :: number, close + #ticks - 1))
		i = close + #ticks
	end
	return table.concat(out)
end

-- An HTML block (its lines joined) as Markdown lines, each unindented so none turns into indented code.
local function convert_block(raw: string, st: State): { string }
	local lines = {}
	for line in string.gmatch(convert(raw, st, "block") .. "\n", "([^\n]*)\n") do
		local trimmed = string.match(line, "^%s*(.-)%s*$") :: string
		-- Collapse runs of blank lines.
		if trimmed ~= "" or (#lines > 0 and lines[#lines] ~= "") then
			table.insert(lines, trimmed)
		end
	end
	return lines
end

local function blank(line: string): boolean
	return string.match(line, "^%s*$") ~= nil
end

local function count(s: string, pattern: string): number
	local _, n = string.gsub(s, pattern, "")
	return n
end

local function table_depth(line: string): number
	local low = string.lower(line)
	return count(low, "<table[%s>]") - count(low, "</table%s*>")
end

-- A cell's text without the indentation its HTML nesting gave it: the first line (after the opening tag) is
-- trimmed, the rest lose the indentation they share, so Markdown written inside a cell still parses.
local function dedent(text: string): string
	local lines = {}
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		table.insert(lines, line)
	end
	local min = math.huge
	for n = 2, #lines do
		if not blank(lines[n]) then
			min = math.min(min, #(string.match(lines[n], "^[ \t]*") :: string))
		end
	end
	lines[1] = string.gsub(lines[1], "^%s+", "")
	for n = 2, #lines do
		lines[n] = if min == math.huge then lines[n] else string.sub(lines[n], min + 1)
	end
	return table.concat(lines, "\n")
end

-- The elements in `s` opened by `open` (a pattern capturing the tag name, matched against `low`, `s` lowercased),
-- each with its opening tag and inner text. Same-name nesting isn't tracked; an unclosed element runs to the
-- next one's start.
local function elements(s: string, low: string, open: string): { { tag: string, name: string, inner: string } }
	local out = {}
	local i = 1
	while true do
		local a, _, name = string.find(low, open, i)
		local gt = a and string.find(low, ">", a, true)
		if not a or not gt then
			break
		end
		local ca, cb = string.find(low, "</" .. name .. "%s*>", gt + 1)
		local na = string.find(low, open, gt + 1)
		if not ca or (na and na < ca) then
			ca = na or #s + 1
			cb = (ca :: number) - 1
		end
		table.insert(out, { tag = string.sub(s, a, gt), name = name, inner = string.sub(s, gt + 1, (ca :: number) - 1) })
		i = (cb :: number) + 1
	end
	return out
end

-- The rows of an HTML table (`raw`, `<table …>` through `</table>`), each cell's content rendered as Markdown.
local function parse_table(raw: string, dir: string): { { Cell } }
	local rows = {}
	for _, tr in elements(raw, string.lower(raw), "<(tr)[%s>]") do
		local cells: { Cell } = {}
		for _, td in elements(tr.inner, string.lower(tr.inner), "<(t[dh])[%s>]") do
			local parts = {}
			for _, seg in M.render(dedent(td.inner), dir) do
				if not seg.table and not blank(seg.md) then
					table.insert(parts, seg.md)
				end
			end
			local align = attr(td.tag, "align") or string.match(attr(td.tag, "style") or "", "text%-align%s*:%s*(%a+)")
			table.insert(cells, {
				md = table.concat(parts, "\n\n"),
				head = td.name == "th",
				colspan = attr(td.tag, "colspan"),
				rowspan = attr(td.tag, "rowspan"),
				align = if align then string.lower(align) else nil,
			})
		end
		if #cells > 0 then
			table.insert(rows, cells)
		end
	end
	return rows
end

-- The segments to render for `text`, a file in directory `dir`.
function M.render(text: string, dir: string): { Segment }
	local st: State = { dir = dir, comment = false, links = {}, notes = {}, order = {} }
	local segments: { Segment } = {}
	local cur: { string } = {}
	local center = false
	-- Inside `<div align="center">` … `</div>` spanning Markdown: the open p/div/center depth, else 0.
	local region = 0
	-- Reference definitions (`[id]: target`), repeated in every segment so links resolve across them.
	local refs: { string } = {}
	local defs: { [string]: string } = {}
	local fence: string? = nil
	local def: string? = nil
	local html: { string }? = nil
	-- Open <table> depth in `html`: a table's blank lines (Markdown in cells) don't end the block.
	local tables = 0

	local function push(line: string, centered: boolean)
		if centered ~= center then
			if #cur > 0 then
				table.insert(segments, { md = table.concat(cur, "\n"), center = center })
			end
			cur = {}
			center = centered
		end
		table.insert(cur, line)
	end

	-- HTML outside tables: one flowing paragraph, centered by `align="center"`.
	local function flush_flow(raw: string)
		local low = string.lower(raw)
		local aligned = string.find(low, "align%s*=%s*[\"']?center") ~= nil or string.find(low, "<center>", 1, true) ~= nil
		local depth = count(low, "<div[%s>]") + count(low, "<p[%s>]") + count(low, "<center>")
			- count(low, "</div%s*>") - count(low, "</p%s*>") - count(low, "</center%s*>")
		local centered = region > 0 or aligned
		if region > 0 then
			region = math.max(region + depth, 0)
		elseif aligned and depth > 0 then
			region = depth
		end
		for _, l in convert_block(raw, st) do
			push(l, centered)
		end
		push("", centered)
	end

	local function flush_html()
		-- Whole comments go first, so a commented-out table stays hidden.
		local raw = string.gsub(table.concat(html :: { string }, "\n"), "<!%-%-.-%-%->", "")
		html = nil
		tables = 0
		local low = string.lower(raw)
		local i = 1
		while true do
			local a = string.find(low, "<table[%s>]", i)
			local flow = string.sub(raw, i, if a then a - 1 else #raw)
			if not blank(flow) then
				flush_flow((string.gsub(flow, "\n", " ")))
			end
			if not a then
				break
			end
			local _, b = string.find(low, "</table%s*>", a)
			local stop = b or #raw
			local open = string.match(raw, "^<[^>]*>", a) or ""
			if #cur > 0 then
				table.insert(segments, { md = table.concat(cur, "\n"), center = center })
				cur = {}
			end
			table.insert(segments, {
				md = "",
				center = region > 0 or string.lower(attr(open, "align") or "") == "center",
				table = parse_table(string.sub(raw, a, stop), st.dir),
			})
			i = stop + 1
		end
	end

	for line in string.gmatch((string.gsub(text, "\r\n", "\n")) .. "\n", "([^\n]*)\n") do
		if html then
			-- An HTML block runs to a blank line, unless a comment or table is still open.
			if blank(line) and not st.comment and tables <= 0 then
				flush_html()
			else
				table.insert(html, line)
				tables += table_depth(line)
			end
		elseif fence then
			push(line, region > 0)
			local run = string.match(line, "^%s*([`~]+)%s*$")
			if run and string.sub(run, 1, 1) == string.sub(fence, 1, 1) and #run >= #fence then
				fence = nil
			end
		elseif string.match(line, "^%s*[`~][`~][`~]") then
			local run, info = string.match(line, "^%s*([`~]+)(.*)$")
			-- A backtick fence's info string holds no backticks; a line like ```x``` is a code span.
			if string.sub(run :: string, 1, 1) == "~" or not string.find(info :: string, "`", 1, true) then
				fence = run
			end
			push(line, region > 0)
			def = nil
		elseif string.match(line, "^ ? ? ?<[%a/!]") then
			html = { line }
			tables = table_depth(line)
			def = nil
		else
			local id, body = string.match(line, "^%[%^([^%]%s]+)%]:%s*(.*)$")
			if id then
				defs[id] = body :: string
				def = id
			elseif def and string.match(line, "^%s%s%s%s") then
				defs[def] ..= " " .. string.gsub(line, "^%s+", "")
			else
				def = nil
				local ref, target = string.match(line, "^%s*(%[[^%]]+%]:%s*)(%S+)")
				if ref then
					local rest = string.sub(line, #(string.match(line, "^%s*") :: string) + #ref + #target + 1)
					local resolved = M.resolve((string.gsub(target :: string, "^<(.*)>$", "%1")), dir)
					table.insert(refs, (ref :: string) .. destination(resolved) .. rest)
				else
					push(convert(line, st, if string.match(line, "^%s*|") then "table" else "inline"), region > 0)
				end
			end
		end
	end
	if html then
		flush_html()
	end

	-- Notes in order of first reference, then any never referenced.
	for id in defs do
		if not st.notes[id] then
			table.insert(st.order, id)
			st.notes[id] = #st.order
		end
	end
	local listed = {}
	for n, id in st.order do
		if defs[id] then
			table.insert(listed, n .. ". " .. convert(defs[id], st, "inline"))
		end
	end
	if #listed > 0 then
		push("\n---\n", false)
		push(table.concat(listed, "\n"), false)
	end
	if #cur > 0 or #segments == 0 then
		table.insert(segments, { md = table.concat(cur, "\n"), center = center })
	end
	if #refs > 0 then
		local tail = "\n\n" .. table.concat(refs, "\n")
		for _, s in segments do
			if not s.table then
				s.md ..= tail
			end
		end
	end
	return segments
end

return M
