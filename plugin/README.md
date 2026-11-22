# DSH Flick

DSH Flick adds a native macOS menu bar entry to DeepSeek Harness. The icon is
started and stopped by a DSH plugin, so it exists exactly while the DSH desktop
app is running.

## What it does

- **Open DeepSeek Harness** — bring the main window to the front.
- **New session** — start a session in the current or most recent workspace and
  open it in the main window.
- **Recent sessions** — list the five latest top-level sessions and jump to one.
- **Pending approvals** — when the DSH window is minimized, on another Space, or
  otherwise not visible, new permission requests appear above the recent-session
  list with the session title, the requested permission, and **Reject / Allow
  once** actions. Opening the details jumps straight to that session in DSH.
  Multiple sessions stack vertically; the panel grows up to a capped height and
  scrolls. A red count badge is always shown while requests are pending.
- **Connection state** — shows the loopback port DSH is listening on.
- **Auto pop-up setting** — the plugin setting **Auto-open approval panel**
  (`autoOpenApprovals`, on by default) controls whether a new approval
  automatically opens the panel when DSH is not visible. When off, only the red
  badge appears.
- **⌥⌘D** — show or hide the panel from anywhere.
- **Hide icon** — remove the icon for this DSH run; it returns next time DSH
  starts.

## Lifecycle

If the standalone `~/Applications/DSH Flick.app` is already running when the
plugin starts, the managed instance exits immediately (single-instance lock).
Quit the standalone app once after installing the plugin; otherwise the native
icon appears only on the next DSH launch.

The plugin spawns `resources/DSH Flick.app` with `--managed --native-menu` and
keeps a stdin pipe open. The app exits when the pipe closes or when the DSH Host
process disappears, so quitting DSH, disabling the plugin, or a crash removes
the icon without leaving a launch agent or a background process behind.

## Bridge

The native panel talks to the plugin over a loopback-only bridge:

| Route | Purpose |
| --- | --- |
| `GET /dsh-flick/api/ping` | bridge health and page heartbeat |
| `GET /dsh-flick/api/recent?limit=5` | recent sessions from `ctx.sessionQuery` |
| `POST /dsh-flick/api/action` | queue `new-session` / `open-session` |
| `GET /dsh-flick/api/pending` | poll queued commands from the DSH page |
| `POST /dsh-flick/api/ack` | page reports a command was executed |
| `POST /dsh-flick/api/approvals/sync` | page mirrors its pending approval interactions |
| `GET /dsh-flick/api/approvals` | pending approvals and the auto-pop-up setting |
| `POST /dsh-flick/api/approval-answer` | queue an allow/reject decision for the page |

The DSH client half polls `/pending` and calls `ctx.uiWorkspace.startSession()`
or `ctx.uiWorkspace.openSession(id)`. It also mirrors
`ctx.uiSession.sessionStatus.pendingInteraction` to the Host bridge and submits a
menu bar decision through the same `PendingApproval.answer()` object the DSH
composer uses, so both surfaces always agree on whether a request is pending. Requests are checked against the DSH
browser credential when the connection service is available; the listener is
loopback-only.

## Build the bundled app

From the repository root (`dsh-flick/`):

```sh
./scripts/build-plugin.sh              # native build
./scripts/build-plugin.sh --universal  # arm64 + x86_64 distribution build
```

This runs the normal app build and copies `dist/DSH Flick.app` into
`plugin/resources/`. The plugin package links to this checkout when installed
from a local directory, so keep `dsh-flick/` in place.

## Enable and disable

Use the **Plugins** panel in the DSH main window's left sidebar to enable,
disable, or remove this bundle. The **Settings → Built-in plugins** page is a
read-only inventory: it shows `已启用 / 运行中` but has no toggle.

## Requirements

- macOS 14 or newer (universal arm64 + x86_64 build)
- DeepSeek Harness 0.2.2-rc.5 or newer, desktop profile
- No Accessibility or Screen Recording permission is required

## Limitations

- The menu bar app is still a separate process; DSH only manages its lifetime.
- The recent-session list comes from the DSH Host and depends on
  `ctx.sessionQuery` being available in the profile.
- Approval cards mirror DSH's own pending interaction: one request per session is
  visible at a time, a grant is always one-shot, and approvals disappear if the
  DSH page is closed. DSH must be running; the icon itself still exits with DSH.
- DSH upgrades may change the Client service or route-forwarding behavior; the
  panel degrades to “open + status” when the bridge is unavailable.
- The bundled app and plugin icon use original artwork generated for this
  project; the menu bar icon is a template image that follows the system
  appearance.
