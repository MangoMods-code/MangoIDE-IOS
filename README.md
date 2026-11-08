# MangoIDE

A code editor for iPhone and iPad.

- Syntax highlighting for 30+ languages, line numbers, auto-indent, bracket/quote closing, find & replace
- VS Code-style tabs and a side-by-side split editor
- Built-in folders (Projects, Scratchpad, Snippets, Imported, Extensions), visible in the Files app
- File and folder pickers, new file / folder / project creators with templates
- Run: JavaScript on device, HTML and Markdown previews, every other language through a Piston-compatible runner server
- Extensions: themes, languages and snippets from a single `extension.json`
- Lots of settings

## Builds

Every push to `main` builds an unsigned IPA and publishes it under **Releases**.
Each build gets its own version (`0.1.<build number>`) and the workflow checks the version inside the IPA before publishing, so Mango Signer always sees a new build as an update.
