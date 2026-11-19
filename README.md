# Markdown Preview

A Tern plugin that renders Markdown files the way GitHub shows a README. It uses Tern's own Markdown renderer, so
you get syntax-highlighted code cards, Mermaid diagrams, GitHub alerts, task lists and tables, styled like the agent
chat: sans body text, mono code and the theme's heading color.

| Do this | What happens |
|---|---|
| ⌥⌘V in a Markdown file block | Swaps the file for its rendered view in the same slot. Press ⌥⌘V again to get the source back. |
| ⌥⇧⌘V in a Markdown file block | Opens the rendered view beside the file and keeps focus on the file, so you can watch it while you edit. Press again to close it. |
| Click a `.md` path in an agent chat | Floats the rendered view over the top right of the chat. ⌘-click opens the source, as before. |
| Eye button in the Files pane header | Renders the selected Markdown file. |
| Click a link inside a rendered view | Another Markdown file opens in the same view, ⌘-click opens its source, other local files open as usual and web links go to the browser. |

All of these are also in the palette under "Markdown:".

Previews follow the file as it changes, unsaved edits included, about every 0.4 s. A preview keeps following its
file after a plugin reload or a restart.

Tern's own ⇧⌘V (the eye and `<>` in a file block's header) still switches between the source and Tern's editable
rendering. This plugin adds a read-only view that looks like GitHub.

## GitHub fidelity

Tern's renderer prints raw HTML as text, so `render.luau` rewrites a file before drawing it:

- Relative link and image paths become absolute, so images load and links resolve against the file's own folder.
- The HTML that READMEs use becomes Markdown: `<img>`, `<a>`, `<picture>`, `<h1>`–`<h6>`, `<br>`, `<hr>`, `<b>`,
  `<em>`, `<code>` and `<kbd>`. `<details>` shows expanded with its `<summary>` in bold, and comments are hidden.
  An HTML block reads as one paragraph, so badge rows stay on one line. `align="center"` blocks, and the Markdown
  inside a centered `<div>`, are centered.
- Images keep the `width` and `height` from their attributes or inline style.
- HTML tables become real tables with `colspan`, `rowspan` and cell alignment. Markdown written inside a cell
  (after a blank line, the way GitHub reads it) is rendered too.
- Emoji shortcodes like `:rocket:` become emoji, using GitHub's own list (`emoji.luau`, generated from
  [github/gemoji](https://github.com/github/gemoji)).
- Footnotes become superscript numbers, with their notes listed at the end.
- Code fences and inline code pass through untouched.

Not supported: `#fragment` links. Tern gives plugins no way to scroll a view to a heading; see
[docs/tern-heading-links.md](docs/tern-heading-links.md) for the evidence and what Tern could change.

## Install

```sh
tern plugin install github.com/bubb4rd/tern-md-preview
```

Tested on Tern 0.9.28. The plugin uses Tern's plugin API and some of its CSS class names, which can change between
releases.

To develop it in place instead, clone it and run `tern plugin link <clone>`. `tern plugin types .` writes
`tern.d.luau` for luau-lsp; it's ignored by git because it depends on the installed Tern version.

## License

[MIT](LICENSE). `emoji.luau` is generated from [gemoji](https://github.com/github/gemoji), © GitHub, Inc., under the
MIT License in [LICENSES/gemoji.txt](LICENSES/gemoji.txt).
