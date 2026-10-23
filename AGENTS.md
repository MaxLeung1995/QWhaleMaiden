# QWhaleMaiden contributor notes

Read README.md and docs/HANDOFF.md before changing behavior. User instructions take priority.

- Target Apple silicon macOS; do not add Intel support claims without validation.
- Preserve compact symmetric UI, rounded bubbles and separate notification opacities.
- Keep task facts separate from notification presentation; closing a bubble never approves a task.
- Do not read personal Agent conversation content or calendars for diagnostics.
- Isolate tests and stop test processes. Do not modify user production data or host configurations in tests.
- Build packages only when requested. Do not introduce XP, levels, titles or an inbox.
- Never commit build/, dist/, .local/, logs, databases, credentials or machine-specific documentation.
- Keep attribution and licenses. Update the public handoff for meaningful changes.
