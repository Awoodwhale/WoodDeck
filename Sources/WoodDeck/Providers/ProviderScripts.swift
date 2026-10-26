import Foundation

// 自定义来源的脚本模板，界面上预填这段内容
enum ProviderScripts {
    static var example: String {
        Loc.isChinese ? exampleChinese : exampleEnglish
    }

    static let exampleChinese = """
    // 定义 fetchUsage(ctx)，返回数组（必填，至少一项）。每项是一条配额，每页两条，点击翻页。
    async function fetchUsage(ctx) {
      // ctx.site：站点地址，字符串，未填写时为空。
      // ctx.secrets.key：API 密钥，字符串，未填写时为空。
      // ctx.language：界面语言，"zh-CN" 或 "en-US"。
      // 读取接口：const res = await ctx.http.get(地址, { headers: { ... } }); res.json() 取内容。
      return [
        {
          title: "5 小时",
          percent: 35,
          value: "$12.50",
          suffix: "已用",
          note: "无上限",
          resetAt: "2 时 13 分后"
        }
      ];
    }
    """

    static let exampleEnglish = """
    // Define fetchUsage(ctx) and return an array (required, at least one item). Each item is one quota; a page shows two, and a click turns the page.
    async function fetchUsage(ctx) {
      // ctx.site: the site address, a string; empty when not filled in.
      // ctx.secrets.key: the API key, a string; empty when not filled in.
      // ctx.language: the interface language, "zh-CN" or "en-US".
      // Reading an API: const res = await ctx.http.get(url, { headers: { ... } }); res.json() returns the content.
      return [
        {
          title: "5-hour",
          percent: 35,
          value: "$12.50",
          suffix: "used",
          note: "No limit",
          resetAt: "in 2h 13m"
        }
      ];
    }
    """

    // 内建来源的换算脚本，与上游逐字一致
    static func builtIn(_ id: ProviderID) -> String? {
        switch id {
        case .glmChina: glmChina
        case .glmGlobal: glmGlobal
        case .deepSeek: deepSeek
        case .newAPI: newAPI
        case .sub2API: sub2API
        default: nil
        }
    }

    static let glmChina = """
    async function fetchUsage(ctx) {
      const t = (zh, en) => ctx.language === "en-US" ? en : zh;
      const res = await ctx.http.get("https://open.bigmodel.cn/api/monitor/usage/quota/limit", {
        headers: { Authorization: ctx.secrets.key }
      });
      if (res.status !== 200) throw new Error("HTTP " + res.status);
      const body = res.json();
      if (body.success === false || (body.code != null && ![0, 200, "0", "200"].includes(body.code)))
        throw new Error(body.msg || t("套餐查询失败，请检查凭据或套餐权限。", "The plan query failed. Check the credentials or the plan's permissions."));
      const data = body.data || {};
      if (!Array.isArray(data.limits)) throw new Error(t("data.limits 缺失。", "data.limits is missing."));
      if (data.limits.length === 0) throw new Error(t("接口没有返回套餐额度，团队套餐暂不支持。", "The API returned no plan quota. Team plans are not supported yet."));
      const level = typeof data.level === "string" ? data.level.trim() : "";
      const now = Date.parse(ctx.now);
      const metrics = [];
      data.limits.forEach((limit, i) => {
        const type = String(limit.type || "").toUpperCase();
        const reset = typeof limit.nextResetTime === "number" && limit.nextResetTime > 0 ? limit.nextResetTime : null;
        if (type === "TIME_LIMIT") {
          if (typeof limit.usage === "number" && limit.usage > 0)
            metrics.push({ id: "tools", kind: "count", label: "工具调用", used: limit.currentValue || 0, total: limit.usage, unit: "次", resetAt: reset });
          return;
        }
        if (type !== "TOKENS_LIMIT" && type !== "CREDIT_LIMIT") return;
        let label = "套餐额度", window = null;
        if (limit.unit === 3 && limit.number > 0) { label = limit.number + " 小时"; window = limit.number * 60; }
        else if (limit.unit === 6) { label = "每周"; window = 10080; }
        // Credit plans report exact credits; older plans report only a rounded percentage.
        const credits = type === "CREDIT_LIMIT" && limit.usage > 0 && typeof limit.currentValue === "number";
        if (!credits && typeof limit.percentage !== "number") return;
        // A reset beyond the window length is not a real reset time.
        const resetAt = reset && window && reset > now + window * 60000 ? null : reset;
        const metric = { id: [type, limit.unit, limit.number, i].join(":"), label, window, resetAt };
        metrics.push(credits ? { ...metric, kind: "count", used: limit.currentValue, total: limit.usage, unit: "积分" }
          : { ...metric, kind: "percent", percent: Math.max(0, Math.min(100, limit.percentage)) });
      });
      if (metrics.length === 0) throw new Error(t("没有可识别的套餐额度。", "No recognizable plan quota was returned."));
      return { plan: level && level[0].toUpperCase() + level.slice(1), scope: "plan", metrics };
    }
    """

    static let glmGlobal = """
    async function fetchUsage(ctx) {
      const t = (zh, en) => ctx.language === "en-US" ? en : zh;
      const res = await ctx.http.get("https://api.z.ai/api/monitor/usage/quota/limit", {
        headers: { Authorization: ctx.secrets.key }
      });
      if (res.status !== 200) throw new Error("HTTP " + res.status);
      const body = res.json();
      if (body.success === false || (body.code != null && ![0, 200, "0", "200"].includes(body.code)))
        throw new Error(body.msg || t("套餐查询失败，请检查凭据或套餐权限。", "The plan query failed. Check the credentials or the plan's permissions."));
      const data = body.data || {};
      if (!Array.isArray(data.limits)) throw new Error(t("data.limits 缺失。", "data.limits is missing."));
      if (data.limits.length === 0) throw new Error(t("接口没有返回套餐额度，团队套餐暂不支持。", "The API returned no plan quota. Team plans are not supported yet."));
      const level = typeof data.level === "string" ? data.level.trim() : "";
      const now = Date.parse(ctx.now);
      const metrics = [];
      data.limits.forEach((limit, i) => {
        const type = String(limit.type || "").toUpperCase();
        const reset = typeof limit.nextResetTime === "number" && limit.nextResetTime > 0 ? limit.nextResetTime : null;
        if (type === "TIME_LIMIT") {
          if (typeof limit.usage === "number" && limit.usage > 0)
            metrics.push({ id: "tools", kind: "count", label: "工具调用", used: limit.currentValue || 0, total: limit.usage, unit: "次", resetAt: reset });
          return;
        }
        if (type !== "TOKENS_LIMIT" && type !== "CREDIT_LIMIT") return;
        let label = "套餐额度", window = null;
        if (limit.unit === 3 && limit.number > 0) { label = limit.number + " 小时"; window = limit.number * 60; }
        else if (limit.unit === 6) { label = "每周"; window = 10080; }
        // Credit plans report exact credits; older plans report only a rounded percentage.
        const credits = type === "CREDIT_LIMIT" && limit.usage > 0 && typeof limit.currentValue === "number";
        if (!credits && typeof limit.percentage !== "number") return;
        // A reset beyond the window length is not a real reset time.
        const resetAt = reset && window && reset > now + window * 60000 ? null : reset;
        const metric = { id: [type, limit.unit, limit.number, i].join(":"), label, window, resetAt };
        metrics.push(credits ? { ...metric, kind: "count", used: limit.currentValue, total: limit.usage, unit: "积分" }
          : { ...metric, kind: "percent", percent: Math.max(0, Math.min(100, limit.percentage)) });
      });
      if (metrics.length === 0) throw new Error(t("没有可识别的套餐额度。", "No recognizable plan quota was returned."));
      return { plan: level && level[0].toUpperCase() + level.slice(1), scope: "plan", metrics };
    }
    """

    // 账户余额接口按币种返回 total_balance = granted_balance + topped_up_balance，均为十进制字符串
    static let deepSeek = """
    async function fetchUsage(ctx) {
      const t = (zh, en) => ctx.language === "en-US" ? en : zh;
      const res = await ctx.http.get("https://api.deepseek.com/user/balance", {
        headers: { Authorization: "Bearer " + ctx.secrets.key, Accept: "application/json" }
      });
      if (res.status === 401) throw new Error(t("DeepSeek 拒绝了这个 API 密钥，请检查密钥是否正确或已被删除。", "DeepSeek rejected this API key. Check that it is correct and has not been deleted."));
      if (res.status !== 200) throw new Error("HTTP " + res.status);
      const body = res.json();
      if (!body || !Array.isArray(body.balance_infos)) throw new Error(t("balance_infos 缺失。", "balance_infos is missing."));
      const amount = (info, field) => {
        const value = Number(info[field]);
        if (typeof info[field] !== "string" || !Number.isFinite(value)) throw new Error(field + t(" 缺失或不是数字。", " is missing or not a number."));
        return value;
      };
      const metrics = [];
      for (const info of body.balance_infos) {
        const currency = info.currency;
        if (currency !== "CNY" && currency !== "USD") continue;
        metrics.push({ id: "total:" + currency, kind: "balance", label: "账户余额", amount: amount(info, "total_balance"), currency });
        metrics.push({ id: "granted:" + currency, kind: "balance", label: "赠送余额", amount: amount(info, "granted_balance"), currency });
      }
      if (metrics.length === 0) throw new Error(t("接口没有返回人民币或美元余额。", "The API returned no balance in CNY or USD."));
      const warnings = body.is_available === false ? [t("余额不足，DeepSeek API 暂时无法调用。", "The balance is insufficient, so the DeepSeek API cannot be called for now.")] : [];
      return { scope: "account", metrics, warnings };
    }
    """

    static let newAPI = #"""
    async function fetchUsage(ctx) {
      const t = (zh, en) => ctx.language === "en-US" ? en : zh;
      const auth = { headers: { Authorization: "Bearer " + ctx.secrets.key } };
      function json(res) { try { return res.json(); } catch (e) { return null; } }
      async function tryGet(url, options) { try { return await ctx.http.get(url, options); } catch (e) { return null; } }
      function blocked(res) { return res.status === 403 && /^\s*</.test(res.text()); }
      // Older deployments register the path without the trailing slash.
      let usage = await tryGet(ctx.site + "/api/usage/token/", auth);
      if (!usage || usage.status === 404 || usage.status === 301) usage = await ctx.http.get(ctx.site + "/api/usage/token", auth);
      const body = json(usage);
      if (usage.status === 401) throw new Error(t("密钥无效或已被禁用。", "The key is invalid or disabled."));
      if (blocked(usage)) throw new Error(t("站点拦截了程序请求。", "The site blocked the request from this program."));
      if (!body || !(body.code === true || body.success === true) || !body.data) {
        const other = json(await tryGet(ctx.site + "/v1/usage", auth) || { json: () => null });
        if (other && (typeof other.mode === "string" || typeof other.isValid === "boolean")) throw new Error(t("这个站点是 Sub2API。请把配额来源改为 Sub2API。", "This site runs Sub2API. Change the quota source to Sub2API."));
        if (body && typeof body.message === "string" && body.message) throw new Error(body.message);
        throw new Error(usage.status === 200 ? t("站点返回的内容无法识别。", "The site's response is not recognized.") : "HTTP " + usage.status);
      }
      const data = body.data;
      if (typeof data.unlimited_quota !== "boolean" || typeof data.total_used !== "number") throw new Error(t("密钥额度字段缺失。", "The key's quota fields are missing."));

      // Today is counted from local midnight, which is also what the station's web console uses.
      const day = ctx.now.slice(0, 10), midnight = Date.parse(day + "T00:00:00" + ctx.now.slice(-6)) / 1000;
      const memory = ctx.memory && ctx.memory.day === day && typeof ctx.memory.base === "number" && data.total_used >= ctx.memory.base ? ctx.memory : null;
      const [status, subscription, billing, logs] = await Promise.all([
        tryGet(ctx.site + "/api/status"),
        tryGet(ctx.site + "/v1/dashboard/billing/subscription", auth),
        tryGet(ctx.site + "/v1/dashboard/billing/usage", auth),
        memory ? null : tryGet(ctx.site + "/api/log/token", { ...auth, pick: { path: "data", fields: ["type", "quota", "created_at"] } })
      ]);

      const warnings = [];
      let config = status && status.status === 200 ? json(status) : null;
      config = config && config.success === true && config.data ? config.data : null;
      let display = config && config.quota_display_type;
      if (config && display == null && typeof config.display_in_currency === "boolean") display = config.display_in_currency ? "USD" : "TOKENS";
      let perUnit = config && config.quota_per_unit;
      if (!["USD", "CNY", "TOKENS", "CUSTOM"].includes(display) || (display !== "TOKENS" && !(typeof perUnit === "number" && perUnit > 0))) {
        display = "USD"; perUnit = 500000; warnings.push(t("站点单位未确认，按美元显示。", "The site's unit is not confirmed; amounts are shown in US dollars."));
      }
      let exchange = 1, currency = display === "TOKENS" ? "" : display;
      if (display === "CNY") exchange = typeof config.usd_exchange_rate === "number" && config.usd_exchange_rate > 0 ? config.usd_exchange_rate : 1;
      if (display === "CUSTOM") {
        exchange = typeof config.custom_currency_exchange_rate === "number" && config.custom_currency_exchange_rate > 0 ? config.custom_currency_exchange_rate : 1;
        currency = config.custom_currency_symbol || "¤";
      }
      const money = raw => display === "TOKENS" ? raw : raw / perUnit * exchange;
      function amount(field) {
        if (typeof data[field] !== "number" || !Number.isFinite(data[field])) throw new Error(field + t(" 缺失或不是数字。", " is missing or not a number."));
        return money(data[field]);
      }
      const expiresAt = data.expires_at > 0 ? data.expires_at * 1000 : null;
      const metrics = [];

      // The billing endpoint reports the whole account only when the station turns off per-key statistics.
      // Its totals are lifetime income, so only the balance is kept. A CNY station with its own exchange rate
      // may or may not have converted these figures (forks differ), so the balance is left out there.
      const sub = subscription && subscription.status === 200 ? json(subscription) : null;
      const used = billing && billing.status === 200 ? json(billing) : null;
      if (sub && used && typeof sub.hard_limit_usd === "number" && typeof used.total_usage === "number" && !(display === "CNY" && exchange !== 1)) {
        const toBilling = raw => display === "TOKENS" ? raw : display === "CNY" ? raw / perUnit * exchange : raw / perUnit;
        const account = data.unlimited_quota ? Math.abs(sub.hard_limit_usd - 100000000) > 0.5
          : typeof data.total_granted === "number" && Math.abs(sub.hard_limit_usd - toBilling(data.total_granted)) > 0.01;
        if (account) metrics.push({ id: "account", kind: "balance", label: "账户余额",
          amount: (sub.hard_limit_usd - used.total_usage / 100) * (display === "CUSTOM" ? exchange : 1), currency });
      }
      if (!data.unlimited_quota)
        metrics.push({ id: "key", kind: "balance", label: "密钥余额", amount: amount("total_available"), total: amount("total_granted"), currency, expiresAt });

      let remember = null, today = null;
      if (memory) { today = { raw: data.total_used - memory.base, atLeast: memory.atLeast }; remember = memory; }
      else {
        const rows = logs && logs.status === 200 ? json(logs) : null;
        // An empty log cannot tell "unused today" from "logging disabled", so nothing is shown.
        if (Array.isArray(rows) && rows.length > 0) {
          let sum = 0, oldest = Infinity;
          for (const row of rows) {
            if (typeof row.created_at === "number") oldest = Math.min(oldest, row.created_at);
            if (typeof row.quota !== "number" || !(row.created_at >= midnight)) continue;
            if (row.type === 2) sum += row.quota; else if (row.type === 6) sum -= row.quota;
          }
          // A full page that starts after midnight may have lost earlier records of today.
          const atLeast = rows.length >= 100 && oldest >= midnight;
          today = { raw: sum, atLeast };
          remember = { day, base: data.total_used - sum, atLeast };
        }
      }
      if (today) metrics.push({ id: "today", kind: "spend", label: "今日扣费", amount: Math.max(0, money(today.raw)), atLeast: today.atLeast, currency });
      if (data.unlimited_quota)
        metrics.push({ id: "total", kind: "spend", label: "密钥累计", amount: amount("total_used"), unlimited: true, currency, expiresAt });
      return { scope: metrics.some(m => m.id === "account") ? "account" : "key", metrics, warnings, memory: remember };
    }
    """#

    static let sub2API = #"""
    async function fetchUsage(ctx) {
      const auth = { headers: { Authorization: "Bearer " + ctx.secrets.key } };
      function json(res) { try { return res.json(); } catch (e) { return null; } }
      async function tryGet(url, options) { try { return await ctx.http.get(url, options); } catch (e) { return null; } }
      const t = (zh, en) => ctx.language === "en-US" ? en : zh;
      const [res, rate] = await Promise.all([ctx.http.get(ctx.site + "/v1/usage", auth), tryGet(ctx.site + "/v1/sub2api/billing", auth)]);
      const data = json(res);
      if (res.status === 401) throw new Error(t("密钥无效或已被禁用。", "The key is invalid or disabled."));
      if (res.status === 403 && /^\s*</.test(res.text())) throw new Error(t("站点拦截了程序请求。", "The site blocked the request from this program."));
      if (!data || (typeof data.mode !== "string" && typeof data.isValid !== "boolean")) {
        const other = await tryGet(ctx.site + "/api/usage/token/", auth);
        const token = other && json(other);
        if (token && token.data && token.data.object === "token_usage") throw new Error(t("这个站点是 New API。请把配额来源改为 New API。", "This site runs New API. Change the quota source to New API."));
        throw new Error(res.status === 200 ? t("站点返回的内容无法识别。", "The site's response is not recognized.") : "HTTP " + res.status);
      }
      if (data.isValid !== true) throw new Error(t("密钥无效或已被禁用。", "The key is invalid or disabled."));
      function number(value, field) {
        if (typeof value !== "number" || !Number.isFinite(value)) throw new Error(field + t(" 缺失或不是数字。", " is missing or not a number."));
        return value;
      }
      function windowMetric(id, label, minutes, used, limit, resetAt) {
        number(used, id + ".used"); number(limit, id + ".limit");
        if (limit <= 0) throw new Error(id + t(".limit 必须大于 0。", ".limit must be greater than 0."));
        return { id, kind: "percent", label, window: minutes, percent: used / limit * 100, resetAt: resetAt || null };
      }
      // The expiry goes on the last window, where the panel shows it beside or above that window's reset time.
      function expire(metrics, at) { if (at && metrics.length > 0) metrics[metrics.length - 1].expiresAt = at; }
      const billing = rate && rate.status === 200 ? json(rate) : null;
      const multiplier = billing && typeof billing.effective_rate_multiplier === "number" ? Number(billing.effective_rate_multiplier.toFixed(2)) + "×" : "";
      const metrics = [];
      if (data.mode === "quota_limited") {
        const periods = { "5h": ["5 小时", 300], "1d": ["每日", 1440], "7d": ["每周", 10080] };
        const windows = (data.rate_limits || []).filter(r => periods[r.window]).sort((a, b) => periods[a.window][1] - periods[b.window][1]);
        for (const r of windows) metrics.push(windowMetric("rate:" + r.window, periods[r.window][0], periods[r.window][1], r.used, r.limit, r.reset_at));
        if (data.quota) metrics.push({ id: "quota", kind: "balance", label: "密钥余额", amount: number(data.quota.remaining, "quota.remaining"),
          total: number(data.quota.limit, "quota.limit"), currency: data.quota.unit || "USD" });
        expire(metrics, data.expires_at);
        return { plan: multiplier, scope: "key", metrics };
      }
      if (data.mode !== "unrestricted") throw new Error(t("无法识别站点返回的 mode。", "The mode the site returned is not recognized."));
      if (data.subscription) {
        const s = data.subscription;
        for (const [key, label, minutes] of [["daily", "每日", 1440], ["weekly", "每周", 10080], ["monthly", "每月", 43200]]) {
          const limit = s[key + "_limit_usd"];
          if (limit == null || limit === 0) continue;
          // Only the weekly window origin is published, so the other windows show no reset time.
          const start = key === "weekly" && s.weekly_window_start ? new Date(s.weekly_window_start).getTime() : NaN;
          const reset = start + 7 * 86400000 > Date.parse(ctx.now) ? new Date(start + 7 * 86400000).toISOString() : null;
          metrics.push(windowMetric(key, label, minutes, s[key + "_usage_usd"], limit, reset));
        }
        expire(metrics, s.expires_at);
        return { plan: data.planName || "", scope: "plan", metrics };
      }
      metrics.push({ id: "wallet", kind: "balance", label: "账户余额", amount: number(data.balance, "balance"), currency: data.unit || "USD" });
      const today = data.usage && data.usage.today;
      if (today && typeof today.actual_cost === "number") metrics.push({ id: "today", kind: "spend", label: "今日扣费", amount: today.actual_cost, currency: data.unit || "USD" });
      return { plan: multiplier, scope: "account", metrics };
    }
    """#
}
