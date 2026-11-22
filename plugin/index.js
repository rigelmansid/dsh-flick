/**
 * DSH Flick — Host half.
 *
 * Owns the managed native menu bar process and serves a tiny loopback bridge
 * for the menu bar app and the DSH page:
 *
 *   GET  /dsh-flick/api/ping     bridge health + client heartbeat
 *   GET  /dsh-flick/api/recent   recent top-level sessions (host sessionQuery)
 *   POST /dsh-flick/api/action   queue a UI command for the DSH page
 *   GET  /dsh-flick/api/pending  drain queued commands (called by the page)
 *   POST /dsh-flick/api/ack      page reports a command was executed
 *
 * The managed app exits when its stdin pipe closes, so quitting DeepSeek
 * Harness (or this plugin being disabled) removes the menu bar icon without
 * leaving a launch agent behind.
 */
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import z from "@deepseek-ai/schemastery";

const PACKAGE_DIR = dirname(fileURLToPath(import.meta.url));
const ROUTE_BASE = "/dsh-flick/api";
const APP_RELATIVE = ["resources", "DSH Flick.app", "Contents", "MacOS", "DSHFlick"];
const RESTART_LIMIT = 3;
const CLIENT_READY_WINDOW_MS = 5000;
const QUEUE_LIMIT = 20;
const APPROVAL_TTL_MS = 5 * 60_000;

const VERSION = (() => {
  try {
    return JSON.parse(readFileSync(join(PACKAGE_DIR, "package.json"), "utf8")).version ?? "0.1.0";
  } catch {
    return "0.1.0";
  }
})();

export const name = "dsh-flick";
export const inject = [];

export const Config = z.object({
  autoOpenApprovals: z
    .boolean()
    .default(true)
    .description(
      "当 DeepSeek Harness 主界面不可见时，收到新的权限审批请求就自动弹出菜单栏面板。关闭后只显示待审批角标，点击菜单栏图标查看。 / Automatically open the menu bar panel when a new approval arrives while DeepSeek Harness is not visible. When off, only the badge is shown."
    ),
});

export function apply(ctx, config = {}) {
  const state = {
    autoOpenApprovals: config?.autoOpenApprovals !== false,
    child: undefined,
    stopping: false,
    restartTimer: undefined,
    restarts: 0,
    lastRestartAt: 0,
    pending: [],
    approvalClients: new Map(),
    lastApprovalSyncAt: 0,
    lastClientPollAt: 0,
    lastAckAction: undefined,
    lastAckAt: 0,
    language: undefined,
  };

  const binaryPath = join(PACKAGE_DIR, ...APP_RELATIVE);

  function detectLocale() {
    try {
      const settings = ctx.get("settings");
      const descriptors = settings && typeof settings.describe === "function"
        ? settings.describe()
        : [];
      for (const descriptor of descriptors) {
        const namespace = String(descriptor?.ns ?? "");
        const preference = descriptor?.value?.preference;
        if (typeof preference === "string" && (namespace === "locale" || namespace.endsWith(":locale"))) {
          return preference;
        }
      }
    } catch {
      // Fall through to the profile file below.
    }
    try {
      const candidates = [process.env.DSH_PROFILE_DIR, process.cwd()].filter(Boolean);
      for (const profileDir of candidates) {
        const patch = readFileSync(join(profileDir, "cordis.patch.yml"), "utf8");
        const match = patch.match(/(?:^|\n)\s*preference:\s*["']?([a-zA-Z-]+)/);
        if (match) return match[1];
      }
    } catch {
      // Locale is optional; the app falls back to the system language.
    }
    return undefined;
  }

  state.language = detectLocale();

  // ─── Managed menu bar process ──────────────────────────────────────────

  function log(message) {
    console.log(`[dsh-flick] ${message}`);
  }

  function warn(message) {
    console.warn(`[dsh-flick] ${message}`);
  }

  function spawnApp() {
    if (state.stopping) return;
    if (!existsSync(binaryPath)) {
      warn(`menu bar binary is missing: ${binaryPath}`);
      return;
    }

    const language = state.language;
    const child = spawn(binaryPath, ["--managed", "--native-menu"], {
      stdio: ["pipe", "pipe", "pipe"],
      env: {
        ...process.env,
        DSH_FLICK_MANAGED: "1",
        ...(language === undefined ? {} : { DSH_FLICK_LANGUAGE: language }),
      },
    });
    state.child = child;
    log(`spawned menu bar app (pid ${child.pid ?? "?"})`);

    const pipe = (stream, label) => {
      if (!stream) return;
      stream.setEncoding("utf8");
      stream.on("data", (chunk) => {
        for (const line of String(chunk).split("\n")) {
          if (line.trim() !== "") log(`${label}: ${line}`);
        }
      });
    };
    pipe(child.stdout, "app");
    pipe(child.stderr, "app");

    child.on("error", (error) => {
      warn(`menu bar app failed: ${String(error)}`);
    });

    child.on("exit", (code, signal) => {
      state.child = undefined;
      if (state.stopping) {
        log("menu bar app exited during plugin teardown");
        return;
      }
      if (code === 0) {
        // Deliberate user action ("隐藏图标") or another instance already owns
        // the status item. Stay quiet until the next DSH launch.
        log("menu bar app exited cleanly; not restarting");
        return;
      }

      const now = Date.now();
      if (now - state.lastRestartAt > 60_000) state.restarts = 0;
      state.lastRestartAt = now;
      state.restarts += 1;
      if (state.restarts > RESTART_LIMIT) {
        warn(`menu bar app exited (code ${code ?? "?"}, signal ${signal ?? "?"}); restart limit reached`);
        return;
      }
      const delay = Math.min(750 * state.restarts, 4000);
      warn(`menu bar app exited (code ${code ?? "?"}, signal ${signal ?? "?"}); retrying in ${delay}ms`);
      state.restartTimer = setTimeout(() => {
        state.restartTimer = undefined;
        spawnApp();
      }, delay);
    });
  }

  function stopApp() {
    state.stopping = true;
    if (state.restartTimer !== undefined) {
      clearTimeout(state.restartTimer);
      state.restartTimer = undefined;
    }
    const child = state.child;
    if (!child) return;
    try {
      child.stdin?.end();
    } catch {
      // Expected when the pipe is already closed.
    }
    try {
      child.kill("SIGTERM");
    } catch {
      // Already gone.
    }
    const started = Date.now();
    const killTimer = setInterval(() => {
      if (state.child === undefined || Date.now() - started > 2000) {
        clearInterval(killTimer);
        return;
      }
      try {
        state.child.kill("SIGKILL");
      } catch {
        // Already gone.
      }
    }, 300);
  }

  if (typeof ctx.effect === "function") {
    ctx.effect(() => {
      spawnApp();
      return () => stopApp();
    }, "dsh-flick: managed native app");
  } else {
    spawnApp();
  }

  // ─── Bridge routes ─────────────────────────────────────────────────────

  // The routes are loopback-only by construction (the DSH web server binds a
  // loopback literal) and every request is checked against the DSH browser
  // credential when the connection service is available.
  function authorized(req) {
    const connection = ctx.get("connection");
    if (!connection || typeof connection.requestRejection !== "function") return true;
    try {
      return connection.requestRejection({ headers: req.headers }) === undefined;
    } catch (error) {
      warn(`bridge auth check failed: ${String(error)}`);
      return true;
    }
  }

  function sendJSON(res, status, body) {
    if (res.writableEnded) return;
    res.statusCode = status;
    res.setHeader("Content-Type", "application/json; charset=utf-8");
    res.setHeader("Cache-Control", "no-store");
    res.end(JSON.stringify(body));
  }

  function readJSON(req, limit = 64 * 1024) {
    return new Promise((resolve, reject) => {
      const chunks = [];
      let size = 0;
      req.on("data", (chunk) => {
        size += chunk.length;
        if (size > limit) {
          reject(new Error("body too large"));
          req.destroy();
          return;
        }
        chunks.push(chunk);
      });
      req.on("end", () => {
        try {
          const text = Buffer.concat(chunks).toString("utf8");
          resolve(text === "" ? {} : JSON.parse(text));
        } catch (error) {
          reject(error);
        }
      });
      req.on("error", reject);
    });
  }

  async function recentSessions(limit) {
    const sessionQuery = ctx.get("sessionQuery");
    if (!sessionQuery || typeof sessionQuery.listSessions !== "function") return [];

    const records = await sessionQuery.listSessions();
    const top = records
      .filter((record) => {
        const header = record?.header ?? {};
        return header.origin !== "subagent" && (header.parentSession === undefined || header.parentSession === null);
      })
      .slice(0, limit);

    const titles = new Map();
    try {
      const observations = await sessionQuery.readTitleSnapshots(
        top.map((record) => record.header.id)
      );
      for (const observation of observations) {
        const title = observation?.value?.title?.title;
        if (typeof title === "string" && title.trim() !== "") {
          titles.set(observation.sessionId, title);
        }
      }
    } catch (error) {
      warn(`could not read session titles: ${String(error)}`);
    }

    return top.map((record) => {
      const header = record.header;
      return {
        id: String(header.id),
        title: titles.get(header.id) ?? null,
        detail: typeof header.cwd === "string" && header.cwd !== "" ? basename(header.cwd) : null,
        createdAt: typeof header.createdAt === "number" ? header.createdAt : null,
      };
    });
  }

  function enqueue(command) {
    state.pending.push({ id: randomUUID(), at: Date.now(), ...command });
    while (state.pending.length > QUEUE_LIMIT) state.pending.shift();
  }

  // ─── Pending approvals ────────────────────────────────────────────────

  function asString(value, limit = 2000) {
    if (typeof value !== "string") return undefined;
    const trimmed = value.trim();
    if (trimmed === "") return undefined;
    return trimmed.length > limit ? trimmed.slice(0, limit) : trimmed;
  }

  function normalizeDisplayReason(value) {
    if (value === null || typeof value !== "object" || Array.isArray(value)) return undefined;
    const result = {};
    for (const [locale, text] of Object.entries(value)) {
      if (!/^[a-z]{2}(?:-[A-Za-z0-9]+)?$/.test(locale)) continue;
      if (typeof text !== "string" || text.trim() === "") continue;
      result[locale] = text.length > 8000 ? text.slice(0, 8000) : text;
      if (Object.keys(result).length >= 10) break;
    }
    return Object.keys(result).length > 0 ? result : undefined;
  }

  function normalizeApproval(raw) {
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return undefined;
    const key = asString(raw.key, 300);
    const sessionId = asString(raw.sessionId, 300);
    if (key === undefined || sessionId === undefined) return undefined;
    return {
      key,
      sessionId,
      sessionTitle: asString(raw.sessionTitle, 500),
      cwd: asString(raw.cwd, 1000),
      toolName: asString(raw.toolName, 200),
      reason: asString(raw.reason, 8000),
      displayReason: normalizeDisplayReason(raw.displayReason),
      isSubagent: raw.isSubagent === true,
      createdAt: Number.isFinite(raw.createdAt) ? raw.createdAt : undefined,
      firstSeenAt: Date.now(),
    };
  }

  function pendingApprovalItems() {
    const items = [];
    const now = Date.now();
    for (const [clientId, record] of state.approvalClients) {
      if (now - record.syncedAt > APPROVAL_TTL_MS) {
        state.approvalClients.delete(clientId);
        continue;
      }
      for (const item of record.items.values()) {
        items.push({ ...item, clientId });
      }
    }
    items.sort((left, right) => (left.firstSeenAt ?? 0) - (right.firstSeenAt ?? 0));
    return items;
  }

  function findApproval(clientId, key) {
    if (typeof clientId === "string" && clientId !== "") {
      const record = state.approvalClients.get(clientId);
      if (record === undefined || Date.now() - record.syncedAt > APPROVAL_TTL_MS) return undefined;
      const item = record.items.get(key);
      return item === undefined ? undefined : { ...item, clientId };
    }
    for (const [candidateClientId, record] of state.approvalClients) {
      if (Date.now() - record.syncedAt > APPROVAL_TTL_MS) continue;
      const item = record.items.get(key);
      if (item !== undefined) return { ...item, clientId: candidateClientId };
    }
    return undefined;
  }

  function removeApproval(clientId, key) {
    const record = state.approvalClients.get(clientId);
    if (record === undefined) return;
    record.items.delete(key);
    if (record.items.size === 0) state.approvalClients.delete(clientId);
  }

  if (typeof ctx.inject === "function") {
    ctx.inject(["webServer"], (httpCtx) => {
      const webServer = httpCtx.get("webServer");
      if (!webServer) {
        warn("webServer is unavailable; bridge routes disabled");
        return;
      }

      const disposers = [];
      const route = (path, handler) => {
        try {
          disposers.push(
            webServer.register({
              kind: "exact",
              path: `${ROUTE_BASE}/${path}`,
              handler,
            })
          );
        } catch (error) {
          warn(`could not register ${path}: ${String(error)}`);
        }
      };

      route("ping", (req, res) => {
        if (!authorized(req)) return sendJSON(res, 401, { ok: false, message: "unauthorized" });
        sendJSON(res, 200, {
          ok: true,
          version: VERSION,
          language: state.language ?? null,
          autoOpenApprovals: state.autoOpenApprovals,
          approvalCount: pendingApprovalItems().length,
          approvalUpdatedAt: state.lastApprovalSyncAt || null,
          clientReady: Date.now() - state.lastClientPollAt < CLIENT_READY_WINDOW_MS,
          lastAckAction: state.lastAckAction ?? null,
          lastAckAt: state.lastAckAt || null,
        });
      });

      route("recent", async (req, res) => {
        if (!authorized(req)) return sendJSON(res, 401, { ok: false, message: "unauthorized" });
        try {
          const url = new URL(req.url ?? "/", "http://127.0.0.1");
          const requested = Number.parseInt(url.searchParams.get("limit") ?? "5", 10);
          const limit = Number.isFinite(requested) ? Math.min(Math.max(requested, 1), 10) : 5;
          const items = await recentSessions(limit);
          sendJSON(res, 200, { ok: true, items });
        } catch (error) {
          warn(`recent failed: ${String(error)}`);
          sendJSON(res, 200, { ok: false, items: [], message: String(error) });
        }
      });

      route("approvals", (req, res) => {
        if (!authorized(req)) return sendJSON(res, 401, { ok: false, message: "unauthorized" });
        const items = pendingApprovalItems();
        sendJSON(res, 200, {
          ok: true,
          autoOpen: state.autoOpenApprovals,
          items,
          updatedAt: state.lastApprovalSyncAt || null,
        });
      });

      route("approvals/sync", async (req, res) => {
        if (!authorized(req)) return sendJSON(res, 401, { ok: false, message: "unauthorized" });
        try {
          const body = await readJSON(req, 512 * 1024);
          const clientId = asString(body?.clientId, 200);
          if (clientId === undefined) {
            return sendJSON(res, 400, { ok: false, message: "clientId is required" });
          }
          const previous = state.approvalClients.get(clientId);
          const items = new Map();
          const incoming = Array.isArray(body?.approvals) ? body.approvals.slice(0, 50) : [];
          for (const raw of incoming) {
            const item = normalizeApproval(raw);
            if (item === undefined) continue;
            const previousItem = previous?.items.get(item.key);
            if (previousItem?.firstSeenAt !== undefined) item.firstSeenAt = previousItem.firstSeenAt;
            items.set(item.key, item);
          }
          if (items.size === 0) {
            state.approvalClients.delete(clientId);
          } else {
            state.approvalClients.set(clientId, { items, syncedAt: Date.now() });
          }
          state.lastApprovalSyncAt = Date.now();
          sendJSON(res, 200, { ok: true, count: items.size });
        } catch (error) {
          sendJSON(res, 400, { ok: false, message: String(error) });
        }
      });

      route("approval-answer", async (req, res) => {
        if (!authorized(req)) return sendJSON(res, 401, { ok: false, message: "unauthorized" });
        try {
          const body = await readJSON(req);
          const key = asString(body?.key, 300);
          const decision = body?.decision;
          if (key === undefined || (decision !== "allowed-once" && decision !== "rejected")) {
            return sendJSON(res, 400, { ok: false, message: "key and a valid decision are required" });
          }
          const item = findApproval(body?.clientId, key);
          if (item === undefined) {
            return sendJSON(res, 409, { ok: false, message: "approval is no longer pending" });
          }
          enqueue({
            action: "approval-answer",
            key,
            decision,
            targetClientId: item.clientId,
          });
          sendJSON(res, 200, { ok: true });
        } catch (error) {
          sendJSON(res, 400, { ok: false, message: String(error) });
        }
      });

      route("action", async (req, res) => {
        if (!authorized(req)) return sendJSON(res, 401, { ok: false, message: "unauthorized" });
        try {
          const body = await readJSON(req);
          const action = body?.action;
          if (action !== "new-session" && action !== "open-session") {
            return sendJSON(res, 400, { ok: false, message: "unsupported action" });
          }
          if (action === "open-session" && (typeof body?.sessionId !== "string" || body.sessionId === "")) {
            return sendJSON(res, 400, { ok: false, message: "sessionId is required" });
          }
          enqueue({
            action,
            sessionId: action === "open-session" ? body.sessionId : undefined,
          });
          sendJSON(res, 200, { ok: true });
        } catch (error) {
          sendJSON(res, 400, { ok: false, message: String(error) });
        }
      });

      route("pending", (req, res) => {
        if (!authorized(req)) return sendJSON(res, 401, { ok: false, message: "unauthorized" });
        state.lastClientPollAt = Date.now();
        const url = new URL(req.url ?? "/", "http://127.0.0.1");
        const clientId = url.searchParams.get("client") ?? undefined;
        const now = Date.now();
        const commands = [];
        const keep = [];
        for (const command of state.pending) {
          if (now - command.at >= 15_000) continue;
          if (typeof command.targetClientId === "string" && command.targetClientId !== clientId) {
            keep.push(command);
            continue;
          }
          commands.push(command);
        }
        state.pending = keep;
        sendJSON(res, 200, { ok: true, commands });
      });

      route("ack", async (req, res) => {
        if (!authorized(req)) return sendJSON(res, 401, { ok: false, message: "unauthorized" });
        try {
          const body = await readJSON(req);
          if (typeof body?.action === "string") state.lastAckAction = body.action;
          if (
            body?.action === "approval-answer" &&
            body?.ok === true &&
            typeof body?.clientId === "string" &&
            typeof body?.key === "string"
          ) {
            removeApproval(body.clientId, body.key);
          }
          state.lastAckAt = Date.now();
          sendJSON(res, 200, { ok: true });
        } catch (error) {
          sendJSON(res, 400, { ok: false, message: String(error) });
        }
      });

      if (typeof httpCtx.effect === "function") {
        httpCtx.effect(() => {
          return () => {
            for (const dispose of disposers) {
              try {
                dispose();
              } catch {
                // Route already gone.
              }
            }
          };
        }, "dsh-flick: bridge routes");
      }
    });
  } else {
    warn("ctx.inject is unavailable; bridge routes disabled");
  }
}
