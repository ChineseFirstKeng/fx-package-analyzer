/* ===== 报告渲染引擎 — 纯 JS，零依赖 ===== */

// ── 全局配置 ──
window.REPORT_CONFIG = window.REPORT_CONFIG || {};
// sorting: 表头排序开关，默认关闭。设为 true 可启用。
if (window.REPORT_CONFIG.sorting === undefined) window.REPORT_CONFIG.sorting = false;

// ── 工具 ──
function fmtSize(b) {
  if (!b) return '0 B';
  if (b >= 1048576) return (b / 1048576).toFixed(2) + ' MB';
  if (b >= 1024) return (b / 1024).toFixed(2) + ' KB';
  return b + ' B';
}
function esc(s) {
  if (!s) return '';
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
function percent(val, total) {
  if (!total) return '0.0%';
  return (val / total * 100).toFixed(1) + '%';
}

// ── KPI 卡片 ──
function kpiCard(label, value, opts = {}) {
  const { sub = '', color = '', valueDisplay = false } = opts;
  const v = valueDisplay ? fmtSize(value) : value;
  const c = color ? ' style="color:' + color + '"' : '';
  const s = sub ? '<div class="kpi-sub">' + sub + '</div>' : '';
  return '<div class="kpi"><div class="kpi-label">' + label + '</div><div class="kpi-value"' + c + '>' + v + '</div>' + s + '</div>';
}

// ── Section 容器 ──
function section(title, body, opts = {}) {
  const { hint = '', explain = '', explain_expand = false } = opts;
  const h = hint ? '<span class="hint">' + hint + '</span>' : '';
  let e = '';
  if (explain) {
    // 从 explain HTML 中提取标题（支持 【xxx】 和 &#12304;xxx&#12305; 格式）
    const titleMatch = explain.match(/<b>(?:【|&#12304;)(.+?)(?:】|&#12305;)<\/b>/);
    const explainTitle = titleMatch ? titleMatch[1] : '实现原理';
    // 从内容中移除标题行（避免重复显示）
    let explainBody = explain.replace(/<b>(?:【|&#12304;).+?(?:】|&#12305;)<\/b>(?:<br>|\s)*/, '');
    const icon = explain_expand ? '▼' : '▶';
    e = '<div class="explain-wrap">';
    e += '<div class="explain-header" onclick="toggleExplain(this)" style="cursor:pointer;display:flex;align-items:center;gap:6px;font-size:13px;font-weight:600;margin-bottom:8px">';
    e += '<span class="explain-toggle">' + icon + '</span> ' + explainTitle + '</div>';
    e += '<div class="explain" style="display:' + (explain_expand ? 'block' : 'none') + '">' + explainBody + '</div>';
    e += '</div>';
  }
  return '<div class="section"><div class="section-title">' + title + h + '</div>' + e + body + '</div>';
}

// ── Banner ──
function banner(type, text) {
  return '<div class="' + type + '-banner">' + text + '</div>';
}

// ── Filter Bar ──
function filterBar(tableId, opts = {}) {
  const { selects = [], search = null } = opts;
  let html = '<div class="filter-bar">';
  selects.forEach(s => {
    html += '<label style="margin-right:4px;font-size:12px;color:var(--text2)">' + s.label + '</label>';
    html += '<select id="' + s.id + '" data-key="' + s.dataKey + '" onchange="applyFilters(\'' + tableId + '\')">';
    s.options.forEach(o => html += '<option value="' + o.value + '">' + o.label + '</option>');
    html += '</select>';
  });
  if (search) html += '<input type="text" id="' + search.id + '" placeholder="' + (search.placeholder || '搜索...') + '" oninput="applyFilters(\'' + tableId + '\')">';
  if (window.REPORT_CONFIG.sorting) html += '<span class="hint">点击表头排序</span>';
  html += '</div>';
  return html;
}

// ── 可排序表格 ──
function sortableTable(id, columns, rows) {
  if (!rows.length) {
    return '<table class="data-table" id="' + id + '"><thead><tr>' +
      columns.map(c => '<th>' + c.label + '</th>').join('') +
      '</tr></thead><tbody><tr><td colspan="' + columns.length + '" class="empty">暂无数据</td></tr></tbody></table>';
  }
  let th = '<thead><tr>';
  columns.forEach((c, i) => {
    const sortAttr = (window.REPORT_CONFIG.sorting && c.sortable) ? ' class="sortable" onclick="sortTable(this,\'' + id + '\',' + i + ',\'' + (c.sortType || 'str') + '\')"' : '';
    th += '<th' + sortAttr + '>' + c.label + '</th>';
  });
  th += '</tr></thead>';

  let tb = '<tbody>';
  rows.forEach(r => {
    const sk = r.sortKey || 0;
    let trAttrs = ' data-size="' + sk + '"';
    if (r.class_name) trAttrs += ' class="' + esc(r.class_name) + '"';
    // 支持两种 attrs 格式：数组 [{key, value}] 和对象 {key: value}
    if (r.attrs) {
      if (Array.isArray(r.attrs)) {
        r.attrs.forEach(a => { trAttrs += ' data-' + a.key + '="' + esc(a.value) + '"'; });
      } else {
        for (let k in r.attrs) { if (r.attrs.hasOwnProperty(k)) trAttrs += ' data-' + k + '="' + esc(r.attrs[k]) + '"'; }
      }
    }
    tb += '<tr' + trAttrs + '>';
    r.cells.forEach(cell => {
      const cls = cell.cls || '';
      var t = cell.title || '';
      if (!t && cell.value) t = cell.value.replace(/<[^>]*>/g, '');  // 去 HTML 标签
      const title = ' title="' + esc(t) + '"';
      const style = cell.style ? ' style="' + cell.style + '"' : '';
      tb += '<td class="' + cls + '"' + title + style + '>' + (cell.value || '') + '</td>';
    });
    tb += '</tr>';
  });
  tb += '</tbody>';
  var cg = '';
  if (columns.length && columns[0].colWidth) {
    cg = '<colgroup>' + columns.map(function(c) {
      return c.colWidth === 'auto' ? '<col>' : '<col style="width:' + c.colWidth + '">';
    }).join('') + '</colgroup>';
  }
  return '<table class="data-table" id="' + id + '">' + cg + th + tb + '</table>';
}

// ── 环形图（扇形填充） ──
function donutChart(centerLabel, items) {
  const total = items.reduce((s, i) => s + i.value, 0);
  if (!total) return '<div style="color:var(--text2);padding:40px;text-align:center">暂无数据</div>';

  const COLORS = (window.SHARED_CONSTANTS && window.SHARED_CONSTANTS.PALETTE) || [];
  const cx = 100, cy = 100, R = 90; // 外半径
  let paths = '', legends = '', angle = -Math.PI / 2; // 从 12 点方向开始

  items.forEach((item, i) => {
    const pct = item.value / total;
    const sweep = pct * 2 * Math.PI;
    const color = item.color || COLORS[i % COLORS.length];
    const x1 = cx + R * Math.cos(angle);
    const y1 = cy + R * Math.sin(angle);
    const x2 = cx + R * Math.cos(angle + sweep);
    const y2 = cy + R * Math.sin(angle + sweep);
    const large = sweep > Math.PI ? 1 : 0;
    // 扇形：从圆心到外弧
    const d = 'M' + cx + ',' + cy + ' L' + x1.toFixed(2) + ',' + y1.toFixed(2) + ' A' + R + ',' + R + ' 0 ' + large + ',1 ' + x2.toFixed(2) + ',' + y2.toFixed(2) + ' Z';
    paths += '<path d="' + d + '" fill="' + color + '"><title>' + item.label + ': ' + fmtSize(item.value) + ' (' + (pct * 100).toFixed(1) + '%)</title></path>';
    angle += sweep;
    legends += '<div class="dl-item"><span class="dl-dot" style="background:' + color + '"></span><span class="dl-name">' + item.label + '</span><span class="dl-pct">' + (pct * 100).toFixed(1) + '%</span><span class="dl-size">' + fmtSize(item.value) + '</span></div>';
  });

  return '<div class="donut-wrap"><svg viewBox="0 0 200 200" class="donut-svg">' + paths +
    '<circle cx="100" cy="100" r="55" fill="#fff"/><text x="100" y="94" text-anchor="middle" class="donut-center">' + fmtSize(total) + '</text><text x="100" y="116" text-anchor="middle" class="donut-sub">' + centerLabel + '</text></svg><div>' + legends + '</div></div>';
}

// ── Explain 块 ──
function explainBlock(data) {
  if (!data || !data.steps) return '';
  let html = '<div class="explain">';
  if (data.title) html += '<b>【' + data.title + '】</b><br><br>';
  data.steps.forEach(s => {
    const t = s.type || 'step';
    if (t === 'step') html += '<b>' + s.title + '</b><br>' + (s.desc || '').replace(/\n/g, '<br>') + '<br><br>';
    else if (t === 'items') {
      html += '<b>' + s.title + '：</b><br>';
      (s.items || []).forEach(item => html += '- ' + item + '<br>');
      html += '<br>';
    } else if (t === 'kv') {
      html += '<b>' + s.title + '：</b><br>';
      (s.pairs || []).forEach(p => html += p[0] + ' → ' + p[1] + '<br>');
      html += '<br>';
    } else if (t === 'code') html += '<b>' + s.title + '：</b><br><pre>' + (s.code || '') + '</pre><br>';
    else if (t === 'text') html += (s.desc || '').replace(/\n/g, '<br>') + '<br><br>';
  });
  return html + '</div>';
}

// ── 类型标签 ──
function typeBadge(t) {
  var labels = { static_lib: '静态库', dynamic_framework: '动态库', system: '系统库', other: '其他', synthesized: '链接器合成', toolchain: '工具链' };
  return '<span class="type-badge type-' + (t || 'other') + '">' + (labels[t] || t || '其他') + '</span>';
}

// ── 置信度标签 ──
function confLabel(c) {
  if (c === 'L1' || c === 'high') return '<span class="bad">L1 高</span>';
  if (c === 'L2' || c === 'medium') return '<span class="warn">L2 中</span>';
  return '<span class="ok">' + esc(c) + '</span>';
}

// ── 树形目录结构（常量来自 window.SHARED_CONSTANTS）──
var TREE_ICONS = (window.SHARED_CONSTANTS && window.SHARED_CONSTANTS.TREE_ICONS) || {};
var TREE_TYPE_LABELS = (window.SHARED_CONSTANTS && window.SHARED_CONSTANTS.TREE_TYPE_LABELS) || {};

// 表头组件。columns: [{label, colWidth}] — 第一列 flex，其余默认100px。
function renderHeader(columns) {
  var h = '<table class="data-table"><colgroup>';
  columns.forEach(function(c,i) {
    var w = c.colWidth || (i === 0 ? 'auto' : '100px');
    h += w === 'auto' ? '<col>' : '<col style="width:' + w + '">';
  });
  h += '</colgroup><thead><tr>';
  columns.forEach(function(c) { h += '<th>' + esc(c.label) + '</th>'; });
  h += '</tr></thead><tbody>';
  return h;
}

// 树节点行 → <tr>/<td>。opts: { columns, icons, labels, collapsible }
function _treeRow(node, totalSize, depth, opts) {
  var hasChildren = node.children && node.children.length > 0;
  var collapsible = opts.collapsible !== false;
  var html = '<tr class="' + (collapsible && hasChildren ? 'tree-row-toggle' : '') + '"';
  if (node.attrs) {
    for (var ak in node.attrs) {
      if (node.attrs.hasOwnProperty(ak)) html += ' data-' + ak + '="' + esc(node.attrs[ak]) + '"';
    }
  }
  var startHidden = opts.start_collapsed !== false;
  html += (collapsible && hasChildren ? ' data-expanded="' + (startHidden ? '0' : '1') + '" onclick="toggleTreeRow(this)"' : '') + '>';
  // 逐列
  opts.columns.forEach(function(c, colIdx) {
    var val = _treeCell(node, c.key, totalSize, opts);
    var cls = c.cls || 'num';
    var pad = (colIdx === 0 && depth > 0) ? '<span style="display:inline-block;width:' + (depth*20) + 'px"></span>' : '';
    var icon = (colIdx === 0 && collapsible) ? '<span class="tree-toggle' + (hasChildren?'':' leaf') + '">▶</span> ' + (opts.icons[node.type] || '📄') + ' ' : '';
    var raw = (node[c.key] != null) ? String(node[c.key]) : '';
    var title = raw ? ' title="' + esc(raw) + '"' : '';
    html += '<td class="' + cls + '"' + title + '>' + pad + icon + val + '</td>';
  });
  html += '</tr>';
  if (hasChildren) {
    var startHidden = opts.start_collapsed !== false;
    html += '<tr class="tree-children-row" style="display:' + (startHidden ? 'none' : '') + '"><td colspan="' + opts.columns.length + '" style="padding:0">';
    html += '<table class="data-table"><colgroup>';
    opts.columns.forEach(function(c) {
      html += c.colWidth === 'auto' ? '<col>' : '<col style="width:' + (c.colWidth || 'auto') + '">';
    });
    html += '</colgroup><tbody>';
    var sorted = node.children.slice().sort(function(a,b){ return b.size - a.size; });
    sorted.forEach(function(c){ html += _treeRow(c, totalSize, depth + 1, opts); });
    html += '</tbody></table></td></tr>';
  }
  return html;
}

function _treeCell(node, key, totalSize, opts) {
  switch (key) {
    case 'name': return esc(node.name || '');
    case 'size': return fmtSize(node.size || 0);
    case 'pct':  return totalSize ? (node.size / totalSize * 100).toFixed(1) + '%' : '0.0%';
    case 'type':
      var l = opts.labels[node.type];
      if (l && typeof l === 'object' && l.label) {
        return '<span class="type-badge" style="color:' + l.color + ';background:' + l.bg + '">' + esc(l.label) + '</span>';
      }
      return esc(l || node.type || '');
    case 'path': return esc(node.path || '');
    case 'path_list':
    case 'name_list':
    case 'owner_list':
    case 'source_list': return esc(node[key] || '').replace(/\n/g, '<br>');
    case '_badge': return typeBadge(node['_badge']);
    default:      return esc(node[key] || '');
  }
}

// 从 data-expanded 同步 UI（display + 箭头），所有展开/闭合的唯一出口
function syncTreeRow(row) {
  var next = row.nextElementSibling;
  if (!next || !next.classList.contains('tree-children-row')) return;
  var expanded = row.getAttribute('data-expanded') === '1';
  var toggle = row.querySelector('.tree-toggle');
  next.style.display = expanded ? '' : 'none';
  if (toggle) {
    if (expanded) toggle.classList.add('open'); else toggle.classList.remove('open');
  }
}

function toggleTreeRow(row) {
  var expanded = row.getAttribute('data-expanded') === '1';
  row.setAttribute('data-expanded', expanded ? '0' : '1');
  syncTreeRow(row);
}

