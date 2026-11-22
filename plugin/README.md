# DSH Flick

**Approve DeepSeek Harness permissions from any window.**

A small macOS menu bar companion for DeepSeek Harness. When DSH asks for a
permission while its window is out of sight, the request shows up in the menu
bar, and one click answers it. The plugin starts the menu bar app with DSH and
stops it when DSH quits.

Full documentation, screenshots and the standalone app:
<https://github.com/rigelmansid/dsh-flick>

> Unofficial personal project, not affiliated with DeepSeek. The icons are
> original and contain no DeepSeek artwork.

## Why DSH Flick

- **Approve from wherever you are.** DSH window minimized, on another Space, or
  behind a full-screen app? A new permission request appears in the menu bar
  panel with the session it came from and what it wants. **Reject** or **Allow
  once** right there, or **View details** to jump to that session.
- **Light on purpose.** One small native panel: open DSH, start a session, the
  five latest sessions, pending approvals. No Dock icon, no Accessibility
  permission.
- **Comes and goes with DSH.** No login item, no leftover background process.
- **Stays on this Mac.** The bridge listens on loopback only.

## Features

**Approvals**
- Each card shows the session title, the requested permission, and
  **Reject / Allow once / View details**
- Answers go through the same `PendingApproval.answer()` the DSH composer uses,
  so the menu bar and the main window always agree on what's pending
- Several sessions waiting at once stack vertically; the panel grows to a cap,
  then scrolls
- A red count badge stays on the icon while anything is pending

**Sessions**
- **Open DeepSeek Harness**: bring the main window forward
- **New session**: start one in the current or most recent workspace and open it
- **Recent sessions**: the five latest top-level sessions, one click to jump

**Menu bar**
- **⌥⌘D** shows or hides the panel from any app
- The header shows the connection state and the loopback port DSH is using
- **Hide icon** removes it for this DSH run; it returns next time DSH starts

## Settings

| Setting | Default | Effect |
| --- | --- | --- |
| **Auto-open approval panel** (`autoOpenApprovals`) | on | Pop the panel up for a new request while DSH isn't visible. When off, only the red badge appears |

## Enable and disable

Use the **Plugins** panel in the left sidebar of the DSH main window to enable,
disable or remove DSH Flick, then restart DSH once. **Settings → Built-in
plugins** is a read-only list: it shows `已启用 / 运行中` but has no toggle.

If the standalone `~/Applications/DSH Flick.app` is running when the plugin
starts, the plugin's copy exits at once (one instance at a time). Quit the
standalone app and restart DSH to switch to plugin mode.

## Requirements

- macOS 14 or later (universal arm64 + x86_64 build)
- DeepSeek Harness desktop, `0.2.2-rc.5` or later
- No Accessibility, Input Monitoring or Screen Recording permission

## Limitations

- **Allow once only.** The menu bar offers **Allow once** and **Reject**; use
  **View details** for anything else.
- **Mirrors DSH's own pending state.** One request per session is visible at a
  time, and approvals disappear if the DSH page is closed.
- **Recent sessions** come from `ctx.sessionQuery` and need it to be available
  in the profile.
- **Tied to DSH internals.** A DSH upgrade may change the client services or
  route forwarding; if the bridge is unavailable, the panel falls back to
  open + status.
- **A separate process.** The menu bar app runs on its own; DSH only manages its
  lifetime.

## How it works

The plugin starts `resources/DSH Flick.app --managed --native-menu` and holds a
stdin pipe open. The app exits when the pipe closes or the DSH host process
disappears, so quitting DSH, disabling the plugin or a crash removes the icon
without leaving anything behind.

The native panel talks to the plugin over a loopback-only bridge:

| Route | Purpose |
| --- | --- |
| `GET /dsh-flick/api/ping` | bridge health and page heartbeat |
| `GET /dsh-flick/api/recent?limit=5` | recent sessions from `ctx.sessionQuery` |
| `POST /dsh-flick/api/action` | queue `new-session` / `open-session` |
| `GET /dsh-flick/api/pending` | page polls queued commands |
| `POST /dsh-flick/api/ack` | page reports a command ran |
| `POST /dsh-flick/api/approvals/sync` | page mirrors its pending approvals |
| `GET /dsh-flick/api/approvals` | pending approvals and the auto-open setting |
| `POST /dsh-flick/api/approval-answer` | queue an allow / reject decision for the page |

The page half polls `/pending` and calls `ctx.uiWorkspace.startSession()` or
`ctx.uiWorkspace.openSession(id)`. It mirrors
`ctx.uiSession.sessionStatus.pendingInteraction` to the host and submits menu
bar decisions through `PendingApproval.answer()`. Requests are checked against
the DSH browser credential when the connection service is available.

## Build the bundled app

From the repository root:

```sh
./scripts/build-plugin.sh              # native build
./scripts/build-plugin.sh --universal  # arm64 + x86_64 for release
```

This builds the app and copies `dist/DSH Flick.app` into `plugin/resources/`.
A plugin installed from a local folder is linked to it, so don't move or delete
the checkout.

## License

MIT
