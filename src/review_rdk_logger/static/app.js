(() => {
  'use strict';

  const MAX_PANES = 3;
  const EMPTY_BYTES = 16;
  const ERR_RE = /\b(ERROR|PANIC|FATAL|CRITICAL|SEGFAULT|EXCEPTION|TRACEBACK|FAIL|FAILED)\b/i;
  const WARN_RE = /\b(WARN|WARNING)\b/i;

  const state = {
    catalog: { macs: [], by_mac: {} },
    mac: null,
    archives: new Set(),
    summaries: new Map(),
    pending: new Set(),
    panes: [],
    fileQuery: '',
    hideEmpty: true,
    issuesOnly: false,
    sort: 'name',
    columns: Number(localStorage.getItem('columns')) || 2,
    sidebarVisible: true,
  };
  let paneSeq = 0;

  // ---------- helpers ----------
  const $ = (sel, root = document) => root.querySelector(sel);
  const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
  const escapeHtml = (s) => s.replace(/[&<>"']/g, (c) => ESC[c]);
  const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const basename = (p) => p.split('/').pop();
  const dirname = (p) => (p.includes('/') ? p.slice(0, p.lastIndexOf('/')) : '');
  const keyOf = (archive, path) => `${archive}::${path}`;

  function el(tag, attrs = {}, ...children) {
    const node = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs)) {
      if (v == null || v === false) continue;
      if (k === 'class') node.className = v;
      else if (k === 'text') node.textContent = v;
      else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
      else node.setAttribute(k, v === true ? '' : v);
    }
    for (const child of children) if (child != null) node.append(child);
    return node;
  }

  function fmtBytes(n) {
    if (n == null) return '';
    if (n < 1024) return `${n} B`;
    const units = ['KB', 'MB', 'GB'];
    let i = -1;
    do { n /= 1024; i += 1; } while (n >= 1024 && i < units.length - 1);
    return `${n.toFixed(n < 10 ? 1 : 0)} ${units[i]}`;
  }

  const fmtDate = (iso) =>
    iso ? new Date(iso).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' }) : '';
  const fmtNum = (n) => Number(n || 0).toLocaleString();
  const debounce = (fn, ms) => { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; };

  async function api(url, options) {
    const res = await fetch(url, options);
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || `${res.status} ${res.statusText}`);
    return data;
  }

  function toast(message, kind = 'info') {
    const node = el('div', { class: `toast toast-${kind}`, text: message });
    $('#toasts').append(node);
    setTimeout(() => node.classList.add('toast-hide'), 4000);
    setTimeout(() => node.remove(), 4500);
  }

  function badges(counts) {
    const wrap = el('span', { class: 'badges' });
    if (!counts) return wrap;
    if (counts.error) wrap.append(el('span', { class: 'badge badge-err', title: 'errors', text: fmtNum(counts.error) }));
    if (counts.warn) wrap.append(el('span', { class: 'badge badge-warn', title: 'warnings', text: fmtNum(counts.warn) }));
    return wrap;
  }

  // ---------- data ----------
  const archivesForMac = (mac) => state.catalog.by_mac[mac] || [];
  const findArchive = (name) =>
    Object.values(state.catalog.by_mac).flat().find((entry) => entry.archive === name) || null;
  const currentArchives = () => [...state.archives].map(name => findArchive(name)).filter(Boolean);
  const getPrimaryArchive = () => [...state.archives][0] || null;

  function archiveTotals(name) {
    const summary = state.summaries.get(name);
    if (!summary) return null;
    return Object.values(summary).reduce((acc, c) => ({ error: acc.error + c.error, warn: acc.warn + c.warn }), { error: 0, warn: 0 });
  }

  async function ensureSummary(name) {
    if (!name || state.summaries.has(name) || state.pending.has(name)) return;
    state.pending.add(name);
    renderArchives();
    renderFiles();
    try {
      const data = await api(`/api/summary?archive=${encodeURIComponent(name)}`);
      state.summaries.set(name, data.files);
    } catch (err) {
      toast(`Could not scan ${name}: ${err.message}`, 'error');
    } finally {
      state.pending.delete(name);
      renderArchives();
      renderFiles();
    }
  }

  async function loadCatalog() {
    try {
      state.catalog = await api('/api/catalog');
    } catch (err) {
      toast(`Failed to load catalog: ${err.message}`, 'error');
      return;
    }
    const names = new Set(Object.values(state.catalog.by_mac).flat().map((a) => a.archive));
    for (const name of [...state.summaries.keys()]) if (!names.has(name)) state.summaries.delete(name);
    state.panes.filter((p) => !names.has(p.archive)).forEach((p) => closePane(p, false));

    if (!state.catalog.macs.includes(state.mac)) state.mac = state.catalog.macs[0] || null;
    const validArchives = archivesForMac(state.mac).map(a => a.archive);
    state.archives = new Set([...state.archives].filter(a => validArchives.includes(a)));
    if (state.archives.size === 0 && validArchives.length > 0) {
      state.archives.add(validArchives[0]);
    }
    renderAll();
    for (const archive of state.archives) ensureSummary(archive);
  }

  // ---------- selection ----------
  function selectMac(mac) {
    if (mac === state.mac) return;
    state.mac = mac;
    state.archives.clear();
    const firstArchive = archivesForMac(mac)[0]?.archive || null;
    if (firstArchive) state.archives.add(firstArchive);
    renderAll();
    for (const archive of state.archives) ensureSummary(archive);
    saveHash();
  }

  function toggleArchive(name) {
    if (state.archives.has(name)) {
      if (state.archives.size > 1) {
        state.archives.delete(name);
      }
    } else {
      state.archives.add(name);
      ensureSummary(name);
    }
    renderArchives();
    renderFiles();
    saveHash();
  }

  async function deleteArchive(entry) {
    if (!confirm(`Delete uploaded bundle "${entry.archive}"?`)) return;
    try {
      await api(`/api/archives/${encodeURIComponent(entry.archive)}`, { method: 'DELETE' });
      toast(`Deleted ${entry.archive}`, 'success');
      state.archives.delete(entry.archive);
      await loadCatalog();
    } catch (err) {
      toast(`Delete failed: ${err.message}`, 'error');
    }
  }

  // ---------- rendering: sidebar ----------
  function renderAll() {
    renderStats();
    renderDevices();
    renderArchives();
    renderFiles();
    renderViewer();
  }

  function renderStats() {
    const archives = Object.values(state.catalog.by_mac).flat();
    const total = archives.reduce((s, a) => s + a.size, 0);
    $('#globalStats').textContent = archives.length
      ? `${state.catalog.macs.length} device(s) · ${archives.length} bundle(s) · ${fmtBytes(total)}`
      : 'No log bundles yet — upload a .tgz to get started';
  }

  function renderDevices() {
    const select = $('#deviceSelect');
    select.replaceChildren();
    $('#deviceCount').textContent = state.catalog.macs.length || '';
    if (!state.catalog.macs.length) {
      select.append(el('option', { value: '', text: 'No bundles found' }));
      return;
    }
    select.append(el('option', { value: '', text: 'Select a device…' }));
    for (const mac of state.catalog.macs) {
      const entries = archivesForMac(mac);
      const latest = entries[0]?.captured_at || entries[0]?.modified;
      select.append(
        el('option', { value: mac, selected: mac === state.mac, text: `${mac} (${entries.length} bundle(s))` })
      );
    }
  }

  function renderArchives() {
    const list = $('#archiveList');
    list.replaceChildren();
    const entries = archivesForMac(state.mac);
    $('#archiveCount').textContent = entries.length || '';
    if (!entries.length) {
      list.append(el('p', { class: 'muted small', text: 'Select a device to see its bundles.' }));
      return;
    }
    for (const entry of entries) {
      const scanning = state.pending.has(entry.archive);
      const item = el('div', {
        class: `archive${state.archives.has(entry.archive) ? ' active' : ''}`,
        title: entry.archive,
      },
        el('label', { class: 'toggle' },
          el('input', {
            type: 'checkbox',
            checked: state.archives.has(entry.archive),
            onchange: (e) => { toggleArchive(entry.archive); }
          }),
          el('span', { text: entry.archive })
        ),
        el('div', { class: 'archive-main' },
          el('span', { class: 'archive-time', text: fmtDate(entry.captured_at) || entry.archive }),
          el('span', { class: 'archive-meta muted', text: `${entry.log_files.length} files · ${fmtBytes(entry.size)}${entry.deletable ? ' · uploaded' : ''}` })),
        el('div', { class: 'archive-side' },
          scanning ? el('span', { class: 'spinner', title: 'Scanning…' }) : badges(archiveTotals(entry.archive)),
          entry.deletable
            ? el('button', {
                type: 'button', class: 'btn btn-icon btn-sm btn-danger', title: 'Delete uploaded bundle',
                onclick: (e) => { e.stopPropagation(); deleteArchive(entry); },
              }, svgIcon('M5 7h14M10 11v6M14 11v6M6 7l1 12a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1l1-12M9 7V4h6v3'))
            : null)
      );
      list.append(item);
    }
  }

  function svgIcon(d) {
    const ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    const path = document.createElementNS(ns, 'path');
    path.setAttribute('d', d);
    svg.append(path);
    return svg;
  }

  function currentFiles() {
    const entries = currentArchives();
    if (!entries.length) return { all: [], shown: [] };
    
    // Collect files from all selected archives
    const all = [];
    for (const entry of entries) {
      const summary = state.summaries.get(entry.archive);
      for (const path of entry.log_files) {
        all.push({
          path,
          name: basename(path),
          dir: dirname(path),
          size: entry.sizes?.[path] ?? 0,
          archive: entry.archive,
          archiveName: entry.archive,
          counts: summary?.[path] || (summary ? { error: 0, warn: 0 } : null),
        });
      }
    }
    
    const q = state.fileQuery.toLowerCase();
    let shown = all.filter((f) =>
      (!q || f.path.toLowerCase().includes(q)) &&
      (!state.hideEmpty || f.size > EMPTY_BYTES) &&
      (!state.issuesOnly || !f.counts || f.counts.error + f.counts.warn > 0));
    const issues = (f) => (f.counts ? f.counts.error * 1000 + f.counts.warn : 0);
    const sorters = {
      name: (a, b) => a.path.localeCompare(b.path, undefined, { numeric: true }),
      issues: (a, b) => issues(b) - issues(a) || a.path.localeCompare(b.path),
      size: (a, b) => b.size - a.size,
    };
    shown = shown.sort(sorters[state.sort]);
    return { all, shown };
  }

  function renderFiles() {
    const list = $('#fileList');
    list.replaceChildren();
    const entries = currentArchives();
    if (!entries.length) {
      $('#fileCount').textContent = '';
      list.append(el('p', { class: 'muted small', text: 'Select a bundle to list its log files.' }));
      return;
    }
    const { all, shown } = currentFiles();
    $('#fileCount').textContent = shown.length === all.length ? `${all.length}` : `${shown.length} / ${all.length}`;
    if (!shown.length) {
      list.append(el('p', { class: 'muted small', text: 'No files match the current filters.' }));
      return;
    }
    const open = new Set(state.panes.map((p) => keyOf(p.archive, p.path)));
    const frag = document.createDocumentFragment();
    for (const f of shown) {
      frag.append(
        el('button', {
          type: 'button',
          class: `file${open.has(keyOf(f.archive, f.path)) ? ' active' : ''}`,
          title: `${f.archive} :: ${f.path}`,
          onclick: () => openPane(f.archive, f.path),
        },
          el('span', { class: 'file-main' },
            el('span', { class: 'file-name', text: f.name }),
            f.dir ? el('span', { class: 'file-dir muted', text: f.dir }) : null),
          el('span', { class: 'file-side' },
            el('span', { class: 'muted small mono', text: entries.length > 1 ? f.archiveName.substring(0, 12) + '…' : '' }),
            badges(f.counts),
            el('span', { class: 'file-size muted', text: fmtBytes(f.size) })))
      );
    }
    list.append(frag);
  }

  // ---------- viewer ----------
  function openPane(archive, path) {
    const existing = state.panes.find((p) => p.archive === archive && p.path === path);
    if (existing) {
      existing.node.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
      existing.node.classList.remove('flash');
      void existing.node.offsetWidth;
      existing.node.classList.add('flash');
      return;
    }
    if (state.panes.length >= MAX_PANES) {
      toast(`Showing at most ${MAX_PANES} logs — closed the oldest one`, 'info');
      closePane(state.panes[0], false);
    }
    const pane = {
      id: ++paneSeq, archive, path, data: null, lines: [], levels: [],
      query: '', only: false, level: 'all', wrap: false, matchIdx: -1, issueIdx: -1,
    };
    pane.node = buildPane(pane);
    state.panes.push(pane);
    renderViewer();
    renderFiles();
    saveHash();
    loadPane(pane);
  }

  function closePane(pane, rerender = true) {
    state.panes = state.panes.filter((p) => p !== pane);
    pane.node.remove();
    if (rerender) {
      renderViewer();
      renderFiles();
      saveHash();
    }
  }

  async function loadPane(pane) {
    const body = $('.log-lines', pane.node);
    try {
      const data = await api(`/api/log-content?archive=${encodeURIComponent(pane.archive)}&path=${encodeURIComponent(pane.path)}`);
      if (!state.panes.includes(pane)) return;
      pane.data = data;
      pane.lines = data.content.split(/\r?\n/);
      if (pane.lines.length && pane.lines[pane.lines.length - 1] === '') pane.lines.pop();
      pane.levels = pane.lines.map((l) => (ERR_RE.test(l) ? 'err' : WARN_RE.test(l) ? 'warn' : ''));
      renderPaneStats(pane);
      renderPaneLines(pane);
    } catch (err) {
      body.replaceChildren(el('div', { class: 'pane-message error', text: `Unable to load: ${err.message}` }));
    }
  }

  function buildPane(pane) {
    const node = $('#paneTemplate').content.firstElementChild.cloneNode(true);
    const entry = findArchive(pane.archive);
    $('.pane-name', node).textContent = basename(pane.path);
    $('.pane-path', node).textContent = `${entry ? fmtDate(entry.captured_at) || pane.archive : pane.archive} · ${pane.path}`;
    $('.pane-path', node).title = `${pane.archive} :: ${pane.path}`;
    $('[data-act="download"]', node).href =
      `/api/download?archive=${encodeURIComponent(pane.archive)}&path=${encodeURIComponent(pane.path)}`;

    $('[data-act="close"]', node).addEventListener('click', () => closePane(pane));
    $('[data-act="wrap"]', node).addEventListener('click', (e) => {
      pane.wrap = !pane.wrap;
      node.classList.toggle('wrap', pane.wrap);
      e.currentTarget.classList.toggle('on', pane.wrap);
    });
    $('[data-act="next-issue"]', node).addEventListener('click', () => jumpIssue(pane, 1));
    $('[data-act="prev-issue"]', node).addEventListener('click', () => jumpIssue(pane, -1));

    const search = $('.pane-search', node);
    const rerender = debounce(() => renderPaneLines(pane), 150);
    search.addEventListener('input', () => { pane.query = search.value; rerender(); });
    search.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); jumpMatch(pane, e.shiftKey ? -1 : 1); }
      if (e.key === 'Escape') { search.value = ''; pane.query = ''; renderPaneLines(pane); }
    });
    $('.pane-only', node).addEventListener('change', (e) => { pane.only = e.target.checked; renderPaneLines(pane); });
    $('.pane-level', node).addEventListener('change', (e) => { pane.level = e.target.value; renderPaneLines(pane); });
    return node;
  }

  function renderPaneStats(pane) {
    const { data } = pane;
    const errs = pane.levels.filter((l) => l === 'err').length;
    const warns = pane.levels.filter((l) => l === 'warn').length;
    const stats = $('.pane-stats', pane.node);
    stats.replaceChildren(
      el('span', { text: `${fmtNum(pane.lines.length)} lines` }),
      el('span', { text: fmtBytes(data.size) }),
      el('span', { class: errs ? 'stat-err' : '', text: `${fmtNum(errs)} error lines` }),
      el('span', { class: warns ? 'stat-warn' : '', text: `${fmtNum(warns)} warning lines` }),
      data.truncated ? el('span', { class: 'stat-warn', text: `truncated — download for full file` }) : null
    );
  }

  function highlight(line, re) {
    if (!re) return escapeHtml(line);
    let out = '';
    let last = 0;
    line.replace(re, (match, offset) => {
      out += `${escapeHtml(line.slice(last, offset))}<mark>${escapeHtml(match)}</mark>`;
      last = offset + match.length;
      return match;
    });
    return out + escapeHtml(line.slice(last));
  }

  function renderPaneLines(pane) {
    if (!pane.data) return;
    const body = $('.log-lines', pane.node);
    if (pane.data.binary) {
      body.innerHTML = '<div class="pane-message">Binary file — use download to inspect it.</div>';
      return;
    }
    const query = pane.query.trim();
    const re = query ? new RegExp(escapeRe(query), 'gi') : null;
    const test = query ? new RegExp(escapeRe(query), 'i') : null;
    const html = [];
    for (let i = 0; i < pane.lines.length; i += 1) {
      const lvl = pane.levels[i];
      if (pane.level === 'err' && lvl !== 'err') continue;
      if (pane.level === 'issues' && !lvl) continue;
      const line = pane.lines[i];
      if (pane.only && test && !test.test(line)) continue;
      html.push(`<div class="ln ${lvl}"><span class="no">${i + 1}</span><span class="tx">${highlight(line, re) || ' '}</span></div>`);
    }
    body.innerHTML = html.length
      ? html.join('')
      : `<div class="pane-message">${pane.lines.length ? 'No lines match the current filters.' : 'This file is empty.'}</div>`;
    pane.matchIdx = -1;
    pane.issueIdx = -1;
    const count = query ? body.querySelectorAll('mark').length : 0;
    $('.match-count', pane.node).textContent = query ? `${fmtNum(count)} match${count === 1 ? '' : 'es'}` : '';
    if (count) jumpMatch(pane, 1);
  }

  function jumpTo(pane, nodes, idxKey, dir, activeClass) {
    if (!nodes.length) return;
    nodes[pane[idxKey]]?.classList.remove(activeClass);
    pane[idxKey] = (pane[idxKey] + dir + nodes.length) % nodes.length;
    const target = nodes[pane[idxKey]];
    target.classList.add(activeClass);
    target.scrollIntoView({ block: 'center' });
    return pane[idxKey];
  }

  function jumpMatch(pane, dir) {
    const marks = pane.node.querySelectorAll('.log-lines mark');
    const idx = jumpTo(pane, marks, 'matchIdx', dir, 'current');
    if (idx != null) $('.match-count', pane.node).textContent = `${idx + 1} / ${fmtNum(marks.length)}`;
  }

  function jumpIssue(pane, dir) {
    const lines = pane.node.querySelectorAll('.log-lines .ln.err, .log-lines .ln.warn');
    if (!lines.length) { toast('No errors or warnings in this view', 'info'); return; }
    jumpTo(pane, lines, 'issueIdx', dir, 'focus');
  }

  function renderViewer() {
    const grid = $('#viewerGrid');
    const count = state.panes.length;
    const cols = Math.max(1, Math.min(state.columns, count || 1));
    grid.style.setProperty('--cols', cols);
    document.querySelectorAll('.segmented button').forEach((b) => b.classList.toggle('on', Number(b.dataset.cols) === state.columns));
    $('#closeAllBtn').disabled = !count;
    $('#viewerHint').textContent = count
      ? `${count} of ${MAX_PANES} logs open`
      : `${state.archives.size} bundle(s) selected — pick a log file to open`;

    if (!count) {
      grid.replaceChildren(
        el('div', { class: 'viewer-empty' },
          el('div', { class: 'viewer-empty-icon' }, svgIcon('M7 3h7l5 5v13H7zM14 3v5h5M10 13h6M10 17h6')),
          el('strong', { text: state.archives.size ? 'Pick a log file from the list' : 'Upload or select log bundles' }),
          el('span', { class: 'muted', text: 'Errors are highlighted red, warnings amber. Use the arrows in a pane to jump between them.' }))
      );
      return;
    }
    grid.querySelector('.viewer-empty')?.remove();
    for (const pane of state.panes) if (pane.node.parentNode !== grid) grid.append(pane.node);
  }

  // ---------- upload ----------
  function uploadFiles(fileList) {
    const files = [...fileList].filter((f) => /\.(tgz|tar\.gz)$/i.test(f.name));
    const skipped = fileList.length - files.length;
    if (skipped) toast(`Skipped ${skipped} file(s): only .tgz / .tar.gz are accepted`, 'error');
    if (!files.length) return;

    const form = new FormData();
    files.forEach((f) => form.append('archives', f, f.name));
    const progress = $('#uploadProgress');
    const bar = $('.upload-progress-bar', progress);
    const label = $('.upload-progress-label', progress);
    progress.hidden = false;
    bar.style.width = '0%';
    label.textContent = `Uploading ${files.length} file(s)…`;

    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/api/upload');
    xhr.upload.onprogress = (e) => {
      if (!e.lengthComputable) return;
      const pct = Math.round((e.loaded / e.total) * 100);
      bar.style.width = `${pct}%`;
      label.textContent = pct < 100 ? `Uploading… ${pct}%` : 'Processing…';
    };
    xhr.onloadend = async () => {
      progress.hidden = true;
      let data = {};
      try { data = JSON.parse(xhr.responseText || '{}'); } catch { /* non-JSON error page */ }
      if (xhr.status === 0) { toast('Upload failed: network error', 'error'); return; }
      (data.rejected || []).forEach((r) => toast(`${r.name}: ${r.reason}`, 'error'));
      if (data.error) toast(`Upload failed: ${data.error}`, 'error');
      if (data.saved?.length) {
        toast(`Uploaded ${data.saved.length} bundle(s)`, 'success');
        await loadCatalog();
        const entry = findArchive(data.saved[0]);
        if (entry) { selectMac(entry.mac); state.archives.clear(); state.archives.add(entry.archive); renderAll(); }
      }
    };
    xhr.send(form);
  }

  // ---------- URL state ----------
  function saveHash() {
    const params = new URLSearchParams();
    if (state.mac) params.set('mac', state.mac);
    for (const archive of state.archives) params.append('archive', archive);
    state.panes.forEach((p) => params.append('open', keyOf(p.archive, p.path)));
    history.replaceState(null, '', `#${params}`);
  }

  function restoreHash() {
    const params = new URLSearchParams(location.hash.slice(1));
    const mac = params.get('mac');
    const archives = params.getAll('archive');
    if (mac && state.catalog.macs.includes(mac)) state.mac = mac;
    const validArchives = archivesForMac(state.mac).map(a => a.archive);
    state.archives = new Set(archives.filter(a => validArchives.includes(a)));
    if (state.archives.size === 0 && validArchives.length > 0) {
      state.archives.add(validArchives[0]);
    }
    renderAll();
    for (const archive of state.archives) ensureSummary(archive);
    for (const key of params.getAll('open')) {
      const idx = key.indexOf('::');
      const entry = findArchive(key.slice(0, idx));
      const path = key.slice(idx + 2);
      if (entry && entry.log_files.includes(path)) openPane(entry.archive, path);
    }
  }

  // ---------- wiring ----------
  function wire() {
    $('#deviceSelect').addEventListener('change', (e) => { selectMac(e.target.value || null); });
    $('#fileInput').addEventListener('change', (e) => { uploadFiles(e.target.files); e.target.value = ''; });
    $('#refreshBtn').addEventListener('click', () => { state.summaries.clear(); loadCatalog(); });
    $('#themeBtn').addEventListener('click', () => {
      const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
      document.documentElement.dataset.theme = next;
      localStorage.setItem('theme', next);
    });
    $('#sidebarToggleBtn').addEventListener('click', () => {
      state.sidebarVisible = !state.sidebarVisible;
      document.querySelector('.sidebar').classList.toggle('hidden', !state.sidebarVisible);
      localStorage.setItem('sidebarVisible', state.sidebarVisible);
    });
    // Restore sidebar visibility
    if (localStorage.getItem('sidebarVisible') === 'false') {
      state.sidebarVisible = false;
      document.querySelector('.sidebar').classList.add('hidden');
    }
    const search = $('#fileSearch');
    search.addEventListener('input', debounce(() => { state.fileQuery = search.value.trim(); renderFiles(); }, 100));
    $('#hideEmpty').addEventListener('change', (e) => { state.hideEmpty = e.target.checked; renderFiles(); });
    $('#issuesOnly').addEventListener('change', (e) => { state.issuesOnly = e.target.checked; renderFiles(); });
    $('#fileSort').addEventListener('change', (e) => { state.sort = e.target.value; renderFiles(); });
    $('#closeAllBtn').addEventListener('click', () => {
      [...state.panes].forEach((p) => closePane(p, false));
      renderViewer(); renderFiles(); saveHash();
    });
    document.querySelectorAll('.segmented button').forEach((b) =>
      b.addEventListener('click', () => {
        state.columns = Number(b.dataset.cols);
        localStorage.setItem('columns', state.columns);
        renderViewer();
      }));

    document.addEventListener('keydown', (e) => {
      const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName);
      if (e.key === '/' && !typing) { e.preventDefault(); search.focus(); }
    });

    const overlay = $('#dropOverlay');
    let depth = 0;
    const hasFiles = (e) => [...(e.dataTransfer?.types || [])].includes('Files');
    window.addEventListener('dragenter', (e) => { if (!hasFiles(e)) return; depth += 1; overlay.hidden = false; });
    window.addEventListener('dragleave', () => { depth = Math.max(0, depth - 1); if (!depth) overlay.hidden = true; });
    window.addEventListener('dragover', (e) => { if (hasFiles(e)) e.preventDefault(); });
    window.addEventListener('drop', (e) => {
      if (!hasFiles(e)) return;
      e.preventDefault();
      depth = 0;
      overlay.hidden = true;
      uploadFiles(e.dataTransfer.files);
    });
  }

  wire();
  api('/api/catalog')
    .then((catalog) => {
      state.catalog = catalog;
      state.mac = catalog.macs[0] || null;
      const firstArchive = archivesForMac(state.mac)[0]?.archive || null;
      if (firstArchive) state.archives.add(firstArchive);
      restoreHash();
    })
    .catch((err) => {
      renderAll();
      toast(`Failed to load catalog: ${err.message}`, 'error');
    });
})();
