# Note for Tern: `#heading` links in plugin views

## Context

I wanted to read Markdown in Tern at the quality GitHub shows it. I mostly open READMEs, and they rely on the HTML
GitHub accepts: centered logos, badge rows, sized images, tables and collapsible sections. Tern's own rendered view
of a file prints that HTML as raw text, so a README looks broken compared with its GitHub page. I also wanted the result
to look like part of Tern, the way T3 Code renders Markdown in its own style, rather than an embedded web page.

So this plugin opens a read-only view of a Markdown file. It draws with Tern's own Markdown renderer, the one the agent
chat uses, styled like the chat and laid out like a GitHub README. Before drawing, it rewrites what the renderer can't
show: README HTML, relative paths, sized images, HTML tables, emoji shortcodes and footnotes. The view follows the
file as you edit it.

Nearly all of that works from inside a plugin. Links to headings are the gap, and closing it needs a change in Tern.

## The gap

In this plugin's rendered views, a link like `[Setup](#setup-guide)` does nothing. Tern's plugin API gives a plugin no
way to scroll a view to a heading, and if a plugin doesn't handle the click itself, Tern passes `#setup-guide` to
macOS to open. That fails with *"Could not open the link: no application could open #setup-guide"*. The plugin
swallows these clicks to avoid that error. Real fragment navigation has to come from Tern.

Observed on Tern 0.9.28 (3e7c863). Statements marked *(inference)* are reasoning without Tern's source.

## Case study: why `#heading` links stop at plugin views

**What Tern already does.** Tern's own Markdown file view follows fragment links on ⌘-click, so Tern already has the
pieces: it parses headings, derives slugs and scrolls to them. Testing that matcher against GitHub's slugs gives:

| Heading | Link | GitHub | Tern file view (⌘-click) | Id in a plugin view |
|---|---|---|---|---|
| `Setup guide` | `#setup-guide` | ✓ | ✓ | `h-setup-guide` |
| `Hello, World! (v2)` | `#hello-world-v2` | ✓ | ✓ | `h-hello-world-v2` |
| second `Notes` | `#notes-1` | ✓ | ✗ | `h-notes` (same id as the first) |
| `🚀 Rocket launch` | `#-rocket-launch` | ✓ | ✗ (`#rocket-launch` works) | `h-rocket-launch` |

**Underlying cause *(inference)*.** Fragment handling seems to belong to the file editor, not to the shared Markdown
renderer or the window's link router:

- The editor owns its scroll position and its parsed outline (the parser `cx.docs:outline` exposes), so it can
  resolve `#slug` itself.
- Plugin views (canvases) and agent chats are node trees pushed into the window. The window lays them out and owns
  their scroll, and nothing in the protocol says "reveal this node". `CanvasCx` has only `open`, `set`, `get` and
  `list`.
- The router seems to sort a link's target into two kinds only: a path (relative paths resolve against the focused
  pane's directory; `./other.md` from a canvas became `/tmp/other.md`) or a URL for the system opener. A bare `#…`
  matches neither, so it falls through to macOS.
- The slugger behind both the editor and the renderer trims the hyphen GitHub keeps after a leading emoji and doesn't
  add `-1` to repeated headings. The renderer also prefixes ids with `h-` and repeats them for repeated headings. So
  sending fragments to the renderer's ids alone would still miss links written for GitHub.

**Improvement.** Three changes, smallest first:

1. **In the link router:** when a target starts with `#`, resolve it inside the pane that was clicked. Match the
   fragment against that pane's headings and scroll the match into view, reusing the editor's code. This fixes
   canvases and agent chats at once, with no plugin changes.
2. **In the slugger:** use GitHub's rules (lowercase; drop characters other than letters, numbers, spaces, `-` and `_`;
   spaces become `-`; no trimming; `-1`, `-2`… for repeats), and accept the `user-content-` prefix GitHub uses on ids.
   Make ids unique per pane, so two headings never share an `h-…` id.
3. **For plugins:** add an explicit hook, e.g. `cx.canvas:reveal(pane, { heading = "Setup guide" })` or a `scroll_to`
   field on `CanvasChange`. Plugins could then handle fragments their own way, and keep a view's scroll position when
   they redraw it or reload.

Once (1) and (2) are in Tern, this plugin can drop its `#` swallow in `window.luau` and let the built-in handle it.
