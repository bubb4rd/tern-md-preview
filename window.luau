--!strict
-- Markdown Preview, window half. Shows Markdown files rendered in canvases styled like Tern's agent chat reader,
-- following the file (unsaved edits included) as it changes.
--   ⌥⌘V (palette: "Markdown: Toggle source / rendered") swaps a Markdown file block for its rendered view in the
--   same slot, and back. (⇧⌘V stays Tern's own toggle between a file block's source and its editable rendering.)
--   ⌥⇧⌘V (palette: "Markdown: Preview beside") opens the rendered view beside the file, to watch while editing.
--   The Files pane's eye button renders the selected Markdown file.
--   Clicking a Markdown file link in an agent chat floats the rendered view over the chat (⌘-click still opens the
--   source); clicking one inside a rendered view follows it there, like GitHub.

local R = require("./render")

local OWNER = "md-preview"
local MD_EXT = { md = true, markdown = true, mdown = true, mkd = true, mkdn = true }
-- Canvas updates cap at 256 KiB and 2000 nodes; leave room for the wrapping nodes.
local MAX_BYTES = 240 * 1024
local MAX_NODES = 1900
local POLL_MS = 400

local function is_md(path: string): boolean
	local ext = string.match(path, "%.([%w]+)$")
	return ext ~= nil and MD_EXT[string.lower(ext)] == true
end

local function basename(path: string): string
	return string.match(path, "([^/]+)$") or path
end

local function url_decode(s: string): string
	return (string.gsub(s, "%%(%x%x)", function(h)
		return string.char(tonumber(h, 16) :: number)
	end))
end

-- The local Markdown file a link, URL or path names, or nil. Accepts file:// URLs, absolute paths, ~/ paths and
-- paths relative to `dir`, with an optional :LINE[:COL] suffix or #fragment.
local function md_target(target: string, dir: string?): string?
	local path = target
	if string.sub(path, 1, 7) == "file://" then
		path = url_decode((string.gsub(string.gsub(string.sub(path, 8), "^localhost/", "/"), "[?#].*$", "")))
	elseif string.match(path, "^%a[%w+.-]*:") or string.sub(path, 1, 1) == "#" then
		return nil
	else
		path = string.gsub(path, "#.*$", "")
	end
	path = string.gsub(string.gsub(path, ":%d+:%d+$", ""), ":%d+$", "")
	if string.sub(path, 1, 2) == "~/" then
		local home = tern.getenv("HOME")
		if not home then
			return nil
		end
		path = home .. string.sub(path, 2)
	elseif string.sub(path, 1, 1) ~= "/" then
		if not dir or dir == "" then
			return nil
		end
		path = R.normalize(dir .. "/" .. url_decode(path))
	end
	if not is_md(path) or not tern.fs.exists(path) then
		return nil
	end
	return path
end

-- A canvas remembers its file in `about`'s first line, so previews keep following their files across reloads.
local ABOUT_PREFIX = "md-preview:"

local function about(path: string): string
	return ABOUT_PREFIX .. path .. "\nRead-only rendered view of this Markdown file; it follows the file as it changes."
end

-- The file one of this plugin's canvases shows, from its CanvasInfo; nil for other canvases.
local function file_of(c: any): string?
	if not c or c.owner ~= OWNER or string.sub(c.about, 1, #ABOUT_PREFIX) ~= ABOUT_PREFIX then
		return nil
	end
	return string.match(c.about, "^[^\n]+", #ABOUT_PREFIX + 1)
end

local function canvas_file(cx: any, pane: number): string?
	return file_of(cx.canvas:get(pane))
end

-- An HTML table as table nodes, cells drawn as Markdown; `mdp-al-*` classes carry cell alignment.
local function table_node(rows: { { R.Cell } }): any
	local trs = {}
	for _, row in rows do
		local cells = {}
		for _, c in row do
			local attrs: { [string]: string } = {}
			if c.colspan then
				attrs.colspan = c.colspan
			end
			if c.rowspan then
				attrs.rowspan = c.rowspan
			end
			local class = if c.align then "mdp-al-" .. c.align else nil
			table.insert(cells, tern.ui.el(if c.head then "th" else "td", { class = class, attrs = attrs }, { tern.ui.md(c.md) }))
		end
		table.insert(trs, tern.ui.el("tr", {}, cells))
	end
	return tern.ui.el("table", { class = "mdp-table" }, trs)
end

local function view(path: string, text: string): any
	local parts = {}
	local bytes, nodes = MAX_BYTES, MAX_NODES
	for _, seg in R.render(text, R.dirname(path)) do
		local node
		if seg.table then
			local size, count = 0, 1
			for _, row in seg.table do
				count += 1 + 2 * #row
				for _, c in row do
					size += #c.md
				end
			end
			if size > bytes or count > nodes - 2 then
				node = tern.ui.md("_This HTML table is too large to show here._")
				size, count = 0, 1
			else
				node = table_node(seg.table)
			end
			bytes -= size
			nodes -= count
			node = tern.ui.el("div", { class = if seg.center then "mdp-tbl mdp-center" else "mdp-tbl" }, { node })
		else
			local md = seg.md
			if #md > bytes then
				md = string.sub(md, 1, bytes) .. "\n\n---\n\n_Preview cut at " .. MAX_BYTES // 1024 .. " KiB._"
			end
			bytes -= #md
			node = if seg.center then tern.ui.el("div", { class = "mdp-center" }, { tern.ui.md(md) }) else tern.ui.md(md)
		end
		nodes -= 2
		table.insert(parts, node)
		if bytes <= 0 or nodes <= 2 then
			break
		end
	end
	return tern.ui.el("div", { class = "mdp-doc" }, parts)
end

-- The text each canvas last drew, so the poll only redraws what changed.
local drawn: { [number]: string } = {}
-- The file block a toggled canvas covers.
local covers: { [number]: number } = {}
local watching = false

local function draw(cx: any, pane: number, path: string, text: string, retitle: boolean)
	drawn[pane] = text
	local change: any = { view = view(path, text) }
	if retitle then
		change.title = basename(path)
		change.about = about(path)
	end
	pcall(cx.canvas.set, cx.canvas, pane, change)
end

local function poll(cx: any?)
	if not cx then
		watching = false
		return
	end
	local live = {}
	for _, c in cx.canvas:list() do
		local path = file_of(c)
		if path then
			live[c.pane] = true
			cx.docs:read(path):next(function(text, _err, cx2)
				if text and cx2 and drawn[c.pane] ~= text and canvas_file(cx2, c.pane) == path then
					draw(cx2, c.pane, path, text, false)
				end
			end)
		end
	end
	for pane in drawn do
		if not live[pane] then
			drawn[pane] = nil
			covers[pane] = nil
		end
	end
	if next(live) then
		tern.timer(POLL_MS, poll)
	else
		watching = false
	end
end

local function watch()
	if not watching then
		watching = true
		tern.timer(POLL_MS, poll)
	end
end

-- Opens `path` rendered in a new canvas placed by `spec` (CanvasSpec placement fields); `placed` gets its pane.
local function open_rendered(cx: any, path: string, spec: any, placed: ((pane: number, cx: any) -> ())?)
	cx.docs:read(path):next(function(text, err, cx2)
		if not cx2 then
			return
		end
		if not text then
			cx2:toast("error", "Couldn't read " .. path, tostring(err))
			return
		end
		spec.title = basename(path)
		spec.about = about(path)
		spec.view = view(path, text)
		local pane, failure = cx2.canvas:open(spec)
		if not pane then
			cx2:toast("error", "Couldn't render " .. path, tostring(failure))
			return
		end
		drawn[pane] = text
		watch()
		if placed then
			placed(pane, cx2)
		end
	end)
end

-- The focused pane, with the Markdown file it shows as source (`file`) or rendered (`canvas`).
local function focused_md(cx: any): (any, string?, ("file" | "canvas")?)
	local pane = cx.session:focused()
	local info = pane and cx.session:pane(pane)
	if not info then
		return nil, nil, nil
	end
	if info.kind == "file" and type(info.path) == "string" and is_md(info.path) then
		return info, info.path, "file"
	end
	local path = canvas_file(cx, info.pane)
	return info, path, if path then "canvas" else nil
end

local function rendered_beside(cx: any, path: string): number?
	for _, c in cx.canvas:list() do
		if not covers[c.pane] and file_of(c) == path then
			return c.pane
		end
	end
	return nil
end

tern.command({
	id = "toggle",
	title = "Markdown: Toggle source / rendered",
	icon = "eye",
	keys = { "cmd+alt+v" },
	available = function(cx)
		local _, path = focused_md(cx)
		return path ~= nil
	end,
	run = function(cx)
		local info, path, shown = focused_md(cx)
		if not path then
			return
		end
		if shown == "file" then
			open_rendered(cx, path, { how = "over", target = info.pane }, function(pane)
				covers[pane] = info.pane
			end)
			return
		end
		-- Back to source. A toggled canvas closes, bringing back the file block it covers; when the view has since
		-- followed a link, that block then switches to the file now shown. Any other canvas gives way to the
		-- source in its slot.
		local covered = covers[info.pane]
		if covered and cx.session:pane(covered) then
			cx.layout:close(info.pane)
			cx.layout:focus(covered)
			if (cx.session:pane(covered) :: any).path ~= path then
				cx.docs:open(path, { how = "replace" })
			end
			return
		end
		local file = cx.docs:open(path, { how = "beside" })
		if file ~= info.pane then
			cx.layout:close(info.pane)
		end
		cx.layout:focus(file)
	end,
})

tern.command({
	id = "beside",
	title = "Markdown: Preview beside",
	keys = { "cmd+alt+shift+v" },
	available = function(cx)
		local _, _, shown = focused_md(cx)
		return shown == "file"
	end,
	run = function(cx)
		local info, path, shown = focused_md(cx)
		if shown ~= "file" or not path then
			return
		end
		local open = rendered_beside(cx, path)
		if open then
			cx.layout:close(open)
			return
		end
		open_rendered(cx, path, { how = "beside", target = info.pane, dir = "right", ratio = 0.5, focus = false })
	end,
})

tern.files.button({
	id = "preview",
	title = "Preview Markdown",
	icon = "eye",
	run = function(files, cx)
		for _, path in files.selection do
			if is_md(path) then
				open_rendered(cx, path, { how = "beside" })
				return
			end
		end
		cx:toast("info", "Select a Markdown file to preview")
	end,
})

-- Links inside a rendered view: Markdown files open in the same view (⌘-click: their source), #fragments stay
-- put, other local files open as usual. Links in an agent chat: a Markdown file floats rendered over the top right
-- of the chat (⌘-click: Tern's default, the source).
tern.route.link(function(link, cx)
	local shown = canvas_file(cx, link.pane)
	if shown then
		if string.sub(link.url, 1, 1) == "#" then
			return { handled = true }
		end
		local path = md_target(link.url, R.dirname(shown))
		if not path then
			return nil
		end
		if link.mods.cmd then
			return { path = path }
		end
		cx.docs:read(path):next(function(text, err, cx2)
			if not cx2 then
				return
			end
			if not text then
				cx2:toast("error", "Couldn't read " .. path, tostring(err))
				return
			end
			draw(cx2, link.pane, path, text, true)
		end)
		return { handled = true }
	end

	if link.mods.cmd then
		return nil
	end
	local chat = cx.session:pane(link.pane)
	if not chat or chat.kind ~= "agent" then
		return nil
	end
	local path = md_target(link.url, chat.cwd)
	if not path then
		return nil
	end
	for _, p in cx.session:panes() do
		if p.floating and canvas_file(cx, p.pane) == path then
			cx.layout:focus(p.pane)
			return { handled = true }
		end
	end
	open_rendered(cx, path, { how = "beside" }, function(pane, cx2)
		cx2.layout:float(pane, chat.pane, "tr", { size = { 0.6, 0.85 } })
		cx2.layout:focus(pane)
	end)
	return { handled = true }
end)

-- Previews left open across a reload or restart keep following their files: one poll at load picks them up (and
-- stops when there are none).
watch()
