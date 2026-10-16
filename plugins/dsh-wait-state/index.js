/**
 * dsh-wait-state —— 把「DSH 正在等用户回答 / 授权」落成一个小文件。
 *
 * 为什么需要它：
 *   WhaleFloat 是独立于 DSH 的原生程序，拿不到 DSH 的事件流。
 *   但「正在等老大回答/授权」这种状态只有 DSH 知道。
 *   所以由本插件挂在 DSH 上监听事件，状态变化时写一个 JSON；
 *   WhaleFloat 每秒读那个文件即可 —— 与读鲸鱼账本同一模式。
 *
 * 监听的事件（对照 dsh-whale-widget 的实现，2026-10-15）：
 *   tool/call      且 name === 'ask_user_question'  → 提问开始
 *   tool/result                                      → 提问结束
 *   approval/asked                                   → 授权请求
 *   approval/*                                       → 授权结束
 *   turn/start · turn/end                            → 一律复位
 *   session/title                                    → 记录对话名
 *
 * 输出：~/.dsh/.whalefloat-wait.json
 *   { "pending": {"kind":"question"|"approval","ts":123}, "sessionName":"…", "updatedAt":123 }
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const OUT = path.join(os.homedir(), ".dsh", ".whalefloat-wait.json");
/** DSH 里负责向用户提问的工具名。 */
const QUESTION_TOOL = "ask_user_question";

const state = { pending: null, sessionName: "", updatedAt: 0 };

function flush() {
	state.updatedAt = Date.now();
	try {
		fs.mkdirSync(path.dirname(OUT), { recursive: true });
		fs.writeFileSync(OUT, JSON.stringify(state), "utf8");
	} catch {
		/* 写失败不影响宿主 */
	}
}

function eventCallId(event) {
	const d = event?.data ?? {};
	const msg = d.message ?? {};
	const list = Array.isArray(msg.content) ? msg.content : [];
	for (const c of list) {
		const id = c?.toolCallId ?? c?.tool_call_id;
		if (id) return String(id);
	}
	const id = msg.callId ?? msg.toolCallId ?? d.callId ?? d.toolCallId ?? d.id;
	return id ? String(id) : "";
}

function apply(ctx) {
	// 事件在 **sessions 服务的 context** 上发出（dsh-session 里 emitCtx = 创建 session 的 ctx），
	// 直接在插件根 ctx 上订阅收不到 —— 必须先注入该服务。
	ctx.inject(["sessions"], (sctx) => {
	sctx.on("session/event", (session, event) => {
		try {
			const type = String(event?.type ?? "");
			// 诊断日志：只在有需要时打开（写 /tmp/wait-events.log）。
			// 记类型，工具类事件额外记工具名 —— 排查「为什么等待泡没出现」时，
			// 光看事件类型不够，得知道具体调的是哪个工具。
			if (process.env.WHALEFLOAT_DEBUG === "1") {
				try {
					const extra = type === "tool/call"
						? " " + String(event?.data?.name ?? event?.data?.toolName ?? "?")
						: "";
					fs.appendFileSync("/tmp/wait-events.log", type + extra + "\n");
				} catch { /* 忽略 */ }
			}
			const data = event?.data ?? {};
			const now = Date.now();

			// 对话名（用于提示泡第一行的 [ 对话名 ]）
			if (type === "session/title") {
				const t = String(data.title ?? "").trim();
				if (t) {
					state.sessionName = t.slice(0, 120);
					flush();
				}
				return;
			}

			// 提问：tool/call 且是提问工具
			if (type === "tool/call" && String(data.name ?? data.toolName ?? "") === QUESTION_TOOL) {
				state.pending = { kind: "question", id: eventCallId(event) || `q${now}`, ts: now };
				flush();
				return;
			}
			// 提问结束
			if (type === "tool/result") {
				if (state.pending?.kind === "question") {
					const cid = eventCallId(event);
					if (!cid || cid === state.pending.id) {
						state.pending = null;
						flush();
					}
				}
				return;
			}
			// 授权请求
			if (type === "approval/asked") {
				state.pending = { kind: "approval", id: String(data.id ?? `a${now}`), ts: now };
				flush();
				return;
			}
			// 授权结束（approval/answered、approval/expired 等）
			if (type.startsWith("approval/")) {
				if (state.pending?.kind === "approval") {
					const id = String(data.id ?? "");
					if (!id || id === state.pending.id) {
						state.pending = null;
						flush();
					}
				}
				return;
			}
			// 轮次边界一律复位，避免状态卡住
			if (type === "turn/start" || type === "turn/end") {
				if (state.pending !== null) {
					state.pending = null;
					flush();
				}
			}
		} catch {
			/* 任何异常都不影响宿主 */
		}
	}, "wait-state: session events");
	});

	// 启动时先落一次盘，让读取方不必等第一次事件
	flush();
	ctx.logger?.info?.(`dsh-wait-state: 状态文件 ${OUT}`);
}

export { apply };
export const name = "wait-state";