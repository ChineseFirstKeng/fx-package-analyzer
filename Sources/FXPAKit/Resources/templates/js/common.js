/* ===== 公共 JS ===== */
function sortTable(th, tableId, colIdx, type) {
  var table = document.getElementById(tableId);
  if (!table) return;
  var tbody = table.querySelector('tbody');
  var rows = [].slice.call(tbody.querySelectorAll('tr'));
  var asc = th.classList.contains('asc');
  table.querySelectorAll('th.sortable').forEach(function(h) { h.classList.remove('asc','desc'); });
  th.classList.add(asc ? 'desc' : 'asc');
  rows.sort(function(a, b) {
    var va, vb;
    if (type === 'num') {
      va = parseFloat(a.getAttribute('data-size')) || 0;
      vb = parseFloat(b.getAttribute('data-size')) || 0;
    } else {
      va = (a.cells[colIdx] ? (a.cells[colIdx].textContent || '') : '').trim().toLowerCase();
      vb = (b.cells[colIdx] ? (b.cells[colIdx].textContent || '') : '').trim().toLowerCase();
    }
    if (va < vb) return asc ? 1 : -1;
    if (va > vb) return asc ? -1 : 1;
    return 0;
  });
  rows.forEach(function(r) { tbody.appendChild(r); });
}
function applyFilters(tableId) {
  var table = document.getElementById(tableId);
  if (!table) return;
  var rows = [].slice.call(table.querySelectorAll('tbody tr'));
  var parent = table.closest('.section') || table.parentElement;
  var selects = parent.querySelectorAll('.filter-bar select');
  var si = parent.querySelector('.filter-bar input[type="text"]');

  // 是否有筛选条件
  var filterActive = false;
  selects.forEach(function(sel) { if (sel.value !== 'all') filterActive = true; });
  if (si && si.value) filterActive = true;

  var treeRows = [];
  rows.forEach(function(r) {
    if (r.classList.contains('tree-children-row')) return;
    if (r.classList.contains('tree-row-toggle')) { treeRows.push(r); return; }
    var ok = true;
    selects.forEach(function(sel) {
      var val = sel.value, key = sel.getAttribute('data-key');
      if (val !== 'all' && key && r.getAttribute('data-' + key) !== val) ok = false;
    });
    if (ok && si && si.value) ok = r.textContent.toLowerCase().indexOf(si.value.toLowerCase()) !== -1;
    r.style.display = ok ? '' : 'none';
  });

  treeRows.forEach(function(row) {
    var next = row.nextElementSibling;
    var isChildrenRow = next && next.classList.contains('tree-children-row');
    if (!isChildrenRow) return;

    if (filterActive) {
      var hasVisible = false;
      var cr = next.querySelectorAll('tbody tr');
      cr.forEach(function(c) { if (c.style.display !== 'none') hasVisible = true; });
      row.style.display = hasVisible ? '' : 'none';
      row.setAttribute('data-expanded', hasVisible ? '1' : '0');
    } else {
      row.style.display = '';
      row.setAttribute('data-expanded', '0');
    }
    if (typeof syncTreeRow === 'function') syncTreeRow(row);
  });
}
function initTabs(navSel, contentSel) {
  document.querySelectorAll(navSel).forEach(function(item) {
    item.addEventListener('click', function() {
      document.querySelectorAll(navSel).forEach(function(n) { n.classList.remove('active'); });
      item.classList.add('active');
      var idx = item.getAttribute('data-tab');
      document.querySelectorAll(contentSel).forEach(function(c) { c.classList.remove('active'); });
      var t = document.getElementById('tab' + idx);
      if (t) t.classList.add('active');
      var mh = document.querySelector('.main > .header');
      if (mh) mh.style.display = (idx === '0') ? '' : 'none';
    });
  });
}
function toggleExplain(header) {
  var wrap = header.parentElement;
  if (!wrap) return;
  var explain = wrap.querySelector('.explain');
  var toggle = header.querySelector('.explain-toggle');
  if (!explain) return;
  var isHidden = explain.style.display === 'none';
  explain.style.display = isHidden ? 'block' : 'none';
  if (toggle) toggle.textContent = isHidden ? '▼' : '▶';
}
document.addEventListener('DOMContentLoaded', function() {
  if (window.self !== window.top) {
    var c = document.querySelector('.container');
    if (c) { c.style.maxWidth = 'none'; c.style.margin = '0'; }
  }
});
