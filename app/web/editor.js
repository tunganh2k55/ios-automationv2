"use strict";
// ============================================================================
//  Monaco editor cho khung soạn script + GỢI Ý (autocomplete) hàm iOSAuto/Lua.
//  - Nạp Monaco từ CDN (jsdelivr). Web thường được edit từ máy tính trong LAN (có internet).
//  - Offline / CDN lỗi → TỰ fallback về <textarea> cũ (không mất tính năng cơ bản).
//  - Shim `scriptBox.value` → Monaco nên app.js KHÔNG phải sửa gì.
//  - Gợi ý lấy từ window.IOSAUTO_FUNCS (docs.js) → luôn khớp danh sách hàm thật.
// ============================================================================
(function () {
  const ta = document.getElementById("scriptBox");
  if (!ta) return;
  const VS = "https://cdn.jsdelivr.net/npm/monaco-editor@0.52.2/min/vs";

  // Giữ Ctrl + con lăn chuột = chỉnh cỡ chữ (nhớ qua localStorage). Editor Monaco dùng
  // mouseWheelZoom riêng; đây cho log output + textarea fallback.
  function attachFontZoom(el, key) {
    if (!el) return;
    let size = parseFloat(localStorage.getItem(key)) || parseFloat(getComputedStyle(el).fontSize) || 13;
    el.style.fontSize = size + "px";
    el.addEventListener("wheel", (e) => {
      if (!e.ctrlKey) return;
      e.preventDefault();
      size = Math.min(40, Math.max(8, size + (e.deltaY < 0 ? 1 : -1)));
      el.style.fontSize = size + "px";
      try { localStorage.setItem(key, String(size)); } catch (_) {}
    }, { passive: false });
  }
  attachFontZoom(document.getElementById("scriptOut"), "iosauto.outZoom");

  // Khung chứa Monaco (đặt ngay trước textarea, chiếm cùng chỗ). Textarea ẩn đi (vẫn là backing khi fail).
  const host = document.createElement("div");
  host.id = "monacoHost";
  // Khớp layout của .editor-pane (flex column) như textarea cũ: flex:1 1 auto + min-height.
  host.style.cssText = "flex:1 1 auto;min-height:220px;border-radius:10px;overflow:hidden;";
  ta.parentNode.insertBefore(host, ta);
  ta.style.display = "none";

  const nativeVal = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value");
  function fallback() { // Monaco không nạp được → hiện lại textarea
    try { host.remove(); } catch (_) {}
    ta.style.display = "";
    attachFontZoom(ta, "iosauto.editZoom");   // Ctrl+cuộn chỉnh cỡ chữ cho textarea
  }

  // ---- Xây danh sách gợi ý từ IOSAUTO_FUNCS ----
  // Tách: hàm toplevel (tap, swipe…) vs phương thức crane.* (gợi ý sau khi gõ "crane.").
  function buildLists() {
    const funcs = window.IOSAUTO_FUNCS || [];
    const top = [], crane = [];
    let hasCrane = false;
    for (const f of funcs) {
      if (f.name.indexOf("crane.") === 0) {
        hasCrane = true;
        crane.push({ label: f.name.slice(6), insert: f.name.slice(6) + "($0)", detail: f.sig, doc: f.desc, ex: f.ex });
      } else if (f.name.indexOf(".") < 0) {
        top.push({ label: f.name, insert: f.name + "($0)", detail: f.sig, doc: f.desc, ex: f.ex });
      }
    }
    if (hasCrane) top.push({ label: "crane", insert: "crane.", detail: "Đa tài khoản (Crane)", doc: "Bảng crane.* — quản lý container/tài khoản (cần cài tweak Crane).", ex: "" });
    // vài từ khoá Lua hay dùng
    const KW = ["local", "function", "end", "if", "then", "else", "elseif", "for", "while", "do", "return", "true", "false", "nil", "and", "or", "not", "in", "break", "ipairs", "pairs", "tostring", "tonumber"];
    return { top, crane, KW };
  }

  // ---- Quét hàm/biến do NGƯỜI DÙNG tự định nghĩa trong script (để gợi ý kèm) ----
  // Bắt: "function tên(" (kể cả "local function tên("), "tên = function", và "local a, b, c".
  // Regex thô nhưng đủ dùng cho script Lua ngắn; trùng lặp gộp bằng Set.
  function scanUserSymbols(text) {
    const fns = new Set(), vars = new Set();
    let m;
    const reFn = /\bfunction\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/g;         // function ten(  |  local function ten(
    while ((m = reFn.exec(text))) fns.add(m[1]);
    const reAssignFn = /\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*function\b/g;  // ten = function
    while ((m = reAssignFn.exec(text))) fns.add(m[1]);
    const reLocal = /\blocal\s+([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)/g;  // local a, b, c
    while ((m = reLocal.exec(text)))
      for (const v of m[1].split(",")) { const t = v.trim(); if (t && t !== "function") vars.add(t); }
    for (const f of fns) vars.delete(f);   // đã là hàm thì không liệt kê lại như biến
    return { fns: [...fns], vars: [...vars] };
  }

  // Sinh SNIPPET NGẮN từ chữ ký hàm: tên + các tham số BẮT BUỘC + 1 tham số tuỳ chọn đầu tiên,
  // mỗi tham số là placeholder tab được. KHÔNG chèn ví dụ dài.
  //   'tapText("chữ" [, tries=1 [, delay [, lang]]])'  ->  tapText("${1:text}", ${2:tries})
  //   'tap(x, y)'                                       ->  tap(${1:x}, ${2:y})
  //   'crane.create(bundleId, tên)' (callName="create") ->  create(${1:bundleId}, ${2:tên})
  function shortSnippet(sig, callName) {
    callName = callName || "";
    if (!sig) return callName + "($0)";
    const m = sig.match(/\(([\s\S]*)\)/);
    if (!m) return callName + "($0)";
    const inner = m[1];
    const bi = inner.indexOf("[");
    const reqRaw = (bi >= 0 ? inner.slice(0, bi) : inner).replace(/,\s*$/, "").trim();
    const req = reqRaw ? reqRaw.split(",").map((s) => s.trim()).filter(Boolean) : [];
    let firstOpt = null;
    if (bi >= 0) {
      const opt = inner.slice(bi).replace(/[[\]]/g, "").replace(/^,\s*/, "");
      const o = opt.split(",").map((s) => s.trim()).filter(Boolean);
      if (o.length) firstOpt = o[0];
    }
    const chosen = firstOpt ? req.concat([firstOpt]) : req.slice();
    if (!chosen.length) return callName + "()";
    const args = chosen.map((p, i) => {
      const a = p.split("=")[0].trim();
      const ph = "${" + (i + 1) + ":" + (/^["']/.test(a) ? "text" : a) + "}";
      return /^["']/.test(a) ? '"' + ph + '"' : ph;
    });
    return callName + "(" + args.join(", ") + ")";
  }

  function initMonaco(monaco) {
    // Provider gợi ý cho ngôn ngữ lua.
    monaco.languages.registerCompletionItemProvider("lua", {
      triggerCharacters: [".", ":"],
      provideCompletionItems(model, position) {
        const L = buildLists();
        const line = model.getValueInRange({
          startLineNumber: position.lineNumber, startColumn: 1,
          endLineNumber: position.lineNumber, endColumn: position.column,
        });
        const w = model.getWordUntilPosition(position);
        const range = {
          startLineNumber: position.lineNumber, endLineNumber: position.lineNumber,
          startColumn: w.startColumn, endColumn: w.endColumn,
        };
        const K = monaco.languages.CompletionItemKind;
        const RULE = monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet;
        let src, kind;
        if (/crane\.\w*$/.test(line)) { src = L.crane; kind = K.Method; }   // sau "crane."
        else { src = L.top; kind = K.Function; }
        const suggestions = src.map((a) => {
          // Chọn 1 hàm → chèn LỜI GỌI NGẮN GỌN (name + tham số chính, dạng placeholder tab được),
          // KHÔNG chèn ví dụ dài. Ví dụ đầy đủ vẫn xem được ở ô tài liệu (documentation) bên phải.
          const isModule = a.insert.endsWith(".");            // vd item "crane" chèn "crane." để mở menu con
          return {
            label: a.label,
            kind: isModule ? K.Module : kind,
            insertText: isModule ? a.insert : shortSnippet(a.detail, a.label),
            insertTextRules: isModule ? undefined : RULE,
            detail: a.detail,
            documentation: a.doc ? { value: "**" + a.detail + "**\n\n" + a.doc + (a.ex ? "\n\n```lua\n" + a.ex + "\n```" : "") } : undefined,
            range,
          };
        });
        // từ khoá Lua + HÀM/BIẾN người dùng tự viết (chỉ ở ngữ cảnh toplevel)
        if (src === L.top) {
          for (const k of L.KW)
            suggestions.push({ label: k, kind: K.Keyword, insertText: k, range });
          // Quét cả script hiện tại: function tên(...) · tên = function · local a, b, c
          const u = scanUserSymbols(model.getValue());
          const seen = new Set(L.top.map((a) => a.label).concat(L.KW));   // tránh trùng hàm dựng sẵn/từ khoá
          for (const fn of u.fns) if (!seen.has(fn)) {
            seen.add(fn);
            suggestions.push({ label: fn, kind: K.Function, insertText: fn + "($0)", insertTextRules: RULE, detail: "hàm bạn tự viết", range });
          }
          for (const v of u.vars) if (!seen.has(v)) {
            seen.add(v);
            suggestions.push({ label: v, kind: K.Variable, insertText: v, detail: "biến cục bộ", range });
          }
        }
        return { suggestions };
      },
    });

    const ed = monaco.editor.create(host, {
      value: nativeVal.get.call(ta),
      language: "lua",
      theme: "vs-dark",
      fontSize: 13,
      lineNumbers: "on",
      minimap: { enabled: false },
      mouseWheelZoom: true,   // giữ Ctrl + con lăn = phóng to/thu nhỏ cỡ chữ editor
      automaticLayout: true,
      scrollBeyondLastLine: false,
      tabSize: 2,
      wordWrap: "on",
      quickSuggestions: true,
      suggestOnTriggerCharacters: true,
      renderWhitespace: "none",
      padding: { top: 8, bottom: 8 },
    });
    window.iosautoEditor = ed;

    // ---- Shim: scriptBox.value ⇄ Monaco (app.js đọc/ghi .value như cũ) ----
    Object.defineProperty(ta, "value", {
      configurable: true,
      get() { return ed.getValue(); },
      set(v) { ed.setValue(v == null ? "" : String(v)); },
    });
    // Đổi nội dung → phát 'input' trên textarea (để markDirty của app.js chạy).
    ed.onDidChangeModelContent(() => ta.dispatchEvent(new Event("input", { bubbles: true })));

    // Ctrl/Cmd+S = lưu, Ctrl/Cmd+Enter = chạy (giống thao tác nút).
    ed.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => {
      if (typeof window.saveScript === "function") window.saveScript();
    });
    ed.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.Enter, () => {
      const b = document.getElementById("btnRun"); if (b) b.click();
    });

    // ---- Chèn ví dụ từ bảng Hàm (docs.js) vào VỊ TRÍ con trỏ Monaco ----
    if (window.iosauto) {
      window.iosauto.insertCode = (code) => {
        const sel = ed.getSelection();
        ed.executeEdits("insert", [{ range: sel, text: code + "\n", forceMoveMarkers: true }]);
        ed.focus();
        ta.dispatchEvent(new Event("input", { bubbles: true }));
      };
    }
  }

  // ---- Nạp Monaco (AMD loader) ----
  const loader = document.createElement("script");
  loader.src = VS + "/loader.js";
  loader.onload = () => {
    try {
      window.require.config({ paths: { vs: VS } });
      // Worker qua data-URL (worker của CDN là cross-origin → phải bọc importScripts).
      window.MonacoEnvironment = {
        getWorkerUrl: () =>
          "data:text/javascript;charset=utf-8," +
          encodeURIComponent(
            "self.MonacoEnvironment={baseUrl:'" + VS + "/'};importScripts('" + VS + "/base/worker/workerMain.js');"
          ),
      };
      window.require(["vs/editor/editor.main"], () => {
        try { initMonaco(window.monaco); } catch (e) { console.error("monaco init", e); fallback(); }
      }, fallback);
    } catch (e) { console.error("monaco loader", e); fallback(); }
  };
  loader.onerror = fallback;
  document.head.appendChild(loader);
})();
