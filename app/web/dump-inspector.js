// Coordinates in dump XML are screen points, independent of screenshot pixels.
let closeActiveDump = null;
export function closeDumpInspector() {
  if (!closeActiveDump) return false;
  closeActiveDump();
  return true;
}
export function openDumpInspector(xml) {
  const doc = new DOMParser().parseFromString(xml, 'application/xml');
  if (doc.querySelector('parsererror') || doc.documentElement.tagName !== 'screen') {
    throw new Error('Dump không phải XML màn hình hợp lệ.');
  }
  const width = Number(doc.documentElement.getAttribute('w'));
  const height = Number(doc.documentElement.getAttribute('h'));
  if (!(width > 0 && height > 0)) throw new Error('Dump thiếu kích thước màn hình.');
  closeDumpInspector();
  const modal = document.createElement('div');
  modal.className = 'dump-inspector';
  modal.innerHTML = `<div class="dump-head"><strong>🧬 Dump — kiểm tra element</strong><button class="mini dump-refresh">Dump lại</button><button class="mini dump-close">Đóng</button></div>
    <p class="dump-hint">Bấm vào khung để xem thuộc tính. Khi các khung chồng nhau, chọn element trong danh sách. Ảnh và dump được lấy lần lượt.</p>
    <div class="dump-body"><div class="dump-preview"><div class="dump-stage"><img alt="Ảnh màn hình lúc dump" draggable="false"><div class="dump-boxes"></div></div><p class="dump-image-error" hidden>Không tải được ảnh màn hình; vẫn có thể chọn các khung.</p></div>
    <div class="dump-side"><input class="dump-search" placeholder="Tìm class, text, label, id…" aria-label="Tìm element"><div class="dump-count"></div><div class="dump-list"></div><strong>Thuộc tính element</strong><div class="dump-properties">Chọn một element để xem tất cả thuộc tính.</div><details><summary>XML gốc</summary><pre class="dump-raw"></pre></details></div></div>`;
  modal.querySelector('.dump-preview').remove();
  modal.querySelector('.dump-hint').textContent = 'Bấm khung trên View bên trái để xem thuộc tính. Dump lại sau khi màn hình thay đổi. Đóng để tiếp tục điều khiển iPhone.';
  const screen = document.querySelector('#screen');
  const layer = document.createElement('div');
  layer.className = 'dump-view-overlay';
  // Capture inspection gestures before they can reach the VNC canvas.
  for (const name of ['pointerdown', 'pointerup', 'mousedown', 'mouseup', 'touchstart', 'touchend', 'wheel']) {
    layer.addEventListener(name, event => { event.stopPropagation(); event.preventDefault(); }, { passive: false });
  }
  screen.appendChild(layer);
  function alignOverlay() {
    const canvas = screen.querySelector('canvas');
    const bounds = screen.getBoundingClientRect();
    const rect = canvas?.getBoundingClientRect();
    layer.hidden = !rect || !rect.width || !rect.height;
    if (layer.hidden) return;
    // The canvas uses object-fit: contain; account for its letterboxing.
    const scale = Math.min(rect.width / (canvas.width || width), rect.height / (canvas.height || height));
    const w = (canvas.width || width) * scale;
    const h = (canvas.height || height) * scale;
    Object.assign(layer.style, { left: `${rect.left - bounds.left + (rect.width - w) / 2}px`, top: `${rect.top - bounds.top + (rect.height - h) / 2}px`, width: `${w}px`, height: `${h}px` });
  }
  const resize = new ResizeObserver(alignOverlay);
  resize.observe(screen);
  const mutations = new MutationObserver(alignOverlay);
  mutations.observe(screen.querySelector('#vncContainer'), { subtree: true, childList: true, attributes: true });
  window.addEventListener('resize', alignOverlay);
  alignOverlay();
  modal.querySelector('.dump-raw').textContent = xml;
  const list = modal.querySelector('.dump-list');
  const nodes = Array.from(doc.querySelectorAll('node, ax')).map((node, index) => {
    const attrs = Object.fromEntries(Array.from(node.attributes, a => [a.name, a.value]));
    const rect = ['x', 'y', 'w', 'h'].map(key => attrs[key] == null ? NaN : Number(attrs[key]));
    const [x, y, w, h] = rect;
    const drawable = rect.every(Number.isFinite) && w > 0 && h > 0 && attrs.visible !== '0' && x < width && y < height && x + w > 0 && y + h > 0;
    const label = `#${index + 1} ${attrs.type || attrs.class || node.tagName} ${attrs.text || attrs.label || attrs.id || ''}`;
    return { node, attrs, rect, drawable, label, index, box: null, row: null };
  });
  let selected = null;
  function select(item) {
    selected?.box?.classList.remove('selected');
    selected?.row.classList.remove('selected');
    selected = item;
    item.box?.classList.add('selected');
    item.row.classList.add('selected');
    item.row.scrollIntoView({ block: 'nearest' });
    const props = modal.querySelector('.dump-properties');
    props.replaceChildren();
    const title = document.createElement('p');
    title.textContent = `#${item.index + 1} <${item.node.tagName}>`;
    props.appendChild(title);
    const table = document.createElement('table');
    if (item.rect.every(Number.isFinite)) {
      const [x, y, w, h] = item.rect;
      const row = table.insertRow();
      row.insertCell().textContent = 'bounds';
      row.insertCell().textContent = `[${x},${y}][${x + w},${y + h}]`;
      row.title = 'Bounds tính từ dump: [trái,trên][phải,dưới], đơn vị điểm màn hình iOS.';
    }
    for (const [key, value] of Object.entries(item.attrs)) {
      const row = table.insertRow();
      row.insertCell().textContent = key;
      row.insertCell().textContent = value;
    }
    props.appendChild(table);
  }
  for (const item of nodes) {
    const row = document.createElement('button');
    row.className = 'dump-row'; row.textContent = item.label;
    row.title = item.label; row.onclick = () => select(item);
    item.row = row; list.appendChild(row);
  }
  // Large containers go underneath small elements so their children stay clickable.
  for (const item of nodes.filter(n => n.drawable).sort((a, b) => b.rect[2] * b.rect[3] - a.rect[2] * a.rect[3])) {
    const [x, y, w, h] = item.rect;
    const box = document.createElement('button');
    box.className = 'dump-box'; box.title = item.label;
    box.setAttribute('aria-label', item.label);
    Object.assign(box.style, { left: `${Math.max(0, x) / width * 100}%`, top: `${Math.max(0, y) / height * 100}%`, width: `${(Math.min(width, x + w) - Math.max(0, x)) / width * 100}%`, height: `${(Math.min(height, y + h) - Math.max(0, y)) / height * 100}%` });
    box.onclick = () => select(item);
    item.box = box; layer.appendChild(box);
  }
  const search = modal.querySelector('.dump-search');
  search.oninput = () => {
    const query = search.value.toLocaleLowerCase().trim();
    let count = 0;
    for (const item of nodes) {
      const match = (item.label + ' ' + JSON.stringify(item.attrs)).toLocaleLowerCase().includes(query);
      item.row.hidden = !match;
      if (item.box) item.box.hidden = !match;
      if (match) count++;
    }
    modal.querySelector('.dump-count').textContent = `${count}/${nodes.length} element · ${nodes.filter(n => n.drawable).length} khung trong màn hình`;
  };
  search.oninput();
  closeActiveDump = () => {
    resize.disconnect(); mutations.disconnect();
    window.removeEventListener('resize', alignOverlay);
    layer.remove(); modal.remove(); closeActiveDump = null;
    document.querySelector('#miDump').textContent = '🧬 Bật Dump';
  };
  modal.querySelector('.dump-close').onclick = closeDumpInspector;
  modal.querySelector('.dump-refresh').onclick = async event => {
    const button = event.currentTarget; button.disabled = true;
    try {
      const response = await fetch('/api/dump');
      const content = await response.text();
      if (!response.ok) throw new Error(content);
      openDumpInspector(content);
    } catch (error) { alert('Dump lỗi: ' + error.message); }
    finally { button.disabled = false; }
  };
  document.body.appendChild(modal);
  document.querySelector('#miDump').textContent = '🧬 Tắt Dump';
}
