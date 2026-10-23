# QWhaleMaiden engineering handoff

Version 0.1.2-beta, macOS arm64, minimum deployment target 13.0. This public handoff intentionally excludes machine-specific history and user state.

## Architecture

Swift/AppKit windows with local WKWebView resources; SQLite snapshot and bounded event deduplication; same-user Unix socket and embedded helper. Core.swift owns state/reminders, Agents.swift maps events, Motion.swift handles physics, App.swift owns native windows, BridgeSetup.swift installs optional host integrations. RuntimeLog.swift writes bounded technical logs.

## Current behavior

Settings sidebar uses a transparent generated head portrait (`Resources/settings-avatar.png`), with Q鲸娘 above Q-WhaleMaiden. Fixed avatar columns and responsive type keep both labels inside the sidebar. Application/bundle name stays QWhaleMaiden.

The six Interact buttons share a fixed 46-point height. More → Interact includes 贴边勿扰: loops only the crouching interval (2.8–7.6 seconds of 原地重力下蹲压缩), excluding the standing transition. Entry keeps the body horizontal center fixed and descends vertically without bouncing to the physical screen bottom, after the crouching video is ready; the full body hit target remains available. Dragging it out or three taps restores normal mode. While docked, notifications/sounds/whispers/wandering and focus/rest/water timers pause; controls temporarily show off/paused without rewriting saved preferences; task collection continues. The prior hide/recall/timed-quiet controls and quietUntil setting were removed. Normal position is retained on disk while docked. Manage is a symmetric 2×2 grid: 换个形象, 鼠标穿透, 全部设置, 退出桌宠. All Settings uses the same names, with five scoped pages and progressive integration/material details. The App icon now uses the transparent head portrait.

106 built-in DSH-pet animations; body reference height 132 points. Toolbar 132×28, More panel 244×248. Agent background opacity 85%, local/wellness bubble 75%. Default focus 45 minutes. Motion menu suppression uses native and web guards plus 700ms post-motion cooldown. Bounds derive from current NSScreen visibleFrame and body geometry.

Occasional walking now uses a 120–300 second interval, waits for the current built-in idle video (or sprite cycle) to end, then takes a two-dimensional 130–200 point route at 100 points/s. Three genuine taps within 1.5 seconds escape up to 300 points at 120 points/s (shorter on small screens). Directions fit the complete endpoint inside live screen body bounds; side-on clips mirror by horizontal velocity, and movement waits for the running video to be ready. Dragging clears the tap sequence; reduced motion disables escape. No fixed sleep destination is implemented.

Source IDs: codex, workbuddy, trae, lingxi, dsh, qwenwork. QwenWorkCN is distinct from Qianwen chat. Notifications open the app by Bundle ID; deep links are not enabled. DSH and QwenWork integration has isolated-chain coverage, not complete real-host acceptance.

## Known limits

Codex oversized newline-free records may pause that file. WorkBuddy/Trae real mode coverage, DSH/QwenWork dispatch, permission recovery, physical multi-display/trackpad behavior, older macOS, login items, Developer ID signing and notarization need explicit device validation. Do not infer task completion from silence or tool failure.

## Rename compatibility

The displayed product/App is QWhaleMaiden. Internal helper/environment/Bundle identifiers retain compatibility names. Default runtime data is under the user Application Support/QWhaleMaiden/v1 directory; first launch can back up legacy SQLite state using the SQLite backup API and copy user packs without deleting the old data or importing logs. Custom test data roots skip migration.

Build and test commands are in README.md. Packaging is allowlist-based and excludes existing logs, user state, tests and examples. Installations at a new path require refreshing optional Agent hooks/plugins. Private machine handoff and release verification outputs remain local and are never publication inputs.

Release packaging rebuilds a separate `build/release/QWhaleMaiden.app` without DEBUG. Screenshot/mock/verify IPC paths and developer web diagnostics are excluded from the shipped application; development builds retain isolated validation. The obsolete horizontal-only walk path was removed. Release resource and payload audits reject development binaries, test data and pre-existing logs. Runtime technical logging and user-facing reminder previews remain available.
