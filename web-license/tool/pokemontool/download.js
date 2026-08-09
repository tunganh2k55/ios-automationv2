// Trang tải PokemonTool — đọc latest.json (cùng thư mục) rồi điền version + kích thước.
// Script rời (không inline) vì CSP của server chỉ cho script-src 'self'.
(async function () {
  const $ = (s) => document.querySelector(s);
  const fmtMB = (n) => (n / (1024 * 1024)).toFixed(1) + " MB";
  try {
    const r = await fetch("latest.json", { cache: "no-store" });
    const m = await r.json();
    const p = m.portable || {};
    $("#ver").textContent = "v" + m.version;
    if (m.notes) $("#notes").textContent = m.notes;
    if (p.size) $("#size").textContent = fmtMB(p.size);
    const btn = $("#dl");
    btn.href = p.file || "download";
    btn.classList.remove("disabled");
    if (p.sha256) $("#sha").textContent = p.sha256;
  } catch (_) {
    $("#ver").textContent = "(chưa có bản phát hành)";
  }
})();
