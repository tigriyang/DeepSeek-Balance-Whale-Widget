/**
 * dsh-whalefloat-helper —— 鲸鱼浮窗的 DSH 侧中介。
 *
 * 三个子系统各自往一个文件写：
 *   wait     → ~/.dsh/.whalefloat-wait.json      （DSH 在等用户回答/授权）
 *   usage    → ~/.dsh/.whalefloat-usage.json     （每轮 token 与金额）
 *   notify   → ~/.dsh/.whalefloat-notify.json    （推给系统通知的内容）
 *
 * 另有反向通道：
 *   reply    ← ~/.dsh/.whalefloat-reply.json     （用户在通知里回的文本）
 *   轮询到后调 agent.followup() 注入对话。
 *
 * 原先拆成三个插件，后来合并 —— 三者订阅的是同一条 session/event 流。
 * 所有异常都被吞掉：中介出问题不该影响宿主。
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";

const DSH_DIR = path.join(os.homedir(), ".dsh");
const F = {
	wait: path.join(DSH_DIR, ".whalefloat-wait.json"),
	usage: path.join(DSH_DIR, ".whalefloat-usage.json"),
	notify: path.join(DSH_DIR, ".whalefloat-notify.json"),
	reply: path.join(DSH_DIR, ".whalefloat-reply.json"),
};

const QUESTION_TOOL = "ask_user_question";
const MAX_EVENTS = 500;
const MAX_PENDING = 20;
const POLL_MS = 700;

// ── 通用 IO ─────────────────────────────────────────────────────────

function writeJSON(url, obj) {
	try {
		fs.mkdirSync(path.dirname(url), { recursive: true });
		fs.writeFileSync(url, JSON.stringify(obj), "utf8");
	} catch {
		/* 写失败不影响宿主 */
	}
}

function readJSON(url) {
	try {
		return JSON.parse(fs.readFileSync(url, "utf8"));
	} catch {
		return undefined;
	}
}

// ── 时间与计价（与 WhaleFloat 的 PeakValley 同一套规则）──────────────

function beijingTime(date) {
	return new Date(date.getTime() + (8 * 60 + date.getTimezoneOffset()) * 60000);
}

function dayKey(date) {
	return beijingTime(date).toISOString().slice(0, 10);
}

/** 是否高峰（北京时间工作日 9-12、14-18）。 */
function isPeak(date) {
	const bj = beijingTime(date);
	const day = bj.getDay();
	if (day === 0 || day === 6) return false;
	const h = bj.getHours();
	return (h >= 9 && h < 12) || (h >= 14 && h < 18);
}

/** 官方 2026-09-10 调价后的 CNY / 百万 token。 */
const PRICE = {
	flash: { hit: 0.02, miss: 1.0, out: 4.0 },
	pro: { hit: 0.06, miss: 3.0, out: 12.0 },
};

function priceFor(model) {
	return /pro/i.test(String(model)) ? PRICE.pro : PRICE.flash;
}

function costOf(usage, model, at) {
	const p = priceFor(model);
	const input = Number(usage.inputTokens) || 0;
	const cacheRead = Number(usage.cacheReadTokens) || 0;
	const output = Number(usage.outputTokens) || 0;
	const amount = (input / 1e6) * p.miss + (cacheRead / 1e6) * p.hit + (output / 1e6) * p.out;
	return amount * (isPeak(at) ? 2 : 1);
}

/** 从事件里取工具调用 id。 */
function callId(event) {
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

// ── 子系统一：等待状态 ─────────────────────────────────────────────

const wait = {
	state: { pending: null, sessionName: "", updatedAt: 0 },

	flush() {
		this.state.updatedAt = Date.now();
		writeJSON(F.wait, this.state);
	},

	handle(event) {
		const type = String(event?.type ?? "");
		const data = event?.data ?? {};
		const now = Date.now();

		if (type === "session/title") {
			const t = String(data.title ?? "").trim();
			if (t) {
				this.state.sessionName = t.slice(0, 120);
				this.flush();
			}
			return;
		}

		if (type === "tool/call" && String(data.name ?? data.toolName ?? "") === QUESTION_TOOL) {
			this.state.pending = { kind: "question", id: callId(event) || `q${now}`, ts: now };
			this.flush();
			return;
		}

		if (type === "tool/result") {
			if (this.state.pending?.kind === "question") {
				const cid = callId(event);
				if (!cid || cid === this.state.pending.id) {
					this.state.pending = null;
					this.flush();
				}
			}
			return;
		}

		if (type === "approval/asked") {
			this.state.pending = { kind: "approval", id: String(data.id ?? `a${now}`), ts: now };
			this.flush();
			return;
		}

		if (type.startsWith("approval/")) {
			if (this.state.pending?.kind === "approval") {
				const id = String(data.id ?? "");
				if (!id || id === this.state.pending.id) {
					this.state.pending = null;
					this.flush();
				}
			}
			return;
		}

		// 轮次边界一律复位，避免状态卡住
		if (type === "turn/start" || type === "turn/end") {
			if (this.state.pending !== null) {
				this.state.pending = null;
				this.flush();
			}
		}
	},
};

// ── 子系统二：每轮用量 ─────────────────────────────────────────────

const usage = {
	handle(event) {
		if (String(event?.type ?? "") !== "assistant/message") return;
		const data = event?.data ?? {};
		const message = data.message ?? {};
		if (message.role !== "assistant") return;

		const u = message.usage ?? data.usage;
		if (!u || typeof u !== "object") return;
		const input = Number(u.inputTokens) || 0;
		const cacheRead = Number(u.cacheReadTokens) || 0;
		const output = Number(u.outputTokens) || 0;
		if (input + cacheRead + output === 0) return;

		const at = typeof event.time === "number" ? event.time : Date.now();
		const model = String(data.model ?? message.model ?? "deepseek-flash");
		const ledger = readJSON(F.usage) ?? { events: [] };
		if (!Array.isArray(ledger.events)) ledger.events = [];

		ledger.events.push({
			ts: at,
			day: dayKey(new Date(at)),
			model,
			cost: costOf(u, model, new Date(at)),
			tokens: input + cacheRead + output,
		});
		ledger.events = ledger.events.slice(-MAX_EVENTS);
		ledger.updatedAt = Date.now();
		writeJSON(F.usage, ledger);
	},
};

// ── 子系统三：通知桥接 ─────────────────────────────────────────────

const notify = {
	pending: [],
	titles: new Map(),

	handle(event, session) {
		const type = String(event?.type ?? "");
		// 拿不到会话标识就不推。
		// 推出去的通知里没 sessionId，用户点「回复」时无从路由 ——
		// 要么静默失败，要么落到别的会话上，那才是真正的「串」。
		// 宁可少一条通知，也不要推一条回不了的。
		const sid = String(session?.id ?? "");
		if (sid === "") return;

		if (type === "session/title") {
			const t = String(event?.data?.title ?? "").trim();
			if (t) this.titles.set(sid, t);
			return;
		}
		if (type !== "assistant/message") return;

		const msg = event?.data?.message ?? {};
		if (msg.role !== "assistant") return;

		let text = "";
		if (typeof msg.content === "string") {
			text = msg.content;
		} else if (Array.isArray(msg.content)) {
			text = msg.content
				.filter((c) => c && (c.type === "text" || typeof c.text === "string"))
				.map((c) => String(c.text ?? ""))
				.join("");
		}
		text = text.trim();
		if (text === "") return;

		this.pending.push({
			id: `n${Date.now()}_${this.pending.length}`,
			sessionId: sid,
			title: this.titles.get(sid) ?? "DSH",
			text: text.slice(0, 400),
			ts: Date.now(),
		});
		this.flush();
	},

	flush() {
		writeJSON(F.notify, {
			items: this.pending.slice(-MAX_PENDING),
			updatedAt: Date.now(),
		});
	},
};

// ── 反向通道：通知里的回复 → 注入对话 ─────────────────────────────

/**
 * 把一条回复投进对话。
 *
 * 三处曾经写错、导致回复「石沉大海」：
 *   ① 服务名不是 agents —— 按 sessionId 解析 agent 的是
 *      sessionController.resolveAgent(id)，返回 { agent } 或 { error }
 *   ② followup() 要的是完整的 UserMessage 对象，不是字符串
 *   ③ 消息必须用 createUserMessage 造（补 id 并冻结），不能自己拼
 */
/**
 * 造一条用户消息。
 *
 * DSH 自带的 createUserMessage 在 @deepseek-ai/dsh-llm 里，但插件目录
 * 解析不到那个包（除非像 searxng 插件那样往自己 node_modules 里做软链，
 * 而软链绑死了 DSH 的安装路径，换台机器就断）。
 * 它内部其实只有一句：{...input, id: uuid} 再冻结 —— 这里照做。
 */
function makeUserMessage(text) {
	return Object.freeze({
		id: randomUUID(),
		role: "user",
		content: Object.freeze([Object.freeze({ type: "text", text })]),
		source: Object.freeze({ kind: "user" }),
	});
}

async function deliverReply(sc, sessions, sessionId, text) {
	const resolved = await sc.resolveAgent(sessionId);
	if (resolved && "error" in resolved) {
		throw new Error(`resolveAgent 失败: ${resolved.error}`);
	}
	const agent = resolved?.agent;
	if (!agent) throw new Error("resolveAgent 没返回 agent");

	agent.followup(makeUserMessage(text));
	// 立刻落盘 —— 别等下一轮自动 flush，用户正等着看回复有没有进去
	await sessions?.flush?.(agent.session);
}

/**
 * 起一次新对话。
 *
 * 不传 cwd 就用 DSH 的 defaultCwd —— 插件不知道用户的工作区在哪，
 * 也没必要猜。会话建好后立刻把首条消息投进去，DSH 就会开口。
 */
/// 上一次成功发起新会话的时刻，用于防抖。
let lastNewSessionAt = 0;
/// 同一时刻只允许一个在建。观察到过同一条回复被两个 poller 各处理一次，
/// 结果是点一下建出两个会话 —— 除了游标，再加一道时间闸。
const NEW_SESSION_DEBOUNCE_MS = 5000;

async function startNewSession(sc, sessions, text, workspaces) {
	// 这条链路牵涉 DSH 内部好几个服务，出错时宿主那边看不到任何提示。
	// 落一份日志到 /tmp，用户报「点了没反应」时能直接看出卡在哪。
	const now = Date.now();
	if (now - lastNewSessionAt < NEW_SESSION_DEBOUNCE_MS) {
		log("忽略 5 秒内的重复新会话请求");
		return "";
	}
	lastNewSessionAt = now;
	try {
		// 方法名是 create，不是 createSession ——
		// 后者是内部的另一层（SessionController 上），没被 RPC 代理暴露，
		// 调它会得到 "sc.createSession is not a function"。
		// create 是业务命令层（SessionCommandController）的，返回 { sessionId, agentPreset }。
		//
		// 传空对象 —— 刻意不指定 agentPreset，让 DSH 用用户自己在设置里选的那套。
		// 传了就把会话钉在某个 preset 上，用户换了模型，新会话还是旧的。
		//
		// 要带 workspaceId：只给 cwd 的话会话能建出来，但没有工作区归属，
		// 在 DSH 侧边栏里会落到「未分组」。工作区还会决定它在哪个分组、
		// 以及能不能被那一组的文件上下文找到。
		const list = workspaces?.list?.() ?? [];
		log("workspaces 服务=" + (workspaces ? "有" : "无")
			+ " 数量=" + list.length
			+ (list.length ? " ids=" + list.map((w) => w.id).join(",") : ""));
		const ws = list[0];
		const created = ws ? await sc.create({ workspaceId: ws.id }) : await sc.create({});
		const sid = String(created?.sessionId ?? "");
		if (sid === "") throw new Error("create 没返回 sessionId");

		// 会话建好后把首条投进去
		await deliverReply(sc, sessions, sid, text);
		log("新会话已投递 session=" + sid);
		return sid;
	} catch (err) {
		log("startNewSession 失败: " + (err && err.message ? err.message : err));
		throw err;
	}
}

/** 往 /tmp 追加一行诊断。失败就算了，不能因为写日志把宿主搞挂。 */
function log(msg) {
	try {
		fs.appendFileSync("/tmp/whalefloat-helper.log",
			new Date().toISOString() + " " + msg + "\n");
	} catch {
		/* 无妨 */
	}
}

function makeReplyPoller(ctx, sc, sessions, workspaces) {
	let lastSeq = 0;
	return setInterval(() => {
		void (async () => {
			try {
				const box = readJSON(F.reply);
				if (!box || typeof box.seq !== "number" || box.seq <= lastSeq) return;
				// 先推进游标，避免同一条被反复投递
				lastSeq = box.seq;

				const text = String(box.text ?? "").trim();
				if (text === "") return;

				// newSession：不投给现有会话，而是开一个新的
				if (box.newSession === true) {
					const sid = await startNewSession(sc, sessions, text, workspaces);
					ctx.logger?.info?.(`whalefloat-helper: 已新建会话 ${sid}`);
					return;
				}

				const sid = String(box.sessionId ?? "");
				if (sid === "") return;
				await deliverReply(sc, sessions, sid, text);
				ctx.logger?.info?.(`whalefloat-helper: 已注入回复（session ${sid}）`);
			} catch (err) {
				ctx.logger?.warn?.(`whalefloat-helper: 注入失败 ${err}`);
			}
		})();
	}, POLL_MS);
}

// ── 装配 ───────────────────────────────────────────────────────────

/// 记录 apply 被调了几次 —— 如果插件被加载两遍，这里会大于 1，
/// 同时也会有两个 poller 在跑，同一条回复被处理两次。
let applyCount = 0;

function apply(ctx) {
	applyCount += 1;
	log("apply 第 " + applyCount + " 次被调用");
	// 事件在 sessions 服务的 context 上发出 —— 必须先注入该服务再订阅，
	// 直接在插件根 ctx 上订阅收不到。
	// sessionController 用于把通知里的回复投回对话。
	ctx.inject(["sessions", "sessionController", "workspaceRegistry"], (sctx) => {
		sctx.on("session/event", (session, event) => {
			try {
				wait.handle(event);
				usage.handle(event);
				notify.handle(event, session);
			} catch {
				/* 任何异常都不影响宿主 */
			}
		}, "whalefloat-helper: session events");

		log("poller 启动（第 " + applyCount + " 个）");
		const timer = makeReplyPoller(ctx, sctx.sessionController, sctx.sessions, sctx.workspaceRegistry);
		sctx.effect(() => () => clearInterval(timer), "whalefloat-helper.reply-poll()");
	});

	// 启动先落一次盘，让读取方不必等第一个事件
	wait.flush();
	notify.flush();
	ctx.logger?.info?.(`dsh-whalefloat-helper: 输出 ${DSH_DIR}/.whalefloat-*.json`);
}

export { apply };
export const name = "whalefloat-helper";
