# QWhaleMaiden engineering handoff

Version 0.1.2-beta, macOS arm64, minimum deployment target 13.0. This public handoff intentionally excludes machine-specific history and user state.

## Architecture

Swift/AppKit windows with local WKWebView resources; SQLite snapshot and bounded event deduplication; same-user Unix socket and embedded helper. Core.swift owns state/reminders, Agents.swift maps events, Motion.swift handles physics, App.swift owns native windows, BridgeSetup.swift installs optional host integrations. RuntimeLog.swift writes bounded technical logs.

## Current behavior

106 built-in DSH-pet animations; body reference height 132 points. Toolbar 132×28, More panel 244×248. Agent background opacity 85%, local/wellness bubble 75%. Default focus 45 minutes. Motion menu suppression uses native and web guards plus 700ms post-motion cooldown. Bounds derive from current NSScreen visibleFrame and body geometry.

Source IDs: codex, workbuddy, trae, lingxi, dsh, qwenwork. QwenWorkCN is distinct from Qianwen chat. Notifications open the app by Bundle ID; deep links are not enabled. DSH and QwenWork integration has isolated-chain coverage, not complete real-host acceptance.

## Known limits

Codex oversized newline-free records may pause that file. WorkBuddy/Trae real mode coverage, DSH/QwenWork dispatch, permission recovery, physical multi-display/trackpad behavior, older macOS, login items, Developer ID signing and notarization need explicit device validation. Do not infer task completion from silence or tool failure.

## Rename compatibility

The displayed product/App is QWhaleMaiden. Internal helper/environment/Bundle identifiers retain compatibility names. Default runtime data is under the user Application Support/QWhaleMaiden/v1 directory; first launch can back up legacy SQLite state using the SQLite backup API and copy user packs without deleting the old data or importing logs. Custom test data roots skip migration.

Build and test commands are in README.md. Packaging is allowlist-based and excludes existing logs, user state, tests and examples. Installations at a new path require refreshing optional Agent hooks/plugins. Private machine handoff and release verification outputs remain local and are never publication inputs.
