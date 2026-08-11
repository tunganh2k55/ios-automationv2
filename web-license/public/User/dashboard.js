"use strict";
(() => {
  // src/shared/api.ts
  var Auth = {
    get token() {
      return localStorage.getItem("ia_token") || "";
    },
    set token(t) {
      t ? localStorage.setItem("ia_token", t) : localStorage.removeItem("ia_token");
    },
    get user() {
      try {
        return JSON.parse(localStorage.getItem("ia_user") || "null");
      } catch {
        return null;
      }
    },
    set user(u) {
      u ? localStorage.setItem("ia_user", JSON.stringify(u)) : localStorage.removeItem("ia_user");
    },
    logout() {
      try {
        fetch("/api/auth/logout", { method: "POST" });
      } catch {
      }
      this.token = "";
      this.user = null;
    }
  };
  async function api(pathname, opts = {}) {
    const headers = { "Content-Type": "application/json" };
    if (Auth.token) headers.Authorization = "Bearer " + Auth.token;
    const res = await fetch(pathname, {
      method: opts.method || "GET",
      headers,
      body: opts.body ? JSON.stringify(opts.body) : void 0
    });
    let data = {};
    try {
      data = await res.json();
    } catch {
    }
    if (res.status === 401 && Auth.token) Auth.logout();
    if (!res.ok || data.ok === false) throw new Error(data.msg || `L\u1ED7i ${res.status}`);
    return data;
  }
  function toast(msg, type = "ok", ms = 3200) {
    let box = document.getElementById("toastBox");
    if (!box) {
      box = document.createElement("div");
      box.id = "toastBox";
      box.className = "toast-box";
      document.body.appendChild(box);
    }
    const el = document.createElement("div");
    el.className = `toast ${type}`;
    el.textContent = msg;
    box.appendChild(el);
    requestAnimationFrame(() => el.classList.add("show"));
    const kill = () => {
      el.classList.remove("show");
      setTimeout(() => el.remove(), 260);
    };
    el.onclick = kill;
    setTimeout(kill, ms);
  }
  var $ = (s, r = document) => r.querySelector(s);
  var $$ = (s, r = document) => Array.from(r.querySelectorAll(s));
  var fmtVND = (n) => n ? Number(n).toLocaleString("vi-VN") + "\u20AB" : "Mi\u1EC5n ph\xED";
  var fmtDate = (iso) => iso ? new Date(iso).toLocaleDateString("vi-VN", { timeZone: "Asia/Ho_Chi_Minh" }) : "V\u0129nh vi\u1EC5n";
  var esc = (s) => String(s == null ? "" : s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  async function ensureAuth(opts = {}) {
    if (!Auth.token) {
      location.replace("/login");
      return null;
    }
    try {
      const r = await api("/api/auth/me");
      Auth.user = r.user;
      if (opts.admin && r.user.role !== "admin") {
        location.replace("/dashboard");
        return null;
      }
      return r.user;
    } catch {
      Auth.logout();
      location.replace("/login");
      return null;
    }
  }

  // src/User/dashboard.ts
  var TOOLS = [];
  var selTool = null;
  var selPlan = null;
  var poll = 0;
  var cd = 0;
  var ttlMs = 15 * 60 * 1e3;
  var payActivated = false;
  function countSerials() {
    const val = $("#mid").value;
    const lines = val.split(/\r?\n/).map((l) => l.trim()).filter((l) => l.length > 0);
    return Math.max(1, lines.length);
  }
  function updatePriceCalc() {
    const calcEl = $("#priceCalc");
    if (!selTool || !selPlan) {
      calcEl.textContent = "";
      return;
    }
    const plan = selTool.plans.find((p) => p.id === selPlan);
    if (!plan) {
      calcEl.textContent = "";
      return;
    }
    const qty = countSerials();
    const total = plan.price * qty;
    const midVal = $("#mid").value.trim();
    if (midVal.length === 0) {
      calcEl.innerHTML = `<b>T\u1ED5ng: ${fmtVND(plan.price)}</b> (1 m\xE1y)`;
    } else if (qty === 1) {
      calcEl.innerHTML = `<b>T\u1ED5ng: ${fmtVND(plan.price)}</b> (1 m\xE1y)`;
    } else {
      calcEl.innerHTML = `<b>T\u1ED5ng: ${fmtVND(total)}</b> (${qty} m\xE1y \xD7 ${fmtVND(plan.price)})`;
    }
  }
  (async function() {
    const user = await ensureAuth();
    if (!user) return;
    $("#who").innerHTML = `Xin ch\xE0o, <b>${esc(user.name || user.email)}</b>`;
    $("#logout").onclick = () => {
      Auth.logout();
      location.replace("/");
    };
    $("#pdClose").onclick = closeDrawer;
    $("#drawerBack").onclick = closeDrawer;
    $("#payBtn").onclick = pay;
    $("#mid").oninput = updatePriceCalc;
    loadTools();
  })();
  async function loadTools() {
    const box = $("#tools");
    try {
      const r = await api("/api/tools");
      TOOLS = r.tools || [];
      if (!TOOLS.length) {
        box.innerHTML = '<div class="sub">Ch\u01B0a c\xF3 tool n\xE0o \u0111\u01B0\u1EE3c b\xE1n.</div>';
        return;
      }
      box.innerHTML = "";
      TOOLS.forEach((t) => {
        const c = document.createElement("button");
        c.className = "tool-pick";
        c.type = "button";
        c.dataset.id = t.id;
        const from = t.plans.length ? Math.min(...t.plans.map((p) => p.price | 0)) : 0;
        c.innerHTML = `
        <div class="tp-top"><span class="tp-name">${esc(t.name)}</span><span class="pill">${esc(t.slug)}</span></div>
        <div class="tp-desc">${esc(t.description)}</div>
        <div class="tp-from">${t.plans.length ? "T\u1EEB " + fmtVND(from) : "\u2014"}</div>
        <span class="tp-check">\u2713</span>`;
        c.onclick = () => selectTool(t.id);
        box.appendChild(c);
      });
    } catch (e) {
      const m = $("#storeMsg");
      m.className = "msg bad";
      m.textContent = e.message;
    }
  }
  function selectTool(id) {
    selTool = TOOLS.find((t) => t.id === id) || null;
    selPlan = null;
    $$(".tool-pick").forEach((el) => el.classList.toggle("sel", el.dataset.id === id));
    if (!selTool) return;
    $("#planStep").classList.remove("is-locked");
    $("#planFor").innerHTML = `License \u0111ang ch\u1ECDn: <b>${esc(selTool.name)}</b>`;
    $("#buyErr").textContent = "";
    const plansBox = $("#plans");
    plansBox.innerHTML = "";
    selTool.plans.forEach((p) => {
      const pe = document.createElement("button");
      pe.className = "plan";
      pe.type = "button";
      pe.dataset.id = p.id;
      pe.innerHTML = `<div class="pname">${esc(p.label)}</div>
      <div class="price">${fmtVND(p.price)}</div>
      <div class="dur">${p.days ? p.days + " ng\xE0y" : "V\u0129nh vi\u1EC5n"}</div>`;
      pe.onclick = () => {
        selPlan = p.id;
        $$(".plan", plansBox).forEach((x) => x.classList.remove("sel"));
        pe.classList.add("sel");
        $("#payBtn").disabled = false;
        updatePriceCalc();
      };
      plansBox.appendChild(pe);
    });
    $("#payBtn").disabled = true;
    $("#planStep").scrollIntoView({ behavior: "smooth", block: "nearest" });
  }
  async function pay() {
    if (!selTool || !selPlan) return;
    const btn = $("#payBtn");
    $("#buyErr").textContent = "";
    btn.disabled = true;
    const midVal = $("#mid").value.trim();
    const noteVal = $("#note").value.trim();
    payActivated = midVal.length > 0;
    try {
      const r = await api("/api/orders", {
        method: "POST",
        body: { toolId: selTool.id, plan: selPlan, machineId: midVal, note: noteVal }
      });
      if (r.status === "paid") {
        showPaidDrawer(r.code, r.key, r.expiresAt, r.keys);
        return;
      }
      showPendingDrawer(r);
    } catch (e) {
      $("#buyErr").textContent = e.message;
    } finally {
      btn.disabled = false;
    }
  }
  function openDrawer() {
    $("#drawerBack").removeAttribute("hidden");
    $("#payDrawer").removeAttribute("hidden");
    requestAnimationFrame(() => $("#payDrawer").classList.add("open"));
  }
  function closeDrawer() {
    stopTimers();
    $("#payDrawer").classList.remove("open");
    setTimeout(() => {
      $("#payDrawer").setAttribute("hidden", "");
      $("#drawerBack").setAttribute("hidden", "");
    }, 260);
  }
  function stopTimers() {
    clearInterval(poll);
    clearInterval(cd);
  }
  function payRows(r) {
    var _a, _b, _c;
    const row = (k, v, mono = false) => `<div class="kv"><span class="k">${k}</span><span class="v${mono ? " mono" : ""}">${esc(v)}</span></div>`;
    const qty = r.quantity || 1;
    const qtyNote = qty > 1 ? ` (${qty} m\xE1y)` : "";
    return row("Ng\xE2n h\xE0ng", ((_a = r.bank) == null ? void 0 : _a.bankId) || "") + row("S\u1ED1 t\xE0i kho\u1EA3n", ((_b = r.bank) == null ? void 0 : _b.account) || "", true) + (((_c = r.bank) == null ? void 0 : _c.accountName) ? row("Ch\u1EE7 TK", r.bank.accountName) : "") + row("S\u1ED1 ti\u1EC1n", fmtVND(r.amount) + qtyNote, true) + row("N\u1ED9i dung CK", r.transferContent, true);
  }
  function showPendingDrawer(r) {
    stopTimers();
    $("#pdResult").setAttribute("hidden", "");
    $("#pdPending").removeAttribute("hidden");
    $("#pdCode").textContent = r.code;
    $("#pdQr").src = r.qrUrl;
    $("#pdKv").innerHTML = payRows(r);
    $("#pdStatus").innerHTML = "\u23F3 \u0110ang ch\u1EDD thanh to\xE1n\u2026";
    openDrawer();
    startCountdown(r.expiresAt);
    startPoll(r.code);
  }
  function startCountdown(expiresAt) {
    const timer = $("#pdTimer"), bar = $("#pdBar");
    const deadline = expiresAt ? Date.parse(expiresAt) : 0;
    const total = ttlMs;
    const tick = () => {
      const ms = deadline - Date.now();
      if (!deadline || ms <= 0) {
        clearInterval(cd);
        onExpired();
        return;
      }
      const s = Math.floor(ms / 1e3);
      timer.textContent = String(Math.floor(s / 60)).padStart(2, "0") + ":" + String(s % 60).padStart(2, "0");
      bar.style.width = Math.max(0, Math.min(100, ms / total * 100)) + "%";
      timer.classList.toggle("urgent", ms <= 6e4);
    };
    tick();
    cd = setInterval(tick, 1e3);
  }
  function startPoll(code) {
    const tick = async () => {
      try {
        const s = await api("/api/orders/" + encodeURIComponent(code));
        if (s.status === "paid" && s.key) {
          stopTimers();
          showPaidDrawer(code, s.key, s.expiresAt, s.keys);
        } else if (s.status === "expired" || s.status === "canceled") {
          stopTimers();
          onExpired();
        }
      } catch {
      }
    };
    poll = setInterval(tick, 4e3);
  }
  function onExpired() {
    stopTimers();
    $("#pdTimer").textContent = "00:00";
    $("#pdStatus").innerHTML = '<span style="color:var(--bad)">\u0110\u01A1n \u0111\xE3 h\u1EBFt h\u1EA1n (qu\xE1 15 ph\xFAt). H\xE3y t\u1EA1o \u0111\u01A1n m\u1EDBi.</span>';
  }
  function showPaidDrawer(code, key, expiresAt, keys) {
    stopTimers();
    $("#pdCode").textContent = code;
    $("#pdPending").setAttribute("hidden", "");
    const res = $("#pdResult");
    res.removeAttribute("hidden");
    const allKeys = keys && keys.length > 0 ? keys : [key];
    const keysHtml = allKeys.map((k) => `<div class="keybox">${esc(k)}</div>`).join("");
    const keyLabel = allKeys.length > 1 ? `${allKeys.length} License keys c\u1EE7a b\u1EA1n` : "License key c\u1EE7a b\u1EA1n";
    res.innerHTML = `
    <div class="pay-ok">\u2713 Thanh to\xE1n th\xE0nh c\xF4ng</div>
    <div class="pay-ok-l">${keyLabel}</div>
    ${keysHtml}
    <div class="msg exp">H\u1EA1n: ${expiresAt ? fmtDate(expiresAt) : payActivated ? "V\u0129nh vi\u1EC5n" : "T\xEDnh t\u1EEB khi b\u1EA1n k\xEDch ho\u1EA1t key"}</div>
    <button class="mini" id="pdCopy">Sao ch\xE9p ${allKeys.length > 1 ? "t\u1EA5t c\u1EA3 keys" : "key"}</button>
    <a class="linkbtn" href="/license" style="display:inline-block;margin-top:12px">T\u1EDBi License c\u1EE7a t\xF4i \u2192</a>`;
    $("#pdCopy").onclick = async () => {
      try {
        await navigator.clipboard.writeText(allKeys.join("\n"));
        toast("\u0110\xE3 sao ch\xE9p " + allKeys.length + " key(s)", "ok");
      } catch {
        toast("Kh\xF4ng sao ch\xE9p \u0111\u01B0\u1EE3c", "bad");
      }
    };
    openDrawer();
    toast(`\u0110\xE3 c\u1EA5p ${allKeys.length} license th\xE0nh c\xF4ng`, "ok");
  }
})();
