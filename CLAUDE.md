# Jarvis Orb

A glowing, cursor-reactive orb on the macOS desktop that fronts a Claude agent. Native Swift/AppKit shell, WebGL orb in a `WKWebView`, Node helper that runs Claude Code headless.

**Start here:** `README.md` (features, setup) and `docs/ARCHITECTURE.md` (components, protocol, safety model).

## Layout

- `app/` Swift/AppKit macOS app, plus the `CalendarTool` and `MessagesTool` command-line helpers
- `orb-web/` WebGL orb and briefing card (HTML/JS), also viewable in a plain browser tab
- `agent/` Node helper that runs `claude -p`; talks to the app over stdio JSON lines
- `scripts/` build, install, signing and Kokoro setup
- `docs/` architecture and images

## Conventions

- Commit small and often.
- Verify by building, running and screenshotting. Say plainly what was not verified.
- Anything that sends, deletes, spends or posts must go through an Approve/Deny card.
- No secrets or personal data in the repo or logs. Keys go in the Keychain; per-machine values go in `local.env` (git-ignored).
- Don't modify the user's Dock, desktop, system settings or other apps.

## Commands

- Build and launch: `scripts/run.sh` (Debug; pass `Release` for a release build). Output in `build/DerivedData`.
- Install for daily use: `scripts/install.sh` (Release build → `~/Applications/JarvisOrb.app`, launched; its first launch turns on Open at Login, toggle in the orb's menu). Dev builds from `run.sh` never register at login. Both share the bundle id, settings and Keychain items, so quit one before running the other.
- Bundle id: `local.env` sets `BUNDLE_ID` (see `local.env.example`); without it the project default `com.example.JarvisOrb` is used. Keep it stable: macOS ties permissions and settings to it.
- Signing: `scripts/create-signing-cert.sh` creates a self-signed "JarvisOrb Local Signing" certificate (codesign-only access, valid 10 years). `install.sh` signs with it when present, which gives a stable designated requirement, so macOS keeps Accessibility and Full Disk Access across rebuilds; ad-hoc builds lose them every install. Dev builds from `run.sh` stay ad-hoc.
- Kokoro (free on-device voice, fallback after ElevenLabs): `scripts/setup-kokoro.sh` installs a private Python 3.12 venv + ~340 MB model into `~/Library/Application Support/JarvisOrb/kokoro`. The app runs `agent/kokoro_server.py` there on demand. Voice chain: ElevenLabs → Kokoro → Mac voice; ElevenLabs "out of credits" pauses it for 24 h (`elevenOutOfCreditsUntil` default). Kokoro voice: `kokoroVoice` default (bm_george).
- Owner name used in prompts: `ownerName` default, else the first word of the macOS account's full name.
- Global shortcut: ⌃⌥Space opens/closes the orb's input from any app (Carbon hot key, no permissions).
- Activity log: `~/Library/Logs/JarvisOrb/activity-<date>.log` (tools used, approvals and answers; never request text or replies).
- Build only: `xcodebuild -project app/JarvisOrb.xcodeproj -scheme JarvisOrb -configuration Debug -derivedDataPath build/DerivedData build`
- Quit: right-click the orb → Quit, or `pkill -x JarvisOrb`
- Orb in browser: `python3 -m http.server 5178 --directory orb-web`, open `http://localhost:5178/?fps` (file:// also works in most browsers). Drive it from the console with `orb.setState('thinking')`. Briefing preview: `http://localhost:5178/briefing.html` (sample data).
- Orb logs (page console is forwarded): `/usr/bin/log stream --predicate 'subsystem == "<your bundle id>"'`
- Debug launch args: `open build/DerivedData/Build/Products/Debug/JarvisOrb.app --args -RegularPolicy YES` (normal app identity, so screenshot tools can see it), `-ShowFPS YES` (fps/state overlay), `-OcclusionTest YES|full` (normal window half/fully over the orb; full should pause rendering), `-IdleFPS 24` (idle frame rate, any build). `-TestPrompt "..."` sends a request at launch and `-TestStopAfter 3` presses Stop after 3 s. `-model claude-opus-5-5` overrides the model. Debug builds also have a Preview State submenu.
- Browser preview keys: mouse = cursor feed, 1–7 = states (idle, hover, listening, thinking, awaitingApproval, speaking, error).
- `app/JarvisOrb/` is a synchronized folder: new Swift files there are picked up without editing the project. `orb-web/` and `agent/` are bundled as folder references.
- Agent helper (no npm dependencies; the app runs its bundled copy with /opt/homebrew/bin/node): try it by hand with
  `echo '{"type":"task","id":"t1","text":"hi","model":"claude-sonnet-5-5"}' | node agent/index.js`
- Claude Code path: `~/.local/bin/claude`, or set `JARVIS_CLAUDE_PATH`.

## Verified facts

- Wispr Flow: hold **fn** to dictate (push-to-talk); fn+Space is hands-free mode; Esc cancels. It inserts text by simulating **⌘V** into the focused field and does not press Return. So the app keeps an invisible main menu with an Edit menu (paste needs it in an accessory app), and a single change of 3+ characters counts as a dictation and auto-sends after 1.5 s; typing waits for Return.
- The desktop-level window becomes key and takes typing fine.
- The window only takes the mouse inside the orb circle (and the transcript bar while it shows); elsewhere `ignoresMouseEvents` is on so clicks reach the desktop.
- Screenshot tooling hides windows of apps not granted to it, so a spot that looks like bare desktop may have a window on it. Check `CGWindowListCopyWindowInfo` before clicking "empty" space.
- The agent is the user's installed Claude Code run headless (`claude -p`, stream-json) on their own claude.ai login; the helper strips `ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN` from its environment. Working dir: `~/Library/Application Support/JarvisOrb/workspace`.
- If a shell exports `ANTHROPIC_API_KEY`, `claude auth status` looks signed in while no claude.ai login is stored. Sign in with `env -u ANTHROPIC_API_KEY claude auth login` and check with `env -u ANTHROPIC_API_KEY claude auth status` (expect `authMethod: claude.ai`).
- Agent tools: Calendar and Reminders through the bundled `jarvis-calendar`, Gmail and web through Claude in Chrome (`--chrome`, only for browser-sounding requests). Built-in computer use is not available in `claude -p`. `--chrome --strict-mcp-config` keeps startup ~0.6 s (all connectors: ~2.7 s).
- Approvals: `agent/approval-hook.js` is registered via `--settings` for PermissionRequest (fires in `-p` only for actions Claude Code wants permission for; unanswered = denied) and PreToolUse (browser actions that can change a page). It asks the helper over `~/Library/Application Support/JarvisOrb/approve-<pid>.sock`.
- When more than one Claude in Chrome browser is connected, Jarvis asks which to use.
- Wispr auto-start (off by default; orb menu › Voice Input): the orb posts Wispr's hands-free shortcut fn+Space on click and again on the second click; Esc or leaving dismisses Wispr. Needs Accessibility permission for the orb.
- Claude Cowork has no supported external API; the orb runs the agent directly instead of driving Cowork's UI.
- Measured CPU (one core, app + WebKit GPU + WebContent, Apple M3): ~23% at 60 fps (active), ~11% idle at 30 fps, ~0% when covered.
