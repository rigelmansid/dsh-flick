/**
 * DSH Flick — Client half.
 *
 * The menu bar app cannot drive the DSH page directly. It posts commands to the
 * Host bridge; this module polls that bridge from inside the DSH page and runs
 * the UI navigation through the Client's own services.
 *
 * It also mirrors the page's pending approval interactions to the Host bridge
 * so the menu bar can show and answer them. The decision is submitted through
 * the same `PendingApproval` object the DSH composer uses, so the two surfaces
 * can never disagree about whether a request is still pending.
 *
 * No UI is registered: the native menu bar panel is the only surface here.
 */
window.__ModuleLoader__.load({
  id: "dsh-flick",
  factory() {
    return {
      inject: ["uiWorkspace", "uiSession", "sessions"],
      apply(ctx) {
        let disposed = false;
        let timer;
        let inFlight = false;

        const clientId = (() => {
          const storageKey = "dsh-flick-client-id";
          try {
            const existing = sessionStorage.getItem(storageKey);
            if (existing) return existing;
          } catch {
            // Storage can be unavailable in hardened renderers; use an ephemeral id.
          }
          const generated = (() => {
            try {
              return crypto.randomUUID();
            } catch {
              return `client-${Date.now()}-${Math.random().toString(16).slice(2)}`;
            }
          })();
          try {
            sessionStorage.setItem(storageKey, generated);
          } catch {
            // Ignore; the host will clear the ephemeral id on reload.
          }
          return generated;
        })();

        let syncTimer;
        let syncAgain = false;
        let syncing = false;
        let lastSyncedPayload;
        const firstSeen = new Map();

        const sessionSummary = (sessionId) => {
          try {
            return ctx.sessions?.list?.getSnapshot?.()?.byId?.[sessionId];
          } catch {
            return undefined;
          }
        };

        const approvalSnapshot = () => {
          let statuses;
          try {
            statuses = ctx.uiSession?.sessionStatus?.getSnapshot?.();
          } catch {
            statuses = undefined;
          }
          if (!statuses || typeof statuses[Symbol.iterator] !== "function") return [];

          const now = Date.now();
          const seen = new Set();
          const approvals = [];
          for (const [sessionId, status] of statuses) {
            const interaction = status?.pendingInteraction;
            if (!interaction || interaction.kind !== "approval" || interaction.answerable === false) continue;
            const key = typeof interaction.key === "string" ? interaction.key : undefined;
            if (!key) continue;

            seen.add(key);
            if (!firstSeen.has(key)) firstSeen.set(key, now);
            const summary = sessionSummary(sessionId);
            approvals.push({
              key,
              sessionId: String(sessionId),
              sessionTitle:
                typeof summary?.displayTitle === "string"
                  ? summary.displayTitle
                  : typeof summary?.title === "string"
                    ? summary.title
                    : undefined,
              cwd: typeof summary?.cwd === "string" ? summary.cwd : undefined,
              toolName: typeof interaction.toolName === "string" ? interaction.toolName : undefined,
              reason: typeof interaction.reason === "string" ? interaction.reason : undefined,
              displayReason:
                interaction.displayReason && typeof interaction.displayReason === "object"
                  ? interaction.displayReason
                  : undefined,
              isSubagent: summary?.origin === "subagent" || summary?.parentId != null,
              createdAt: firstSeen.get(key),
            });
          }

          for (const key of firstSeen.keys()) {
            if (!seen.has(key)) firstSeen.delete(key);
          }
          approvals.sort((left, right) => (left.createdAt ?? 0) - (right.createdAt ?? 0));
          return approvals;
        };

        const scheduleSync = () => {
          if (disposed) return;
          if (syncTimer !== undefined) clearTimeout(syncTimer);
          syncTimer = setTimeout(() => {
            syncTimer = undefined;
            void syncNow();
          }, 150);
        };

        const syncNow = async (force = false) => {
          if (disposed) return;
          if (syncing) {
            syncAgain = true;
            return;
          }
          syncing = true;
          try {
            const payload = JSON.stringify({ clientId, approvals: approvalSnapshot() });
            if (!force && payload === lastSyncedPayload) return;
            const response = await fetch("/dsh-flick/api/approvals/sync", {
              method: "POST",
              cache: "no-store",
              headers: { "Content-Type": "application/json" },
              body: payload,
            });
            if (response.ok) lastSyncedPayload = payload;
          } catch {
            // The Host may be starting or reloading; retry on the next tick.
          } finally {
            syncing = false;
            if (syncAgain) {
              syncAgain = false;
              scheduleSync();
            }
          }
        };

        const findApproval = (key) => {
          let statuses;
          try {
            statuses = ctx.uiSession?.sessionStatus?.getSnapshot?.();
          } catch {
            statuses = undefined;
          }
          if (!statuses) return undefined;
          for (const status of statuses.values()) {
            const interaction = status?.pendingInteraction;
            if (interaction?.kind === "approval" && interaction.key === key) return interaction;
          }
          return undefined;
        };

        const answerApproval = async (command) => {
          const interaction = findApproval(command.key);
          if (!interaction) throw new Error("审批已经结束");
          if (interaction.answerable === false) throw new Error("审批已经结束");
          const decision = command.decision === "rejected" ? "rejected" : "allowed-once";
          await interaction.answer(decision);
          scheduleSync();
        };

        const postAck = async (body) => {
          await fetch("/dsh-flick/api/ack", {
            method: "POST",
            cache: "no-store",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ ...body, clientId }),
          }).catch(() => {});
        };

        const execute = async (command) => {
          if (!command || typeof command.action !== "string") return;
          try {
            if (command.action === "approval-answer") {
              await answerApproval(command);
            } else if (command.action === "new-session") {
              ctx.uiWorkspace.startSession();
            } else if (command.action === "open-session" && typeof command.sessionId === "string") {
              ctx.uiWorkspace.openSession(command.sessionId);
            } else {
              return;
            }
            await postAck({
              action: command.action,
              sessionId: command.sessionId,
              key: command.key,
              id: command.id,
              ok: true,
            });
          } catch (error) {
            console.error("[dsh-flick] command failed", error);
            await postAck({
              action: command.action,
              sessionId: command.sessionId,
              key: command.key,
              id: command.id,
              ok: false,
              error: String(error?.message ?? error),
            });
          }
        };

        const poll = async () => {
          if (disposed || inFlight) return;
          inFlight = true;
          try {
            const response = await fetch(
              `/dsh-flick/api/pending?client=${encodeURIComponent(clientId)}`,
              {
                cache: "no-store",
                headers: { Accept: "application/json" },
              }
            );
            if (!response.ok) return;
            const data = await response.json();
            for (const command of data?.commands ?? []) {
              await execute(command);
            }
          } catch {
            // The Host may still be starting up or reloading; retry next tick.
          } finally {
            inFlight = false;
          }
        };

        const start = () => {
          let unsubscribe;
          try {
            const status = ctx.uiSession?.sessionStatus;
            if (status && typeof status.subscribe === "function") {
              unsubscribe = status.subscribe(scheduleSync);
            }
          } catch {
            unsubscribe = undefined;
          }

          void syncNow(true);
          const syncInterval = setInterval(() => {
            void syncNow();
          }, 2000);

          poll();
          timer = setInterval(poll, 700);

          ctx.effect(() => {
            return () => {
              disposed = true;
              if (timer !== undefined) clearInterval(timer);
              clearInterval(syncInterval);
              if (syncTimer !== undefined) clearTimeout(syncTimer);
              if (typeof unsubscribe === "function") unsubscribe();
            };
          }, "dsh-flick: bridge polling");
        };

        start();
      },
    };
  },
});
