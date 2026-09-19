#!/usr/bin/env node
/**
 * 额度数据层：汇总 Command Code 与 ChatGPT(Codex) 各账号的实时额度，输出一份 JSON。
 *
 * 用法:
 *   node fetch-quota.mjs                 # 结果打印到 stdout
 *   node fetch-quota.mjs --out cache.json
 *   node fetch-quota.mjs --pretty
 *
 * 数据来源:
 *   Command Code → ~/.commandcode/auth.json 里的 apiKey，调 /alpha/billing/credits
 *   ChatGPT      → Cockpit Tools 加密账号库(~/.antigravity_cockpit)，解密取 token 后调
 *                  https://chatgpt.com/backend-api/wham/usage
 *
 * 本脚本只读，不写回任何 Cockpit / Command Code 的数据文件。
 */

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import tls from 'node:tls';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HOME = os.homedir();
const ROOT = path.dirname(fileURLToPath(import.meta.url));

const DEFAULTS = {
  timeoutMs: 20000,
  proxy: 'auto',
  proxyCandidates: [
    'http://127.0.0.1:10808',
    'http://127.0.0.1:7890',
    'http://127.0.0.1:7897',
    'http://127.0.0.1:10809',
    'http://127.0.0.1:1080',
  ],
  commandCodeAuth: '~/.commandcode/auth.json',
  cockpitDir: '~/.antigravity_cockpit',
  codexUsageUrl: 'https://chatgpt.com/backend-api/wham/usage',
  commandCodeApi: 'https://api.commandcode.ai',
};

// Command Code 各套餐的月度总额度（取自 CLI 内置的计费表）
const PLAN_TOTAL_CREDITS = {
  'individual-go': 10,
  'individual-goat': 70,
  'individual-pro': 30,
  'individual-pro-v1': 80,
  'individual-provider': 15,
  'individual-max': 150,
  'individual-ultra': 300,
  'teams-pro': 40,
};
const PLAN_LABELS = {
  'individual-go': 'Go',
  'individual-goat': 'GOAT',
  'individual-pro': 'Pro',
  'individual-pro-v1': 'Pro',
  'individual-provider': 'Provider',
  'individual-max': 'Max',
  'individual-ultra': 'Ultra',
  'teams-pro': 'Teams Pro',
};

// ---------------------------------------------------------------- 基础设施

const expand = (p) => (p.startsWith('~') ? path.join(HOME, p.slice(1)) : p);

function readConfig() {
  try {
    const raw = JSON.parse(fs.readFileSync(path.join(ROOT, 'config.json'), 'utf8').replace(/^\uFEFF/, ''));
    return { ...DEFAULTS, ...raw };
  } catch {
    return { ...DEFAULTS };
  }
}

/** TCP 连通性探测，用来判断本地代理在不在 */
function probePort(url, timeoutMs = 500) {
  return new Promise((resolve) => {
    let target;
    try {
      target = new URL(url);
    } catch {
      return resolve(false);
    }
    const port = Number(target.port || 80);
    const sock = net.connect({ host: target.hostname, port });
    const finish = (ok) => {
      sock.destroy();
      resolve(ok);
    };
    sock.setTimeout(timeoutMs);
    sock.once('connect', () => finish(true));
    sock.once('timeout', () => finish(false));
    sock.once('error', () => finish(false));
  });
}

/** 系统代理设置（注册表），比固定端口表更贴近用户当前配置 */
function systemProxy() {
  if (process.platform !== 'win32') return null;
  try {
    const out = execFileSync(
      'reg',
      ['query', 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings', '/v', 'ProxyServer'],
      { encoding: 'utf8', timeout: 4000, windowsHide: true },
    );
    const m = out.match(/ProxyServer\s+REG_SZ\s+(\S+)/);
    if (m) return 'http://' + m[1].replace(/^https?:\/\//, '');
  } catch {
    /* 读不到就用候选表 */
  }
  return null;
}

/** 选定本地代理；全部探测不到则返回 null（直连） */
async function detectProxy(cfg, log) {
  if (cfg.proxy === 'off' || cfg.proxy === null) return null;
  if (typeof cfg.proxy === 'string' && cfg.proxy.startsWith('http')) return cfg.proxy;

  const candidates = [];
  const sys = systemProxy();
  if (sys) candidates.push(sys);
  for (const c of cfg.proxyCandidates) if (!candidates.includes(c)) candidates.push(c);

  for (const c of candidates) {
    if (await probePort(c)) {
      log(`proxy: 使用 ${c}`);
      return c;
    }
  }
  log('proxy: 未发现可用本地代理，直连');
  return null;
}

/**
 * 发一个 GET 请求。
 * 走代理时手工做 HTTP CONNECT 隧道 + TLS，不依赖 Node 版本或第三方库；
 * 本地回环地址一律直连（避免 Clash 因为 fake-ip 把自己也劫走）。
 */
function httpGet(rawUrl, { headers = {}, proxy = null, timeoutMs = 20000, method = 'GET' } = {}) {
  return new Promise((resolve, reject) => {
    const u = new URL(rawUrl);
    const isHttps = u.protocol === 'https:';
    const port = Number(u.port || (isHttps ? 443 : 80));
    const reqPath = u.pathname + u.search;
    const baseHeaders = { Host: u.host, 'Accept-Encoding': 'identity', ...headers };

    const collect = (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (d) => (body += d));
      res.on('end', () => resolve({ status: res.statusCode, body }));
    };

    const useProxy = proxy && !/^(127\.|localhost|::1)/.test(u.hostname);

    if (!useProxy) {
      const mod = isHttps ? https : http;
      const req = mod.request(
        { host: u.hostname, port, path: reqPath, method, headers: baseHeaders, timeout: timeoutMs },
        collect,
      );
      req.on('timeout', () => req.destroy(new Error('请求超时')));
      req.on('error', reject);
      req.end();
      return;
    }

    // --- 经代理：CONNECT 隧道 ---
    const p = new URL(proxy);
    const socket = net.connect({ host: p.hostname, port: Number(p.port || 80) });
    const fail = (err) => {
      socket.destroy();
      reject(err);
    };
    socket.setTimeout(timeoutMs, () => fail(new Error('代理连接超时')));
    socket.once('error', (e) => fail(new Error('代理连接失败: ' + e.message)));

    socket.once('connect', () => {
      socket.write(
        `CONNECT ${u.hostname}:${port} HTTP/1.1\r\nHost: ${u.hostname}:${port}\r\nConnection: keep-alive\r\n\r\n`,
      );
      let buf = Buffer.alloc(0);
      const onData = (chunk) => {
        buf = Buffer.concat([buf, chunk]);
        const end = buf.indexOf('\r\n\r\n');
        if (end === -1) return;
        socket.removeListener('data', onData);

        const statusLine = buf.subarray(0, buf.indexOf('\r\n')).toString('latin1');
        if (!/^HTTP\/\d\.\d 200/.test(statusLine)) {
          return fail(new Error('代理拒绝 CONNECT: ' + statusLine));
        }
        const leftover = buf.subarray(end + 4);
        if (leftover.length) socket.unshift(leftover);

        const send = (sock) => {
          const agent = new http.Agent({ keepAlive: false, maxSockets: 1 });
          agent.createConnection = (_opts, cb) => cb(null, sock);
          const req = http.request(
            { host: u.hostname, port, path: reqPath, method, headers: baseHeaders, agent },
            collect,
          );
          req.on('error', fail);
          req.end();
        };

        if (isHttps) {
          const tlsSock = tls.connect({ socket, servername: u.hostname });
          tlsSock.once('secureConnect', () => send(tlsSock));
          tlsSock.once('error', (e) => fail(new Error('TLS 握手失败: ' + e.message)));
        } else {
          send(socket);
        }
      };
      socket.on('data', onData);
    });
  });
}

const clampPct = (n) => Math.max(0, Math.min(100, Number.isFinite(n) ? n : 0));
const round = (n, d = 2) => Math.round(n * 10 ** d) / 10 ** d;

// ---------------------------------------------------------------- Command Code

async function fetchCommandCode(cfg, proxy, log) {
  const out = { ok: false, error: null };
  try {
    const authPath = expand(cfg.commandCodeAuth);
    const auth = JSON.parse(fs.readFileSync(authPath, 'utf8'));
    if (!auth.apiKey) throw new Error('auth.json 里没有 apiKey，请先跑 command-code login');

    out.user = auth.userName ?? null;
    out.email = auth.email ?? null;

    const authHeader = { Authorization: `Bearer ${auth.apiKey}`, Accept: 'application/json' };

    // 两个接口一起打：credits 给额度，subscriptions 给套餐与账期结束时间
    const [r, sub] = await Promise.all([
      httpGet(`${cfg.commandCodeApi}/alpha/billing/credits`, {
        headers: authHeader,
        proxy,
        timeoutMs: cfg.timeoutMs,
      }),
      httpGet(`${cfg.commandCodeApi}/alpha/billing/subscriptions`, {
        headers: authHeader,
        proxy,
        timeoutMs: cfg.timeoutMs,
      }).catch(() => null),
    ]);
    if (r.status === 401 || r.status === 403) throw new Error('凭证失效（' + r.status + '），请重新登录');
    if (r.status !== 200) throw new Error('接口返回 HTTP ' + r.status);

    const j = JSON.parse(r.body);
    const c = j.credits ?? {};
    const w = j.windowLimits ?? {};

    let subscription = null;
    if (sub && sub.status === 200) {
      try {
        subscription = JSON.parse(sub.body)?.data ?? null;
      } catch {
        /* 套餐信息拿不到不影响主数据 */
      }
    }

    // 套餐总额度：优先 subscriptions，其次 credits 里带的 planId
    const planId = subscription?.planId ?? c.planId ?? null;
    const planName = planId ? (PLAN_LABELS[planId] ?? planId) : null;
    const totalCredits = planId ? (PLAN_TOTAL_CREDITS[planId] ?? null) : null;

    const remaining = Number(c.monthlyCredits ?? 0) + Number(c.purchasedCredits ?? 0) + Number(c.freeCredits ?? 0);
    out.planId = planId;
    out.plan = planName;
    out.remainingCredits = round(remaining);
    out.monthlyRemaining = round(Number(c.monthlyCredits ?? 0));
    out.purchasedCredits = round(Number(c.purchasedCredits ?? 0));
    out.freeCredits = round(Number(c.freeCredits ?? 0));
    out.totalCredits = totalCredits;
    out.usedCredits = totalCredits === null ? null : round(Math.max(0, totalCredits - remaining));
    out.usedPct = totalCredits ? clampPct(((totalCredits - remaining) / totalCredits) * 100) : null;
    // 挂件按“剩余”呈现，这里把剩余口径一次算好，UI 不再做减法
    out.remainingPct = totalCredits ? clampPct((remaining / totalCredits) * 100) : null;
    // 月度额度的账期重置时刻（每个账单周期的结束时间）
    out.periodStart = subscription?.currentPeriodStart ? Date.parse(subscription.currentPeriodStart) : null;
    out.periodEnd = subscription?.currentPeriodEnd ? Date.parse(subscription.currentPeriodEnd) : null;
    out.exceeded = w.exceeded ?? null;
    out.belowThreshold = c.belowThreshold ?? false;

    const win = (o) => {
      if (!o) return null;
      const used = Number(o.used ?? 0);
      const cap = Number(o.cap ?? 0);
      const left = Math.max(0, cap - used);
      return {
        used: round(used, 3),
        cap: round(cap, 2),
        pct: cap > 0 ? clampPct((used / cap) * 100) : 0,
        // 5 小时/每周窗口的 cap 单位是积分；remaining 是还剩多少积分
        remaining: round(left, 3),
        remainingPct: cap > 0 ? clampPct((left / cap) * 100) : 0,
        resetAt: o.resetAt ?? null,
        exceeded: !!o.exceeded,
      };
    };
    out.fiveHour = win(w.fiveHour);
    out.weekly = win(w.weekly);

    out.ok = true;
  } catch (e) {
    out.error = e.message ?? String(e);
  }
  return out;
}

// ---------------------------------------------------------------- ChatGPT / Codex

/** Cockpit Tools 的账号库：AES-256-GCM，密钥明文放在 secure-account-storage.key */
function loadCockpitAccounts(cfg, log) {
  const dir = expand(cfg.cockpitDir);
  const keyPath = path.join(dir, 'secure-account-storage.key');
  const listPath = path.join(dir, 'codex_accounts.json');
  if (!fs.existsSync(keyPath) || !fs.existsSync(listPath)) {
    throw new Error('没找到 Cockpit Tools 账号库，请确认已安装并登录过');
  }
  const key = Buffer.from(fs.readFileSync(keyPath, 'utf8').trim(), 'base64');
  const list = JSON.parse(fs.readFileSync(listPath, 'utf8'));

  const accounts = [];
  for (const meta of list.accounts ?? []) {
    const file = path.join(dir, 'codex_accounts', `${meta.id}.json`);
    const entry = {
      id: meta.id,
      email: meta.email ?? null,
      plan: meta.plan_type ?? null,
      expiresAt: meta.subscription_active_until ?? null,
      current: meta.id === list.current_account_id,
    };
    try {
      const blob = JSON.parse(fs.readFileSync(file, 'utf8'));
      const ct = Buffer.from(blob.ciphertext, 'base64');
      const iv = Buffer.from(blob.nonce, 'base64');
      const d = crypto.createDecipheriv('aes-256-gcm', key, iv);
      d.setAuthTag(ct.subarray(ct.length - 16));
      const plain = JSON.parse(Buffer.concat([d.update(ct.subarray(0, ct.length - 16)), d.final()]).toString('utf8'));

      entry.accessToken = plain.tokens?.access_token ?? null;
      entry.accountId = plain.account_id ?? null;
      entry.cachedQuota = plain.quota ?? null;
      entry.cachedAt = plain.usage_updated_at ? plain.usage_updated_at * 1000 : null;
      if (plain.email) entry.email = plain.email;
      if (plain.plan_type) entry.plan = plain.plan_type;
    } catch (e) {
      entry.loadError = '账号文件解密失败: ' + (e.message ?? e);
    }
    accounts.push(entry);
  }
  if (!accounts.length) throw new Error('账号库为空');
  log(`cockpit: 读到 ${accounts.length} 个账号`);
  return accounts;
}

const jwtExp = (token) => {
  try {
    const payload = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8'));
    return { exp: payload.exp * 1000, accountId: payload['https://api.openai.com/auth']?.chatgpt_account_id ?? null };
  } catch {
    return { exp: null, accountId: null };
  }
};

/** 把 ChatGPT 官方 usage 响应压成挂件要的几个数 */
function normalizeCodexUsage(j) {
  const rl = j.rate_limit ?? {};
  const pick = (w) => {
    if (!w) return null;
    const usedPct = clampPct(Number(w.used_percent ?? 0));
    return {
      pct: usedPct,
      remainingPct: clampPct(100 - usedPct),
      resetAt: (w.reset_at ?? null) && w.reset_at * 1000,
    };
  };
  return {
    plan: j.plan_type ?? null,
    email: j.email ?? null,
    userId: j.user_id ?? null,
    fiveHour: pick(rl.primary_window),
    weekly: pick(rl.secondary_window),
    limited: !!rl.limit_reached || rl.allowed === false,
    credits: j.credits?.has_credits ? Number(j.credits.balance ?? 0) : null,
    resetCredits: j.rate_limit_reset_credits?.available_count ?? null,
    additional: (j.additional_rate_limits ?? []).map((a) => ({
      name: a.limit_name,
      pct: clampPct(Number(a.rate_limit?.primary_window?.used_percent ?? 0)),
      resetAt: (a.rate_limit?.primary_window?.reset_at ?? null) * 1000 || null,
    })),
  };
}

/** Cockpit 上次抓到的额度（注意：它的 hourly/weekly_percentage 是“剩余百分比”） */
function quotaFromCache(q, cachedAt) {
  const raw = q.raw_data ?? {};
  const rl = raw.rate_limit ?? {};
  const pick = (win, fallbackPct) => {
    let usedPct = null;
    if (win && typeof win.used_percent === 'number') usedPct = clampPct(win.used_percent);
    else if (typeof fallbackPct === 'number') usedPct = clampPct(100 - fallbackPct);
    if (usedPct === null) return null;
    return {
      pct: usedPct,
      remainingPct: clampPct(100 - usedPct),
      resetAt: win?.reset_at ? win.reset_at * 1000 : null,
    };
  };
  return {
    plan: raw.plan_type ?? null,
    email: raw.email ?? null,
    fiveHour: pick(rl.primary_window, q.hourly_percentage),
    weekly: pick(rl.secondary_window, q.weekly_percentage),
    limited: !!rl.limit_reached,
    credits: raw.credits?.has_credits ? Number(raw.credits.balance ?? 0) : null,
    resetCredits: q.reset_credits_available ?? null,
    additional: [],
    cachedAt,
  };
}

async function fetchChatGpt(cfg, proxy, log) {
  const out = { ok: false, error: null, accounts: [] };
  let accounts;
  try {
    accounts = loadCockpitAccounts(cfg, log);
  } catch (e) {
    out.error = e.message ?? String(e);
    return out;
  }

  const now = Date.now();
  for (const acc of accounts) {
    const row = {
      id: acc.id,
      email: acc.email,
      plan: acc.plan,
      expiresAt: acc.expiresAt,
      current: acc.current,
      ok: false,
      error: null,
      source: null,
    };

    const cached = acc.cachedQuota ? quotaFromCache(acc.cachedQuota, acc.cachedAt) : null;

    if (acc.loadError) {
      row.error = acc.loadError;
    } else if (!acc.accessToken) {
      row.error = '账号里没有 access_token';
    } else {
      const { exp, accountId: jwtAccountId } = jwtExp(acc.accessToken);
      if (exp && exp < now + 60_000) {
        row.error = '登录凭证已过期（打开 Cockpit Tools 刷新一下即可）';
      } else {
        const headers = {
          Authorization: `Bearer ${acc.accessToken}`,
          'User-Agent': 'codex_cli_rs/0.1.0',
          originator: 'codex_cli_rs',
          Accept: 'application/json',
        };
        try {
          let r = await httpGet(cfg.codexUsageUrl, {
            headers: { ...headers, 'chatgpt-account-id': acc.accountId },
            proxy,
            timeoutMs: cfg.timeoutMs,
          });
          // 账号 id 可能已轮换，用 JWT 里的再试一次
          if ((r.status === 401 || r.status === 403) && jwtAccountId && jwtAccountId !== acc.accountId) {
            r = await httpGet(cfg.codexUsageUrl, {
              headers: { ...headers, 'chatgpt-account-id': jwtAccountId },
              proxy,
              timeoutMs: cfg.timeoutMs,
            });
          }
          if (r.status === 200) {
            Object.assign(row, normalizeCodexUsage(JSON.parse(r.body)), { ok: true, source: 'live' });
          } else if (r.status === 401 || r.status === 403) {
            row.error = '登录凭证被拒绝（' + r.status + '），打开 Cockpit Tools 刷新';
          } else {
            row.error = '接口返回 HTTP ' + r.status;
          }
        } catch (e) {
          row.error = '取数失败: ' + (e.message ?? e);
        }
      }
    }

    // 拿不到实时数据就退回 Cockpit 上次的缓存值，并标明数据时间
    if (!row.ok && cached) {
      Object.assign(row, cached, { source: 'cache', ok: true, error: row.error });
    }
    if (!row.ok && !row.error) row.error = '未知错误';
    out.accounts.push(row);
  }

  out.ok = out.accounts.some((a) => a.ok);
  if (!out.ok) out.error = out.accounts.find((a) => a.error)?.error ?? '全部账号取数失败';
  return out;
}

// ---------------------------------------------------------------- 入口

async function main() {
  const argv = process.argv.slice(2);
  const outIdx = argv.indexOf('--out');
  const outFile = outIdx >= 0 ? argv[outIdx + 1] : null;
  const pretty = argv.includes('--pretty');
  const verbose = argv.includes('--verbose');

  const log = verbose ? (m) => process.stderr.write(`[quota] ${m}\n`) : () => {};
  const cfg = readConfig();

  const result = { generatedAt: Date.now(), host: os.hostname(), proxy: null };

  try {
    result.proxy = await detectProxy(cfg, log);
  } catch (e) {
    log('proxy 探测异常: ' + e.message);
  }

  const [commandCode, chatgpt] = await Promise.all([
    fetchCommandCode(cfg, result.proxy, log).catch((e) => ({ ok: false, error: e.message ?? String(e) })),
    fetchChatGpt(cfg, result.proxy, log).catch((e) => ({ ok: false, error: e.message ?? String(e), accounts: [] })),
  ]);

  result.commandCode = commandCode;
  result.chatgpt = chatgpt;

  const text = JSON.stringify(result, null, pretty ? 2 : 0);
  if (outFile) {
    const target = expand(outFile);
    const tmp = target + '.tmp';
    fs.writeFileSync(tmp, text, 'utf8');
    fs.renameSync(tmp, target); // 原子替换，挂件不会读到写了一半的文件
  }
  if (!outFile || verbose) process.stdout.write(text + '\n');
}

main().catch((e) => {
  process.stderr.write('[quota] 致命错误: ' + (e.stack ?? e.message) + '\n');
  process.exitCode = 1;
});
