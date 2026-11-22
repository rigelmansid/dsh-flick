import AppKit
import Foundation

// MARK: - CLI modes
//
// The same binary powers the menu bar app and the diagnostics used by the
// build/verification scripts:
//   DSHFlick --discover        print one discovery result as JSON, then exit
//   DSHFlick --probe [out.png] load the web UI offscreen, dump the DOM and write
//                            a snapshot, then exit
//   DSHFlick --bridge-check    discover DSH and report whether the plugin bridge
//                            is reachable (prints JSON), then exit
//   DSHFlick --bridge-recent   print recent sessions from the plugin bridge (JSON)
//   DSHFlick --bridge-approvals
//                            print pending approvals from the bridge (JSON)
//   DSHFlick --bridge-answer <key> <allowed-once|rejected> [clientId]
//                            queue one approval decision (QA), then exit
//   DSHFlick --open-desktop    focus or launch DeepSeek Harness, then exit
//   DSHFlick --bridge-action <new-session|open-session> [sessionId]
//                            send one bridge command (QA), then exit
//   DSHFlick --show-panel      developer aid: open the full panel shortly after launch
//   DSHFlick --show-native-panel
//                            developer aid: open the native panel shortly after launch
//   DSHFlick --native-menu     run the lightweight native menu (plugin mode)
//   DSHFlick --managed         exit when the parent/stdin goes away (plugin mode)
//   DSHFlick                   run the full menu bar app (default)

private func printJSON(_ object: [String: Any]) {
    guard
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8)
    else {
        print("{\"ok\":false,\"error\":\"json-encoding-failed\"}")
        return
    }
    print(text)
}

private func runBlocking(_ operation: @escaping () async -> Void) {
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        await operation()
        semaphore.signal()
    }
    semaphore.wait()
}

let arguments = CommandLine.arguments

if arguments.contains("--discover") {
    var exitCode: Int32 = 1
    runBlocking {
        let result = await DSHDiscovery.shared.discover()
        switch result {
        case .success(let connection):
            exitCode = 0
            printJSON([
                "ok": true,
                "port": connection.port,
                "cookieName": connection.cookieName,
                "cookieExpiresAt": ISO8601DateFormatter().string(from: connection.cookieExpiresAt),
                "discoveredAt": ISO8601DateFormatter().string(from: connection.discoveredAt),
            ])
        case .failure(let error):
            exitCode = 1
            printJSON([
                "ok": false,
                "code": error.diagnostic,
                "message": error.errorDescription ?? "unknown error",
            ])
        }
    }
    exit(exitCode)
}

if let probeIndex = arguments.firstIndex(of: "--probe") {
    let snapshotPath: String
    if probeIndex + 1 < arguments.count, !arguments[probeIndex + 1].hasPrefix("--") {
        snapshotPath = arguments[probeIndex + 1]
    } else {
        snapshotPath = "probe.png"
    }
    exit(Probe.run(snapshotPath: snapshotPath))
}

if arguments.contains("--open-desktop") {
    let ok = DSHDesktop.activateOrLaunch()
    printJSON(["ok": ok])
    exit(ok ? 0 : 1)
}

if arguments.contains("--bridge-check") {
    var exitCode: Int32 = 1
    runBlocking {
        let discovery = await DSHDiscovery.shared.discover()
        switch discovery {
        case .success(let connection):
            let api = BridgeAPI(connection: connection)
            do {
                let ping = try await api.ping()
                let recent = (try? await api.recent(limit: 5)) ?? []
                exitCode = ping.ok ? 0 : 1
                printJSON([
                    "ok": ping.ok,
                    "port": connection.port,
                    "bridgeVersion": ping.version ?? "",
                    "language": ping.language ?? "",
                    "clientReady": ping.clientReady ?? false,
                    "lastAckAction": ping.lastAckAction ?? "",
                    "recentCount": recent.count,
                ])
            } catch {
                printJSON([
                    "ok": false,
                    "port": connection.port,
                    "code": "bridge-unavailable",
                    "message": error.localizedDescription,
                ])
            }
        case .failure(let error):
            printJSON([
                "ok": false,
                "code": error.diagnostic,
                "message": error.errorDescription ?? "discovery failed",
            ])
        }
    }
    exit(exitCode)
}

if arguments.contains("--bridge-recent") {
    var exitCode: Int32 = 1
    runBlocking {
        let discovery = await DSHDiscovery.shared.discover()
        switch discovery {
        case .success(let connection):
            do {
                let items = try await BridgeAPI(connection: connection).recent(limit: 10)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(items)
                let json = String(data: data, encoding: .utf8) ?? "[]"
                print("{\"ok\":true,\"items\":\(json)}")
                exitCode = 0
            } catch {
                printJSON([
                    "ok": false,
                    "code": "bridge-unavailable",
                    "message": error.localizedDescription,
                ])
            }
        case .failure(let error):
            printJSON([
                "ok": false,
                "code": error.diagnostic,
                "message": error.errorDescription ?? "discovery failed",
            ])
        }
    }
    exit(exitCode)
}

if arguments.contains("--bridge-approvals") {
    var exitCode: Int32 = 1
    runBlocking {
        let discovery = await DSHDiscovery.shared.discover()
        switch discovery {
        case .success(let connection):
            do {
                let result = try await BridgeAPI(connection: connection).approvals()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(result.items)
                let json = String(data: data, encoding: .utf8) ?? "[]"
                print("{\"ok\":true,\"autoOpen\":\(result.autoOpen),\"items\":\(json)}")
                exitCode = 0
            } catch {
                printJSON([
                    "ok": false,
                    "code": "bridge-unavailable",
                    "message": error.localizedDescription,
                ])
            }
        case .failure(let error):
            printJSON([
                "ok": false,
                "code": error.diagnostic,
                "message": error.errorDescription ?? "discovery failed",
            ])
        }
    }
    exit(exitCode)
}

if let answerIndex = arguments.firstIndex(of: "--bridge-answer") {
    guard answerIndex + 2 < arguments.count else {
        FileHandle.standardError.write(Data("usage: DSHFlick --bridge-answer <key> <allowed-once|rejected> [clientId]\n".utf8))
        exit(2)
    }
    let key = arguments[answerIndex + 1]
    let decision = arguments[answerIndex + 2]
    let clientId = answerIndex + 3 < arguments.count ? arguments[answerIndex + 3] : nil
    var exitCode: Int32 = 1
    runBlocking {
        let discovery = await DSHDiscovery.shared.discover()
        switch discovery {
        case .success(let connection):
            do {
                try await BridgeAPI(connection: connection).answerApproval(
                    key: key,
                    decision: decision,
                    clientId: clientId
                )
                printJSON(["ok": true])
                exitCode = 0
            } catch {
                printJSON(["ok": false, "message": error.localizedDescription])
            }
        case .failure(let error):
            printJSON([
                "ok": false,
                "code": error.diagnostic,
                "message": error.errorDescription ?? "discovery failed",
            ])
        }
    }
    exit(exitCode)
}

if let actionIndex = arguments.firstIndex(of: "--bridge-action") {
    guard
        actionIndex + 1 < arguments.count,
        !arguments[actionIndex + 1].hasPrefix("--")
    else {
        FileHandle.standardError.write(Data("usage: DSHFlick --bridge-action <new-session|open-session> [sessionId]\n".utf8))
        exit(2)
    }
    let action = arguments[actionIndex + 1]
    let sessionId: String? = {
        let next = actionIndex + 2
        guard next < arguments.count, !arguments[next].hasPrefix("--") else { return nil }
        return arguments[next]
    }()
    var exitCode: Int32 = 1
    runBlocking {
        let discovery = await DSHDiscovery.shared.discover()
        switch discovery {
        case .success(let connection):
            do {
                try await BridgeAPI(connection: connection).send(action: action, sessionId: sessionId)
                exitCode = 0
                printJSON(["ok": true, "action": action, "sessionId": sessionId ?? ""])
            } catch {
                printJSON([
                    "ok": false,
                    "code": "bridge-unavailable",
                    "message": error.localizedDescription,
                ])
            }
        case .failure(let error):
            printJSON([
                "ok": false,
                "code": error.diagnostic,
                "message": error.errorDescription ?? "discovery failed",
            ])
        }
    }
    exit(exitCode)
}

// MARK: - Menu bar app

/// The AppKit surface is main-actor isolated; the process starts on the main
/// thread, so this entry point can assert that isolation synchronously.
@MainActor
private func runMenuBarApp() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    guard InstanceLock.acquire() else {
        let line = "[DSHFlick] another instance is already running; exiting (exit 0)\n"
        FileHandle.standardError.write(Data(line.utf8))
        exit(0)
    }

    ManagedLifecycle.startIfNeeded()

    if arguments.contains("--native-menu") {
        let ui = NativeMenuController(managed: ManagedLifecycle.isManaged)
        let controller = AppController(ui: ui)
        controller.start()
        application.run()
        return
    }

    let ui = DSHFlickController()
    let controller = AppController(ui: ui)
    controller.start()

    // Developer aid: open the panel shortly after launch so the popover can be
    // inspected/screenshotted without clicking the status item.
    if arguments.contains("--show-panel") {
        let ui = ui
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            MainActor.assumeIsolated {
                ui.togglePanel()
            }
        }
    }

    application.run()
}

MainActor.assumeIsolated {
    runMenuBarApp()
}
