/**
 * dsh-turn-usage —— 采集每轮对话的用量，落成 WhaleFloat 读的账本。
 *
 * 为什么需要它：
 *   WhaleFloat 的「每轮消耗」原先读 dsh-whale-widget 的账本。
 *   网页版鲸鱼已停用，这条数据源随之断掉 —— 所以自己采一份。
 *
 * 数据来源（与鲸鱼同源，都是 DSH 的事件流）：
 *   session/event 里的 assistant/message 事件带 usage：
 *     { inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, totalTokens }
 *
 * 计价：按官方峰谷价折算成人民币（与 WhaleFloat 的 TurnCost 用同一套规则）。
 *
 * 输出：~/.dsh/.whalefloat-usage.json
 *   { "events": [ { ts, day, model, cost, tokens } ... ], "updatedAt": ... }
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const OUT = path.join(os.homedir(), ".dsh", ".whalefloat-usage.json");
/** 最多保留多少条（够 WhaleFloat 显示，也不至于无限增长）。 */
const MAX_EVENTS = 500;

// ── 计价（CNY / 百万 token，官方 2026-09-10 调价后）────────────────────
const PRICE = {
	flash: { hit: 0.02, miss: 1.0, out: 4.0 },
	pro: { hit: 0.06, miss: 3.0, out: 12.0 },
};

function priceFor(model) {
	return /pro/i.test(String(model)) ? PRICE.pro : PRICE.flash;
}

/** 是否高峰时段（北京时间工作日 9-12、14-18）。 */
function isPeak(date) {
	const bj = new Date(date.getTime() + (8 * 60 + date.getTimezoneOffset()) * 60000);
	const day = bj.getDay();                       // 0=周日 6=周六
	if (day === 0 || day === 6) return false;
	const h = bj.getHours();
	return (h >= 9 && h < 12) || (h >= 14 && h < 18);
}

/** 一轮的金额（元）。reasoningTokens 已含在 outputTokens 内，不重复计。 */
function costOf(usage, model, at) {
	const p = priceFor(model);
	const input = Number(usage.inputTokens) || 0;
	const cacheRead = Number(usage.cacheReadTokens) || 0;
	const output = Number(usage.outputTokens) || 0;
	const amount =
		(input / 1e6) * p.miss +
		(cacheRead / 1e6) * p.hit +
		(output / 1e6) * p.out;
	return amount * (isPeak(at) ? 2 : 1);
}

function dayKey(date) {
	const bj = new Date(date.getTime() + (8 * 60 + date.getTimezoneOffset()) * 60000);
	return bj.toISOString().slice(0, 10);
}

// ── 账本读写 ─────────────────────────────────────────────────────────
function load() {
	try {
		const raw = fs.readFileSync(OUT, "utf8");
		const parsed = JSON.parse(raw);
		if (parsed && Array.isArray(parsed.events)) return parsed;
	} catch {
		/* 首次运行或文件损坏都从头开始 */
	}
	return { events: [] };
}

function save(ledger) {
	ledger.events = ledger.events.slice(-MAX_EVENTS);
	ledger.updatedAt = Date.now();
	try {
		fs.mkdirSync(path.dirname(OUT), { recursive: true });
		fs.writeFileSync(OUT, JSON.stringify(ledger), "utf8");
	} catch {
		/* 写失败不影响宿主 */
	}
}

/** 从 assistant/message 事件里抠出 usage 与模型名。 */
function extract(event) {
	const data = event?.data ?? {};
	const message = data.message ?? {};
	if (message.role !== "assistant") return null;
	const usage = message.usage ?? data.usage;
	if (!usage || typeof usage !== "object") return null;
	const model = String(data.model ?? message.model ?? "deepseek-flash");
	const input = Number(usage.inputTokens) || 0;
	const cacheRead = Number(usage.cacheReadTokens) || 0;
	const output = Number(usage.outputTokens) || 0;
	if (input + cacheRead + output === 0) return null;
	return { usage, model, tokens: input + cacheRead + output };
}

function apply(ctx) {
	// 同 dsh-wait-state：事件在 sessions 服务的 context 上发出，
	// 必须先注入该服务再订阅，否则收不到。
	ctx.inject(["sessions"], (sctx) => {
	sctx.on("session/event", (session, event) => {
		try {
			if (String(event?.type ?? "") !== "assistant/message") return;
			const got = extract(event);
			if (got === null) return;

			const at = typeof event.time === "number" ? event.time : Date.now();
			const ledger = load();
			ledger.events.push({
				ts: at,
				day: dayKey(new Date(at)),
				model: got.model,
				cost: costOf(got.usage, got.model, new Date(at)),
				tokens: got.tokens,
			});
			save(ledger);
		} catch {
			/* 任何异常都不影响宿主 */
		}
	}, "turn-usage: session events");
	});

	ctx.logger?.info?.(`dsh-turn-usage: 账本 ${OUT}`);
}

export { apply };
export const name = "turn-usage";
