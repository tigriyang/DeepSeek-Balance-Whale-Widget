/**
 * dsh-notify-bridge —— 把对话输出桥接到系统通知，并支持在通知里回复。
 *
 * 为什么需要它：
 *   WhaleFloat 是独立进程，既看不到对话内容，也无法把文字送回对话。
 *   所以由本插件做中介：
 *     出：监听 assistant 回复 → 写 ~/.dsh/.whalefloat-notify.json
 *     入：轮询 ~/.dsh/.whalefloat-reply.json → 调 agent.followup(text) 注入
 *
 * 注入用的是 DSH 自己的 API（ctx.agents.get(id).followup），
 * 不是模拟输入 —— 回复会正常作为「用户消息」进入对话。
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const OUT = path.join(os.homedir(), ".dsh", ".whalefloat-notify.json");
const IN = path.join(os.homedir(), ".dsh", ".whalefloat-reply.json");

/** 轮询间隔（毫秒）。 */
const POLL_MS = 700;
/** 最多保留多少条待读通知。 */
const MAX_PENDING = 20;

function write(url, obj) {
	try {
		fs.mkdirSync(path.dirname(url), { recursive: true });
		fs.writeFileSync(url, JSON.stringify(obj), "utf8");
	} catch {
		/* 写失败不影响宿主 */
	}
}

function read(url) {
	try {
		return JSON.parse(fs.readFileSync(url, "utf8"));
	} catch {
		return undefined;
	}
}

function apply(ctx) {
	let pending = [];
	let lastReplySeq = 0;
	const titles = new Map();

	function flush() {
		write(OUT, { items: pending.slice(-MAX_PENDING), updatedAt: Date.now() });
	}

	ctx.inject(["sessions"], (sctx) => {
		sctx.on("session/event", (session, event) => {
			try {
				const type = String(event?.type ?? "");
				const sid = session?.id ?? "default";

				if (type === "session/title") {
					const t = String(event?.data?.title ?? "").trim();
					if (t) titles.set(sid, t);
					return;
				}

				if (type !== "assistant/message") return;
				const data = event?.data ?? {};
				const msg = data.message ?? {};
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

				pending.push({
					id: `n${Date.now()}_${pending.length}`,
					sessionId: sid,
					title: titles.get(sid) ?? "DSH",
					text: text.slice(0, 400),
					ts: Date.now(),
				});
				flush();
			} catch {
				/* 吞掉 */
			}
		}, "notify-bridge: session events");
	});

	const timer = setInterval(() => {
		try {
			const box = read(IN);
			if (!box || typeof box.seq !== "number") return;
			if (box.seq <= lastReplySeq) return;
			lastReplySeq = box.seq;

			const text = String(box.text ?? "").trim();
			if (text === "") return;
			const sid = String(box.sessionId ?? "");

			const agents = ctx.get("agents");
			const agent = sid ? agents?.get?.(sid) : undefined;
			if (agent && typeof agent.followup === "function") {
				agent.followup(text);
				ctx.logger?.info?.(`notify-bridge: 已注入回复（session ${sid}）`);
			} else {
				ctx.logger?.warn?.(`notify-bridge: 找不到 agent(${sid})`);
			}
		} catch (err) {
			ctx.logger?.warn?.(`notify-bridge: 注入失败 ${err}`);
		}
	}, POLL_MS);

	ctx.effect(() => () => clearInterval(timer), "notify-bridge.poll()");

	flush();
	ctx.logger?.info?.(`dsh-notify-bridge: 出 ${OUT} / 入 ${IN}`);
}

export { apply };
export const name = "notify-bridge";
