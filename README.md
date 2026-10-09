# TrayTranslate

Menu bar translator for macOS. Select text, press ⌘C twice within 0.5 s: the text is translated
(Cyrillic-dominated text RU→EN, everything else EN→RU), shown in a floating panel near the cursor and
copied to the clipboard. Esc or a click outside closes the panel.

Claude and Codex translation runs through a local CLI agent, non-interactively and with minimal context
(no tools, MCP, plugins, hooks, skills, AGENTS.md/CLAUDE.md or session files). The text goes to the CLI
over stdin and nowhere else:

| Engine | Model | First text | Total (median of 10) |
|---|---|---|---|
| Claude (`claude -p`, default) | `claude-haiku-5-5` | ~1.5 s, streamed | ~1.7 s |
| Codex (`codex exec`) | `gpt-6-luna`, effort low | no streaming | ~3.8 s |
| OpenAI (direct API) | `gpt-4o-mini` | full response | not measured |

Select **API-ключ OpenAI…** in the menu to save your OpenAI API key in macOS Keychain.
Saving the key selects OpenAI; you can switch engines in the same menu. OpenAI sends the selected
text and translation instructions directly to `https://api.openai.com/v1/chat/completions`.
For headless runs, `--engine openai` also accepts `OPENAI_API_KEY` when no key is stored in Keychain.

CLI timings measured with `echo "…" | TrayTranslate --translate --runs 5` before OpenAI was added.

## Permission

The double ⌘C is read with a listen-only keyboard event tap, which needs
**System Settings → Privacy & Security → Input Monitoring → TrayTranslate**. The app is ad-hoc signed,
so a rebuild may require toggling the permission off and on again.

## Build

`./scripts/build-app.sh --install` builds and copies the app to `/Applications`.
Tests: `swift run SelfTest`.
Hotkey permission check: `TrayTranslate --check-hotkey`.

Commits follow the Commit Attribution rule (Contribution — Zhdan Parfenov block) from `~/.claude/CLAUDE.md`.
