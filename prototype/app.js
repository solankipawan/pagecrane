/* ==========================================================================
   PDFit prototype — app logic (vanilla JS, no build step)
   Sections map 1:1 to the Flutter feature modules in docs/ARCHITECTURE.md:
     core/      utils, haptics, sheet, toast, PDF engine
     dashboard/ home + storage            files/    list, search, sort, folders
     scanner/   camera, edge detection, perspective warp, filters, review, save
     pdf_tools/ merge, compress           image_tools/ target-size, resize, img→pdf
   ========================================================================== */
(() => {
  'use strict';

  /* ------------------------------------------------------------------ core */
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const ic = (name, cls = '') => `<i data-lucide="${name}"${cls ? ` class="${cls}"` : ''}></i>`;
  const icons = () => { if (window.lucide) window.lucide.createIcons({ attrs: { 'stroke-width': 1.75 } }); };
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
  const plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`;
  // Decimal units (1 KB = 1,000 B) and floor rounding, so "99.9 KB" really is under a 100 KB upload limit.
  const fmtSize = (b) => {
    if (b < 1000) return `${b} B`;
    if (b < 1e6) { const k = b / 1000; return k < 100 ? `${Math.floor(k * 10) / 10} KB` : `${Math.floor(k)} KB`; }
    return `${(Math.floor(b / 1e5) / 10).toFixed(1)} MB`;
  };
  const fmtDate = (t) => {
    const now = new Date();
    const start = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    if (t >= start) return new Date(t).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
    if (t >= start - 864e5) return 'Yesterday';
    return new Date(t).toLocaleDateString([], { day: 'numeric', month: 'short' });
  };
  const mkCanvas = (w, h) => { const c = document.createElement('canvas'); c.width = w; c.height = h; return c; };
  const toBlob = (c, type, q) => new Promise((r) => c.toBlob(r, type, q));
  const nextFrame = () => new Promise((r) => requestAnimationFrame(() => setTimeout(r, 0)));
  const store = {
    get(k, d) { try { const v = localStorage.getItem(k); return v ? JSON.parse(v) : d; } catch { return d; } },
    set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch { /* storage blocked: settings stay in memory */ } },
  };

  const settings = Object.assign({ theme: 'system', autoCapture: true, haptics: true, defaultFilter: 'magic' }, store.get('pdfit.settings', {}));
  const saveSettings = () => store.set('pdfit.settings', settings);

  function haptic(kind = 'light') {
    if (!settings.haptics || !navigator.vibrate) return;
    if (navigator.userActivation && !navigator.userActivation.hasBeenActive) return; // browsers block vibrate before a tap
    const p = { select: 6, light: 12, medium: 20, success: [12, 50, 20], warn: [30, 40, 30] }[kind] ?? 10;
    try { navigator.vibrate(p); } catch { /* not supported */ }
  }

  let toastTimer;
  function toast(msg, iconName = 'circle-check') {
    const t = $('#toast');
    t.innerHTML = `${ic(iconName)}<span>${esc(msg)}</span>`;
    icons();
    t.classList.add('on');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.classList.remove('on'), 2600);
  }

  let sheetOnClose = null;
  function openSheet(html, onMount, onClose) {
    // Fresh body node each time so listeners from a previous sheet never leak.
    const old = $('#sheetBody');
    const body = old.cloneNode(false);
    old.replaceWith(body);
    body.innerHTML = html;
    icons();
    $('#scrim').classList.add('on');
    $('#sheet').classList.add('open');
    sheetOnClose = onClose || null;
    if (onMount) onMount(body);
  }
  function closeSheet() {
    if (!$('#sheet').classList.contains('open')) return;
    $('#scrim').classList.remove('on');
    $('#sheet').classList.remove('open');
    const f = sheetOnClose; sheetOnClose = null;
    if (f) f();
  }
  const sheetHead = (title, sub, iconName, cat) =>
    `<div class="sheet-head"><span class="ti c-${cat}">${ic(iconName)}</span><div><h2>${title}</h2><p>${sub}</p></div></div>`;

  function setProgress(box, k) { box.hidden = false; box.firstElementChild.style.width = `${clamp(k, 0, 1) * 100}%`; }
  function fakeProgress(box, ms) {
    const t0 = performance.now();
    return new Promise((res) => {
      const step = (t) => { const k = Math.min(1, (t - t0) / ms); setProgress(box, k); if (k < 1) requestAnimationFrame(step); else setTimeout(res, 120); };
      requestAnimationFrame(step);
    });
  }

  /* PDF engine: jsPDF, lazy-loaded the first time a PDF is built. */
  let jsPdfPromise = null;
  function loadJsPDF() {
    jsPdfPromise ??= new Promise((res, rej) => {
      const s = document.createElement('script');
      s.src = 'https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js';
      s.onload = () => res(window.jspdf.jsPDF);
      s.onerror = () => { jsPdfPromise = null; rej(new Error('jsPDF failed to load')); };
      document.head.appendChild(s);
    });
    return jsPdfPromise;
  }
  async function buildPdf(canvases) {
    const JsPDF = await loadJsPDF();
    let pdf;
    canvases.forEach((c, i) => {
      const w = 595, h = Math.round((595 * c.height) / c.width), o = w > h ? 'l' : 'p';
      if (i === 0) pdf = new JsPDF({ unit: 'pt', format: [w, h], orientation: o, compress: true });
      else pdf.addPage([w, h], o);
      pdf.addImage(c.toDataURL('image/jpeg', 0.85), 'JPEG', 0, 0, w, h, undefined, 'FAST');
    });
    return pdf.output('blob');
  }
  async function shareOrDownload(blob, filename) {
    const file = new File([blob], filename, { type: blob.type });
    if (navigator.canShare && navigator.canShare({ files: [file] })) {
      try { await navigator.share({ files: [file], title: filename }); return 'shared'; }
      catch (e) { if (e.name === 'AbortError') return 'cancelled'; }
    }
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = filename;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 5000);
    return 'downloaded';
  }
  const safeName = (s) => s.replace(/[\\/:*?"<>|]+/g, '-').trim() || 'document';
  async function exportPdf(d) {
    try {
      toast('Building PDF…', 'loader');
      const blob = await buildPdf(d.canvases);
      const r = await shareOrDownload(blob, `${safeName(d.name)}.pdf`);
      if (r !== 'cancelled') toast(r === 'shared' ? 'Shared' : `Downloaded · ${fmtSize(blob.size)}`);
    } catch {
      toast('PDF engine failed to load (offline?)', 'triangle-alert');
    }
  }

  /* ------------------------------------------------------------ data model */
  function makeThumb(color, kind, seed) {
    const c = mkCanvas(84, 108), x = c.getContext('2d');
    if (kind === 'img') {
      const g = x.createLinearGradient(0, 0, 0, 108);
      g.addColorStop(0, '#a9c8ff'); g.addColorStop(1, '#ffd9b0');
      x.fillStyle = g; x.fillRect(0, 0, 84, 108);
      x.fillStyle = 'rgba(255,255,255,.85)'; x.beginPath(); x.arc(42, 46, 16, 0, Math.PI * 2); x.fill();
      x.fillStyle = color; x.beginPath(); x.ellipse(42, 112, 34, 36, 0, Math.PI, 0); x.fill();
      return c.toDataURL();
    }
    x.fillStyle = '#fff'; x.fillRect(0, 0, 84, 108);
    x.fillStyle = color; x.fillRect(0, 0, 84, 18);
    x.fillStyle = '#d6d9e3';
    let r = seed;
    for (let y = 28; y < 100; y += 8) { r = (r * 9301 + 49297) % 233280; x.fillRect(10, y, 30 + (r / 233280) * 42, 3); }
    return c.toDataURL();
  }

  const NOW = Date.now(), HR = 36e5, DAY = 864e5;
  const docs = [
    { id: 'd1', name: 'Rental Agreement 2026', kind: 'pdf', pages: 12, size: 2480000, date: NOW - 2 * HR, folder: 'Legal', starred: true, color: '#4c5bff' },
    { id: 'd2', name: 'Passport Scan', kind: 'pdf', pages: 2, size: 640000, date: NOW - DAY - 5 * HR, folder: 'ID', starred: true, color: '#0d9488' },
    { id: 'd3', name: 'Electricity Bill — Oct', kind: 'pdf', pages: 3, size: 1120000, date: NOW - 3 * DAY, folder: 'Bills', starred: false, color: '#d97706' },
    { id: 'd4', name: 'Profile Photo (under 100 KB)', kind: 'img', pages: 1, size: 98400, date: NOW - 5 * DAY, folder: 'Forms', starred: false, color: '#7c3aed' },
    { id: 'd5', name: 'Lecture Notes Week 7', kind: 'pdf', pages: 18, size: 5900000, date: NOW - 8 * DAY, folder: 'Study', starred: false, color: '#e11d48' },
    { id: 'd6', name: 'Invoice INV-2026-114', kind: 'pdf', pages: 1, size: 212000, date: NOW - 12 * DAY, folder: 'Bills', starred: false, color: '#16a34a' },
  ].map((d, i) => ({ ...d, thumb: makeThumb(d.color, d.kind, i * 17 + 5), sample: true }));
  let savedByCompress = 3400000;

  const TOOLS = {
    scan: { label: 'Scan', name: 'Document scanner', icon: 'scan-line', cat: 'scan', desc: 'Camera to PDF with auto-crop' },
    merge: { label: 'Merge', name: 'Merge PDFs', icon: 'layers', cat: 'pdf', desc: 'Combine files, drag to reorder' },
    split: { label: 'Split', name: 'Split PDF', icon: 'scissors', cat: 'pdf', desc: 'Extract pages or ranges', native: true },
    compress: { label: 'Compress', name: 'Compress PDF', icon: 'minimize-2', cat: 'pdf', desc: 'Low · Medium · High, size preview' },
    sign: { label: 'Sign', name: 'Sign & annotate', icon: 'pen-line', cat: 'pdf', desc: 'Signature, highlight, comments', native: true },
    target: { label: 'Under KB', name: 'Compress to size', icon: 'gauge', cat: 'image', desc: 'Hit limits like “under 100 KB”' },
    resize: { label: 'Resize', name: 'Resize image', icon: 'scaling', cat: 'image', desc: 'Pixels / %, format, quality' },
    convert: { label: 'To PDF', name: 'Images to PDF', icon: 'arrow-left-right', cat: 'convert', desc: 'JPG / PNG / WebP to PDF' },
    pdf2img: { label: 'PDF → JPG', name: 'PDF to images', icon: 'image', cat: 'convert', desc: 'Export pages as JPG / PNG', native: true },
    heic: { label: 'HEIC', name: 'HEIC to JPG', icon: 'file-image', cat: 'convert', desc: 'Convert iPhone photos', native: true },
  };
  const QUICK = ['scan', 'merge', 'split', 'compress', 'resize', 'target', 'convert', 'sign'];

  function openTool(id) {
    const t = TOOLS[id];
    if (!t) return;
    haptic('select');
    if (id === 'scan') return Scanner.open();
    if (t.native) return toast(`${t.name} ships in the native build`, 'info');
    const map = { merge: openMerge, compress: () => openCompress(), target: () => openImageTool('target'), resize: () => openImageTool('resize'), convert: openConvert };
    map[id]();
  }

  /* -------------------------------------------------------------- theming */
  const mqDark = window.matchMedia('(prefers-color-scheme: dark)');
  const isDark = () => (settings.theme === 'system' ? mqDark.matches : settings.theme === 'dark');
  function applyTheme() {
    if (settings.theme === 'system') document.documentElement.removeAttribute('data-theme');
    else document.documentElement.setAttribute('data-theme', settings.theme);
    $('#themeQuick').innerHTML = ic(isDark() ? 'sun' : 'moon');
    $$('#themeSeg button').forEach((b) => b.classList.toggle('on', b.dataset.theme === settings.theme));
    icons();
  }
  mqDark.addEventListener?.('change', applyTheme);

  /* ------------------------------------------------------------ dashboard */
  function docRow(d) {
    const [tag, cat] = d.kind === 'pdf' ? ['PDF', 'pdf'] : ['IMG', 'image'];
    const pages = d.kind === 'pdf' ? `${plural(d.pages, 'page')} · ` : '';
    return `<button class="doc-row${d.isNew ? ' new' : ''}" data-doc="${d.id}">
      <img class="doc-thumb" src="${d.thumb}" alt="">
      <span class="doc-meta"><span class="doc-name">${esc(d.name)}</span>
      <span class="doc-sub"><span class="kind-tag c-${cat}">${tag}</span>${pages}${fmtSize(d.size)} · ${fmtDate(d.date)}</span></span>
      ${d.starred ? ic('star', 'star') : ''}${ic('ellipsis', 'more')}</button>`;
  }
  const skeletonRows = (n) => Array(n).fill('<div class="sk-row"><div class="sk t"></div><div class="lines"><div class="sk l1"></div><div class="sk l2"></div></div></div>').join('');

  function renderHome(skeleton) {
    $('#stDocs').textContent = docs.length;
    $('#stPages').textContent = docs.reduce((a, d) => a + d.pages, 0);
    $('#stSaved').textContent = fmtSize(savedByCompress);
    const recents = [...docs].sort((a, b) => b.date - a.date).slice(0, 4);
    $('#recents').innerHTML = skeleton
      ? skeletonRows(3)
      : recents.length ? recents.map(docRow).join('') : '<div class="empty">No documents yet. Tap the scan button to start.</div>';
    renderStorage();
    icons();
  }
  function renderStorage() {
    const by = { pdf: 0, scans: 0, image: 0 };
    docs.forEach((d) => { if (!d.sample) by.scans += d.size; else if (d.kind === 'pdf') by.pdf += d.size; else by.image += d.size; });
    const total = by.pdf + by.scans + by.image;
    const pct = (v) => (total ? ((v / total) * 100).toFixed(1) : 0);
    $('#storage').innerHTML = `
      <div class="storage-top"><span>Used by PDFit · on device</span><b>${fmtSize(total)}</b></div>
      <div class="bar"><i style="width:${pct(by.pdf)}%;background:var(--pdf)"></i><i style="width:${pct(by.scans)}%;background:var(--scan)"></i><i style="width:${pct(by.image)}%;background:var(--image)"></i></div>
      <div class="legend"><span class="c-pdf">PDFs ${fmtSize(by.pdf)}</span><span class="c-scan">Scans ${fmtSize(by.scans)}</span><span class="c-image">Images ${fmtSize(by.image)}</span></div>`;
  }
  function renderQuickTools() {
    $('#quickTools').innerHTML = QUICK.map((id) => {
      const t = TOOLS[id];
      return `<button class="tool glass c-${t.cat}" data-tool="${id}"><span class="ti">${ic(t.icon)}</span>${t.label}</button>`;
    }).join('');
  }

  /* ---------------------------------------------------------------- files */
  const filesState = { view: 'all', q: '', sort: 'date', folder: null };
  function renderFiles() {
    const body = $('#filesBody');
    $$('#filesSeg button').forEach((b) => b.classList.toggle('on', b.dataset.view === filesState.view));
    if (filesState.view === 'folders' && !filesState.folder && !filesState.q) {
      const folders = {};
      docs.forEach((d) => (folders[d.folder] ??= []).push(d));
      body.innerHTML = `<div class="folders">${Object.entries(folders).map(([f, list]) => `
        <button class="folder glass pressable" data-folder="${esc(f)}">${ic('folder')}
          <div><b>${esc(f)}</b><span>${plural(list.length, 'file')} · ${fmtSize(list.reduce((a, d) => a + d.size, 0))}</span></div>
        </button>`).join('')}</div>`;
      icons();
      return;
    }
    const q = filesState.q.toLowerCase();
    const list = docs.filter((d) => (filesState.view !== 'starred' || d.starred)
      && (!filesState.folder || d.folder === filesState.folder)
      && (d.name.toLowerCase().includes(q) || d.folder.toLowerCase().includes(q)));
    const s = filesState.sort;
    list.sort((a, b) => (s === 'name' ? a.name.localeCompare(b.name) : s === 'size' ? b.size - a.size : b.date - a.date));
    body.innerHTML = (filesState.folder ? `<button class="chip filter-pill" id="clearFolder">${ic('folder-open')}${esc(filesState.folder)}${ic('x')}</button>` : '')
      + (list.length
        ? `<div class="list glass">${list.map(docRow).join('')}</div>`
        : `<div class="empty">${filesState.q ? `No results for “${esc(filesState.q)}”` : 'Nothing here yet'}</div>`);
    icons();
  }

  function refreshAll() {
    renderHome(false);
    renderFiles();
    setTimeout(() => docs.forEach((d) => { d.isNew = false; }), 2000);
  }

  function openDocSheet(id) {
    const d = docs.find((x) => x.id === id);
    if (!d) return;
    haptic('select');
    const isPdf = d.kind === 'pdf';
    openSheet(`${sheetHead(esc(d.name), `${isPdf ? `${plural(d.pages, 'page')} · ` : ''}${fmtSize(d.size)} · ${esc(d.folder)}`, isPdf ? 'file-text' : 'image', isPdf ? 'pdf' : 'image')}
      <div class="btn-col">
        <button class="btn primary" data-act="export">${ic('share')}Export / share as PDF</button>
        <button class="btn ghost" data-act="star">${ic('star')}${d.starred ? 'Remove star' : 'Star'}</button>
        ${isPdf ? `<button class="btn ghost" data-act="compress">${ic('minimize-2')}Compress</button>` : ''}
        <button class="btn danger" data-act="delete">${ic('trash-2')}Delete</button>
      </div>
      ${d.sample ? '<p class="note">This is sample data. Scan a document to try real PDF export.</p>' : ''}`, (body) => {
      body.addEventListener('click', async (e) => {
        const act = e.target.closest('[data-act]')?.dataset.act;
        if (act === 'star') { d.starred = !d.starred; haptic('select'); closeSheet(); refreshAll(); }
        if (act === 'delete') { docs.splice(docs.indexOf(d), 1); haptic('warn'); closeSheet(); refreshAll(); toast(`Deleted “${d.name}”`, 'trash-2'); }
        if (act === 'compress') { closeSheet(); setTimeout(() => openCompress(d.id), 260); }
        if (act === 'export') {
          if (!d.canvases) return toast('Sample file: nothing to export', 'info');
          closeSheet();
          await exportPdf(d);
        }
      });
    });
  }

  /* ------------------------------------------------------------ pdf_tools */
  function enableDragReorder(list, onDrop) {
    const renumber = () => $$('.merge-item .ord', list).forEach((o, i) => { o.textContent = i + 1; });
    list.addEventListener('pointerdown', (e) => {
      const handle = e.target.closest('.handle');
      if (!handle) return;
      const item = handle.closest('.merge-item');
      e.preventDefault();
      let startY = e.clientY;
      item.classList.add('dragging');
      haptic('light');
      const move = (ev) => {
        let dy = ev.clientY - startY;
        const prev = item.previousElementSibling, next = item.nextElementSibling;
        if (next && dy > next.offsetHeight / 2 + 4) {
          next.after(item); startY += next.offsetHeight + 8; dy = ev.clientY - startY; renumber(); haptic('select');
        } else if (prev && dy < -(prev.offsetHeight / 2 + 4)) {
          prev.before(item); startY -= prev.offsetHeight + 8; dy = ev.clientY - startY; renumber(); haptic('select');
        }
        item.style.transform = `translateY(${dy}px)`;
      };
      const up = () => {
        window.removeEventListener('pointermove', move);
        window.removeEventListener('pointerup', up);
        window.removeEventListener('pointercancel', up);
        item.classList.remove('dragging');
        item.style.transform = '';
        onDrop();
      };
      window.addEventListener('pointermove', move);
      window.addEventListener('pointerup', up);
      window.addEventListener('pointercancel', up);
    });
  }

  function openMerge() {
    const pdfs = docs.filter((d) => d.kind === 'pdf').slice(0, 5);
    if (pdfs.length < 2) return toast('You need at least 2 PDFs to merge', 'info');
    let order = pdfs.map((d) => d.id);
    const render = (body) => {
      const list = order.map((id) => docs.find((d) => d.id === id));
      const pages = list.reduce((a, d) => a + d.pages, 0);
      body.querySelector('#mergeList').innerHTML = list.map((d, i) => `
        <div class="merge-item" data-id="${d.id}">
          <span class="ord">${i + 1}</span>
          <img class="doc-thumb" src="${d.thumb}" alt="">
          <span class="doc-meta"><span class="doc-name">${esc(d.name)}</span><span class="doc-sub">${plural(d.pages, 'page')} · ${fmtSize(d.size)}</span></span>
          <button class="icon-btn" data-remove="${d.id}" aria-label="Remove ${esc(d.name)}">${ic('x')}</button>
          <span class="handle" aria-label="Drag to reorder">${ic('grip-vertical')}</span>
        </div>`).join('');
      const go = body.querySelector('#mergeGo');
      go.innerHTML = `${ic('layers')}Merge ${plural(list.length, 'file')} · ${pages} pages`;
      go.disabled = list.length < 2;
      icons();
    };
    openSheet(`${sheetHead('Merge PDFs', 'Drag the handles to set the order', 'layers', 'pdf')}
      <div class="merge-list" id="mergeList"></div>
      <div class="progress" id="mergeProg" hidden><i></i></div>
      <div class="btn-row"><button class="btn primary" id="mergeGo"></button></div>
      <p class="note">Prototype: sample files and a simulated merge. The native build merges with syncfusion_flutter_pdf on a background isolate.</p>`, (body) => {
      render(body);
      const listEl = body.querySelector('#mergeList');
      listEl.addEventListener('click', (e) => {
        const r = e.target.closest('[data-remove]');
        if (r) { order = order.filter((id) => id !== r.dataset.remove); haptic('select'); render(body); }
      });
      enableDragReorder(listEl, () => { order = $$('.merge-item', listEl).map((el) => el.dataset.id); render(body); });
      body.querySelector('#mergeGo').addEventListener('click', async (e) => {
        e.currentTarget.disabled = true;
        const list = order.map((id) => docs.find((d) => d.id === id));
        await fakeProgress(body.querySelector('#mergeProg'), 1100);
        const merged = {
          id: `m${Date.now()}`, name: `Merged — ${list[0].name}`, kind: 'pdf',
          pages: list.reduce((a, d) => a + d.pages, 0), size: Math.round(list.reduce((a, d) => a + d.size, 0) * 0.96),
          date: Date.now(), folder: list[0].folder, starred: false, thumb: list[0].thumb, sample: true, isNew: true,
        };
        docs.unshift(merged);
        haptic('success'); closeSheet(); setTab('home'); refreshAll();
        toast(`Merged ${plural(list.length, 'file')} · ${merged.pages} pages`);
      });
    });
  }

  // Levels from ARCHITECTURE.md §5: quality + resolution scale per level.
  const LEVELS = [
    { id: 'low', label: 'Low', sub: 'Best quality · ~200 DPI', q: 0.82, scale: 1, ratio: 0.78 },
    { id: 'medium', label: 'Medium', sub: 'Recommended · ~150 DPI', q: 0.62, scale: 0.75, ratio: 0.52 },
    { id: 'high', label: 'High', sub: 'Smallest · ~110 DPI', q: 0.42, scale: 0.55, ratio: 0.31 },
  ];
  const scaleCanvas = (c, s) => {
    if (s === 1) return c;
    const o = mkCanvas(Math.max(1, Math.round(c.width * s)), Math.max(1, Math.round(c.height * s)));
    const x = o.getContext('2d'); x.imageSmoothingQuality = 'high'; x.drawImage(c, 0, 0, o.width, o.height);
    return o;
  };
  // Real docs: encode page 1 at each level and scale by page count (the sampling estimate).
  // Sample docs: heuristic ratio, since there are no real bytes behind them.
  async function estimateLevels(d) {
    if (!d.canvases) {
      return Object.fromEntries(LEVELS.map((l) => [l.id, Math.round(d.size * 0.15 + d.size * 0.85 * l.ratio)]));
    }
    if (d.estimates) return d.estimates;
    const out = {};
    for (const l of LEVELS) {
      const b = await toBlob(scaleCanvas(d.canvases[0], l.scale), 'image/jpeg', l.q);
      out[l.id] = Math.min(d.size, Math.round(b.size * d.canvases.length + 1500));
    }
    d.estimates = out;
    return out;
  }

  function openCompress(preId) {
    const pdfs = docs.filter((d) => d.kind === 'pdf');
    if (!pdfs.length) return toast('No PDFs yet', 'info');
    let sel = preId && pdfs.some((d) => d.id === preId) ? preId : [...pdfs].sort((a, b) => b.size - a.size)[0].id;
    let level = 'medium';
    let est = {};
    openSheet(`${sheetHead('Compress PDF', 'Original <b id="cmpOrig"></b>', 'minimize-2', 'pdf')}
      <div class="file-pick" id="cmpFiles"></div>
      <div class="levels" id="cmpLevels" role="radiogroup" aria-label="Compression level"></div>
      <div class="progress" id="cmpProg" hidden><i></i></div>
      <div class="btn-row"><button class="btn primary" id="cmpGo"></button></div>
      <p class="note" id="cmpNote"></p>`, (body) => {
      const $b = (s) => body.querySelector(s);
      let renderSeq = 0;
      const render = async (recalc) => {
        const seq = ++renderSeq;
        const d = docs.find((x) => x.id === sel);
        $b('#cmpOrig').textContent = fmtSize(d.size);
        $b('#cmpFiles').innerHTML = pdfs.map((p) => `<button class="chip${p.id === sel ? ' on' : ''}" data-file="${p.id}">${esc(p.name.length > 22 ? `${p.name.slice(0, 21)}…` : p.name)}</button>`).join('');
        if (recalc) {
          $b('#cmpLevels').innerHTML = LEVELS.map(() => '<div class="level"><div class="sk" style="height:38px;width:100%"></div></div>').join('');
          const fresh = await estimateLevels(d);
          if (seq !== renderSeq) return; // user picked another file meanwhile
          est = fresh;
        }
        $b('#cmpLevels').innerHTML = LEVELS.map((l) => {
          const e = est[l.id];
          return `<button class="level${l.id === level ? ' on' : ''}" data-level="${l.id}" role="radio" aria-checked="${l.id === level}">
            <span class="radio"></span><span class="lt"><b>${l.label}</b><span>${l.sub}</span></span>
            <span class="est"><b>~${fmtSize(e)}</b><span>−${Math.max(0, Math.round((1 - e / d.size) * 100))}%</span></span></button>`;
        }).join('');
        $b('#cmpGo').innerHTML = `${ic('minimize-2')}Compress to ~${fmtSize(est[level])}`;
        $b('#cmpNote').textContent = d.canvases
          ? 'Estimate: page 1 is encoded at each level, then scaled by page count.'
          : 'Sample file: estimates use typical ratios. Scan a document to see real numbers.';
        icons();
      };
      render(true);
      body.addEventListener('click', (e) => {
        const f = e.target.closest('[data-file]'); const l = e.target.closest('[data-level]');
        if (f) { sel = f.dataset.file; haptic('select'); render(true); }
        if (l) { level = l.dataset.level; haptic('select'); render(false); }
      });
      $b('#cmpGo').addEventListener('click', async (e) => {
        const d = docs.find((x) => x.id === sel), lv = LEVELS.find((x) => x.id === level), before = d.size;
        e.currentTarget.disabled = true;
        const prog = $b('#cmpProg');
        if (d.canvases) {
          let size = 1500; const out = [];
          for (let i = 0; i < d.canvases.length; i++) {
            const c = scaleCanvas(d.canvases[i], lv.scale);
            const b = await toBlob(c, 'image/jpeg', lv.q);
            // Keep the re-encoded pixels so a later export really is smaller.
            const img = await createImageBitmap(b);
            const kept = mkCanvas(img.width, img.height); kept.getContext('2d').drawImage(img, 0, 0);
            out.push(kept); size += b.size;
            setProgress(prog, (i + 1) / d.canvases.length);
          }
          if (size < before) { d.canvases = out; d.size = size; d.estimates = null; }
        } else {
          await fakeProgress(prog, 900);
          d.size = est[level];
        }
        d.date = Date.now(); d.isNew = true;
        const saved = Math.max(0, before - d.size);
        savedByCompress += saved;
        haptic('success'); closeSheet(); setTab('home'); refreshAll();
        toast(saved ? `Saved ${fmtSize(saved)} · now ${fmtSize(d.size)}` : 'Already optimal');
      });
    });
  }

  /* ---------------------------------------------------------- image_tools */
  function loadImage(file) {
    return new Promise((res, rej) => {
      const url = URL.createObjectURL(file);
      const im = new Image();
      im.onload = () => res(im);
      im.onerror = () => { URL.revokeObjectURL(url); rej(new Error('decode')); };
      im.src = url;
    });
  }
  function drawScaled(img, s, opaque) {
    const w = img.naturalWidth || img.width, h = img.naturalHeight || img.height;
    const c = mkCanvas(Math.max(1, Math.round(w * s)), Math.max(1, Math.round(h * s)));
    const x = c.getContext('2d');
    if (opaque) { x.fillStyle = '#fff'; x.fillRect(0, 0, c.width, c.height); } // JPEG has no alpha
    x.imageSmoothingQuality = 'high';
    x.drawImage(img, 0, 0, c.width, c.height);
    return c;
  }
  const fitCanvas = (img, max) => drawScaled(img, Math.min(1, max / Math.max(img.naturalWidth, img.naturalHeight)), true);

  // Binary search on JPEG quality; only shrink pixels when quality would drop too low.
  async function compressToTarget(img, targetBytes) {
    let fallback = null;
    for (let round = 0, scale = 1; round < 14 && scale > 0.05; round++, scale *= 0.85) {
      const c = drawScaled(img, scale, true);
      const top = await toBlob(c, 'image/jpeg', 0.92);
      if (top.size <= targetBytes) return { blob: top, w: c.width, h: c.height, q: 0.92 };
      let lo = 0.05, hi = 0.92, best = null, bestQ = 0;
      for (let k = 0; k < 7; k++) {
        const q = (lo + hi) / 2;
        const b = await toBlob(c, 'image/jpeg', q);
        if (b.size <= targetBytes) { best = b; bestQ = q; lo = q; } else hi = q;
      }
      if (best && bestQ >= 0.4) return { blob: best, w: c.width, h: c.height, q: bestQ };
      if (best && !fallback) fallback = { blob: best, w: c.width, h: c.height, q: bestQ };
    }
    return fallback;
  }

  function openImageTool(initialMode) {
    let mode = initialMode, img = null, fileName = 'image', origSize = 0;
    let target = 100000, pct = 100, quality = 85, fmt = 'image/jpeg', busy = false;
    const PRESETS = [20, 50, 100, 200, 500];
    openSheet(`${sheetHead('Image tools', 'Resize, recompress, hit an upload limit', 'scaling', 'image')}
      <div class="seg" id="imgMode"><button data-m="target">Target size</button><button data-m="resize">Dimensions</button></div>
      <div style="height:14px"></div>
      <label class="drop" id="imgDrop"><input type="file" accept="image/*" id="imgFile" hidden>${ic('image-plus')}<b>Choose an image</b><span>JPG, PNG, WebP · HEIC opens in Safari</span></label>
      <div id="imgInfo"></div>
      <div id="imgOpts"></div>
      <button class="btn primary" id="imgGo" disabled>${ic('sparkles')}Process</button>
      <div id="imgResult"></div>
      <p class="note">Runs fully in your browser. 1 KB = 1,000 bytes, which is safe for strict upload limits.</p>`, (body) => {
      const $b = (s) => body.querySelector(s);
      const dims = () => (img ? `${Math.max(1, Math.round(img.naturalWidth * pct / 100))} × ${Math.max(1, Math.round(img.naturalHeight * pct / 100))} px` : '—');
      const renderOpts = () => {
        $$('#imgMode button', body).forEach((b) => b.classList.toggle('on', b.dataset.m === mode));
        if (mode === 'target') {
          const custom = PRESETS.includes(target / 1000) ? '' : Math.round(target / 1000);
          $b('#imgOpts').innerHTML = `
            <div class="field">Target size<div class="chips">${PRESETS.map((k) => `<button class="chip${target === k * 1000 ? ' on' : ''}" data-k="${k}">${k} KB</button>`).join('')}</div></div>
            <label class="field">Custom (KB)<input class="input" id="tgtCustom" type="number" min="5" max="20000" inputmode="numeric" placeholder="e.g. 150" value="${custom}"></label>`;
        } else {
          $b('#imgOpts').innerHTML = `
            <div class="field">Scale<input class="range" type="range" id="pct" min="5" max="100" value="${pct}">
              <div class="range-row"><span id="pctLbl">${pct}%</span><span id="dimLbl">${dims()}</span></div></div>
            <div class="field">Format<div class="chips">${[['image/jpeg', 'JPG'], ['image/png', 'PNG'], ['image/webp', 'WebP']].map(([v, l]) => `<button class="chip${fmt === v ? ' on' : ''}" data-v="${v}">${l}</button>`).join('')}</div></div>
            <div class="field" ${fmt === 'image/png' ? 'hidden' : ''}>Quality<input class="range" type="range" id="qual" min="30" max="100" value="${quality}">
              <div class="range-row"><span>Smaller</span><span id="qLbl">${quality}%</span><span>Sharper</span></div></div>`;
        }
        $b('#imgGo').disabled = !img || busy;
        $b('#imgGo').innerHTML = busy ? `${ic('loader')}Working…` : `${ic('sparkles')}${mode === 'target' ? `Compress under ${Math.round(target / 1000)} KB` : 'Resize'}`;
        icons();
      };
      renderOpts();

      body.addEventListener('click', (e) => {
        const m = e.target.closest('[data-m]'), k = e.target.closest('[data-k]'), v = e.target.closest('[data-v]');
        if (m) { mode = m.dataset.m; haptic('select'); $b('#imgResult').innerHTML = ''; renderOpts(); }
        if (k) { target = Number(k.dataset.k) * 1000; haptic('select'); renderOpts(); }
        if (v) { fmt = v.dataset.v; haptic('select'); renderOpts(); }
      });
      body.addEventListener('input', (e) => {
        if (e.target.id === 'tgtCustom') {
          const n = Number(e.target.value);
          if (n >= 5) {
            target = n * 1000;
            $$('[data-k]', body).forEach((c) => c.classList.toggle('on', Number(c.dataset.k) * 1000 === target));
            $b('#imgGo').innerHTML = `${ic('sparkles')}Compress under ${n} KB`; icons();
          }
        }
        if (e.target.id === 'pct') { pct = Number(e.target.value); $b('#pctLbl').textContent = `${pct}%`; $b('#dimLbl').textContent = dims(); }
        if (e.target.id === 'qual') { quality = Number(e.target.value); $b('#qLbl').textContent = `${quality}%`; }
      });
      $b('#imgFile').addEventListener('change', async (e) => {
        const f = e.target.files[0];
        if (!f) return;
        try {
          img = await loadImage(f);
          fileName = f.name.replace(/\.[^.]+$/, '') || 'image';
          origSize = f.size;
          $b('#imgDrop').hidden = true;
          $b('#imgInfo').innerHTML = `<div class="img-preview"><img src="${img.src}" alt=""><span class="doc-meta"><span class="doc-name">${esc(f.name)}</span>
            <span class="doc-sub">${img.naturalWidth} × ${img.naturalHeight} px · ${fmtSize(f.size)}</span></span>
            <button class="icon-btn" id="imgSwap" aria-label="Choose another image">${ic('refresh-cw')}</button></div>`;
          $b('#imgSwap').onclick = () => $b('#imgFile').click();
          $b('#imgResult').innerHTML = '';
          renderOpts();
        } catch {
          toast('Could not read that image here', 'triangle-alert');
        }
      });
      $b('#imgGo').addEventListener('click', async () => {
        if (!img || busy) return;
        busy = true; renderOpts();
        await nextFrame();
        let r;
        if (mode === 'target') {
          r = await compressToTarget(img, target);
          if (r) { r.label = `JPEG quality ${Math.round(r.q * 100)}%${r.w < img.naturalWidth ? ' · downscaled to fit' : ''}`; r.name = `${fileName}-${Math.round(target / 1000)}KB.jpg`; }
        } else {
          const c = drawScaled(img, pct / 100, fmt === 'image/jpeg');
          const blob = await toBlob(c, fmt, quality / 100);
          const ext = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' }[fmt];
          r = blob && { blob, w: c.width, h: c.height, label: `${ext.toUpperCase()}${fmt === 'image/png' ? '' : ` · quality ${quality}%`}`, name: `${fileName}-${c.width}x${c.height}.${ext}` };
        }
        busy = false; renderOpts();
        if (!r) {
          $b('#imgResult').innerHTML = `<div class="result fail"><b>Can’t reach ${Math.round(target / 1000)} KB</b><p class="note">Even at a very small size it’s still too big. Try a larger target.</p></div>`;
          haptic('warn');
          return;
        }
        const saved = 1 - r.blob.size / origSize;
        $b('#imgResult').innerHTML = `<div class="result"><div class="result-top"><div><div class="eyebrow">New size</div><b>${fmtSize(r.blob.size)}</b></div>
          ${saved > 0 ? `<span class="badge-save">−${Math.round(saved * 100)}%</span>` : ''}</div>
          <p class="note" style="margin-top:6px">${r.w} × ${r.h} px · ${esc(r.label)}</p>
          <div class="btn-row"><button class="btn primary" id="imgDl">${ic('download')}Save image</button></div></div>`;
        icons();
        haptic('success');
        $b('#imgDl').onclick = () => shareOrDownload(r.blob, r.name);
      });
    });
  }

  function openConvert() {
    const items = [];
    openSheet(`${sheetHead('Images to PDF', 'Each image becomes one page, in order', 'arrow-left-right', 'convert')}
      <label class="drop"><input type="file" accept="image/*" multiple hidden id="convFile">${ic('images')}<b>Choose images</b><span>Pick several to build a multi-page PDF</span></label>
      <div class="conv-list" id="convList"></div>
      <button class="btn primary" id="convGo" disabled></button>
      <div class="progress" id="convProg" hidden><i></i></div>
      <p class="note">PDF → JPG and HEIC → JPG use native decoders (PDFium, ImageIO/HEIF) in the app build.</p>`, (body) => {
      const $b = (s) => body.querySelector(s);
      const render = () => {
        $b('#convList').innerHTML = items.map((it, i) => `
          <div class="merge-item"><span class="ord">${i + 1}</span><img class="doc-thumb" src="${it.thumb}" alt="">
            <span class="doc-meta"><span class="doc-name">${esc(it.name)}</span><span class="doc-sub">${it.w} × ${it.h} · ${fmtSize(it.size)}</span></span>
            <button class="icon-btn" data-rm="${i}" aria-label="Remove ${esc(it.name)}">${ic('x')}</button></div>`).join('');
        $b('#convGo').disabled = !items.length;
        $b('#convGo').innerHTML = `${ic('file-down')}Create PDF${items.length ? ` · ${plural(items.length, 'page')}` : ''}`;
        icons();
      };
      render();
      $b('#convFile').addEventListener('change', async (e) => {
        for (const f of e.target.files) {
          try {
            const img = await loadImage(f);
            const c = fitCanvas(img, 2000);
            items.push({ name: f.name, size: f.size, w: img.naturalWidth, h: img.naturalHeight, canvas: c, thumb: thumbURL(c, 100) });
          } catch { toast(`Could not read ${f.name}`, 'triangle-alert'); }
        }
        e.target.value = '';
        render();
      });
      body.addEventListener('click', (e) => {
        const rm = e.target.closest('[data-rm]');
        if (rm) { items.splice(Number(rm.dataset.rm), 1); haptic('select'); render(); }
      });
      $b('#convGo').addEventListener('click', async (e) => {
        const btn = e.currentTarget;
        btn.disabled = true;
        const prog = $b('#convProg');
        setProgress(prog, 0.25);
        try {
          const canvases = items.map((i) => i.canvas);
          const blob = await buildPdf(canvases);
          setProgress(prog, 1);
          const name = items.length === 1 ? items[0].name.replace(/\.[^.]+$/, '') : `Images to PDF ${new Date().toLocaleDateString([], { day: 'numeric', month: 'short' })}`;
          docs.unshift({ id: `c${Date.now()}`, name, kind: 'pdf', pages: canvases.length, size: blob.size, date: Date.now(), folder: 'Converted', starred: false, thumb: items[0].thumb, canvases, sample: false, isNew: true });
          closeSheet(); setTab('home'); refreshAll(); haptic('success');
          toast(`PDF created · ${fmtSize(blob.size)}`);
          shareOrDownload(blob, `${safeName(name)}.pdf`);
        } catch {
          prog.hidden = true;
          btn.disabled = false;
          toast('PDF engine failed to load (offline?)', 'triangle-alert');
        }
      });
    });
  }

  /* ================================================================ scanner
     Pipeline per frame: draw (camera | demo scene) → downscale to 160px →
     Otsu threshold → largest bright blob → 4 extreme corners → EMA smoothing
     → stability timer → auto-capture → perspective warp at full resolution.
     The native build replaces this with VisionKit / ML Kit (ARCHITECTURE §1). */

  // Square → quad projective mapping (Heckbert). Maps (u,v)∈[0,1]² to the quad TL,TR,BR,BL.
  function sq2quad([x0, y0], [x1, y1], [x2, y2], [x3, y3]) {
    const sx = x0 - x1 + x2 - x3, sy = y0 - y1 + y2 - y3;
    if (Math.abs(sx) < 1e-9 && Math.abs(sy) < 1e-9) return { a: x1 - x0, b: x3 - x0, c: x0, d: y1 - y0, e: y3 - y0, f: y0, g: 0, h: 0 };
    const dx1 = x1 - x2, dx2 = x3 - x2, dy1 = y1 - y2, dy2 = y3 - y2, den = dx1 * dy2 - dx2 * dy1;
    const g = (sx * dy2 - dx2 * sy) / den, h = (dx1 * sy - sx * dy1) / den;
    return { a: x1 - x0 + g * x1, b: x3 - x0 + h * x3, c: x0, d: y1 - y0 + g * y1, e: y3 - y0 + h * y3, f: y0, g, h };
  }

  function warp(img, q, maxDim = 1600) {
    const [p0, p1, p2, p3] = q;
    const dist = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1]);
    let ow = Math.max(dist(p0, p1), dist(p3, p2)), oh = Math.max(dist(p0, p3), dist(p1, p2));
    const k = Math.min(1, maxDim / Math.max(ow, oh));
    ow = Math.max(1, Math.round(ow * k)); oh = Math.max(1, Math.round(oh * k));
    const m = sq2quad(p0, p1, p2, p3);
    const out = new ImageData(ow, oh), od = out.data, sd = img.data, sw = img.width, sh = img.height;
    for (let y = 0, o = 0; y < oh; y++) {
      const v = (y + 0.5) / oh;
      for (let x = 0; x < ow; x++, o += 4) {
        const u = (x + 0.5) / ow;
        const den = m.g * u + m.h * v + 1;
        const sx = clamp((m.a * u + m.b * v + m.c) / den - 0.5, 0, sw - 1.001);
        const sy = clamp((m.d * u + m.e * v + m.f) / den - 0.5, 0, sh - 1.001);
        const x0 = sx | 0, y0 = sy | 0, fx = sx - x0, fy = sy - y0;
        const i00 = (y0 * sw + x0) * 4, i10 = i00 + 4, i01 = i00 + sw * 4, i11 = i01 + 4;
        for (let c = 0; c < 3; c++) { // bilinear
          const top = sd[i00 + c] + (sd[i10 + c] - sd[i00 + c]) * fx;
          const bot = sd[i01 + c] + (sd[i11 + c] - sd[i01 + c]) * fx;
          od[o + c] = top + (bot - top) * fy;
        }
        od[o + 3] = 255;
      }
    }
    const c = mkCanvas(ow, oh);
    c.getContext('2d').putImageData(out, 0, 0);
    return c;
  }

  function detectQuad(id) {
    const { data, width: w, height: h } = id, n = w * h;
    const g = new Uint8Array(n), hist = new Uint32Array(256);
    for (let i = 0, j = 0; i < n; i++, j += 4) { const v = (data[j] * 77 + data[j + 1] * 150 + data[j + 2] * 29) >> 8; g[i] = v; hist[v]++; }
    // Otsu threshold
    let sum = 0;
    for (let i = 0; i < 256; i++) sum += i * hist[i];
    let sumB = 0, wB = 0, best = 0, th = 128, mBack = 0, mFore = 0;
    for (let i = 0; i < 256; i++) {
      wB += hist[i]; if (!wB) continue;
      const wF = n - wB; if (!wF) break;
      sumB += i * hist[i];
      const mB = sumB / wB, mF = (sum - sumB) / wF, between = wB * wF * (mB - mF) ** 2;
      if (between > best) { best = between; th = i; mBack = mB; mFore = mF; }
    }
    if (mFore - mBack < 35) return null; // not enough contrast between page and background
    // Largest bright connected component (4-neighbour flood fill)
    const lab = new Int32Array(n), stack = new Int32Array(n);
    let cur = 0, bestLab = 0, bestSize = 0;
    for (let i = 0; i < n; i++) {
      if (g[i] <= th || lab[i]) continue;
      cur++; let sp = 0, size = 0;
      stack[sp++] = i; lab[i] = cur;
      while (sp) {
        const p = stack[--sp]; size++;
        const x = p % w;
        if (x > 0 && !lab[p - 1] && g[p - 1] > th) { lab[p - 1] = cur; stack[sp++] = p - 1; }
        if (x < w - 1 && !lab[p + 1] && g[p + 1] > th) { lab[p + 1] = cur; stack[sp++] = p + 1; }
        if (p >= w && !lab[p - w] && g[p - w] > th) { lab[p - w] = cur; stack[sp++] = p - w; }
        if (p < n - w && !lab[p + w] && g[p + w] > th) { lab[p + w] = cur; stack[sp++] = p + w; }
      }
      if (size > bestSize) { bestSize = size; bestLab = cur; }
    }
    const frac = bestSize / n;
    if (frac < 0.08 || frac > 0.9) return null;
    // Corners = extremes of x+y and x−y (valid for rotation < 45°)
    let tl, tr, br, bl, minS = Infinity, maxS = -Infinity, minD = Infinity, maxD = -Infinity;
    for (let i = 0; i < n; i++) {
      if (lab[i] !== bestLab) continue;
      const x = i % w, y = (i / w) | 0, s = x + y, d = x - y;
      if (s < minS) { minS = s; tl = [x, y]; }
      if (s > maxS) { maxS = s; br = [x, y]; }
      if (d > maxD) { maxD = d; tr = [x, y]; }
      if (d < minD) { minD = d; bl = [x, y]; }
    }
    const quad = [tl, tr, br, bl];
    let area = 0;
    for (let i = 0; i < 4; i++) { const [ax, ay] = quad[i], [bx, by] = quad[(i + 1) % 4]; area += ax * by - bx * ay; }
    area = Math.abs(area) / 2;
    // Blob must fill most of its quad (text holes allowed) → it really is a sheet.
    if (area < n * 0.08 || bestSize / area < 0.6) return null;
    return quad;
  }

  /* --- filters (ARCHITECTURE §5) --- */
  function percentiles(hist, n, a, b) {
    let acc = 0, lo = 0, hi = 255;
    for (let i = 0; i < 256; i++) { acc += hist[i]; if (acc >= n * a) { lo = i; break; } }
    acc = 0;
    for (let i = 255; i >= 0; i--) { acc += hist[i]; if (acc >= n * (1 - b)) { hi = i; break; } }
    return [lo, Math.max(lo + 1, hi)];
  }
  // Paper-brightness estimate: downscale, 5×5 max filter (drops ink), smooth upscale.
  function backgroundMap(src) {
    const w = src.width, h = src.height, bw = Math.max(4, Math.round(w / 28)), bh = Math.max(4, Math.round(h / 28));
    const s = mkCanvas(bw, bh), sx = s.getContext('2d', { willReadFrequently: true });
    sx.imageSmoothingQuality = 'high';
    sx.drawImage(src, 0, 0, bw, bh);
    const a = sx.getImageData(0, 0, bw, bh).data, out = new Uint8ClampedArray(a.length);
    for (let y = 0; y < bh; y++) {
      for (let x = 0; x < bw; x++) {
        const o = (y * bw + x) * 4;
        for (let c = 0; c < 3; c++) {
          let m = 0;
          for (let yy = Math.max(0, y - 2); yy <= Math.min(bh - 1, y + 2); yy++) {
            for (let xx = Math.max(0, x - 2); xx <= Math.min(bw - 1, x + 2); xx++) { const v = a[(yy * bw + xx) * 4 + c]; if (v > m) m = v; }
          }
          out[o + c] = m;
        }
        out[o + 3] = 255;
      }
    }
    sx.putImageData(new ImageData(out, bw, bh), 0, 0);
    const big = mkCanvas(w, h), bx = big.getContext('2d', { willReadFrequently: true });
    bx.imageSmoothingEnabled = true; bx.imageSmoothingQuality = 'high';
    bx.drawImage(s, 0, 0, w, h);
    return bx.getImageData(0, 0, w, h).data;
  }

  function applyFilter(src, f) {
    const w = src.width, h = src.height, c = mkCanvas(w, h), x = c.getContext('2d', { willReadFrequently: true });
    x.drawImage(src, 0, 0);
    if (f === 'original') return c;
    const id = x.getImageData(0, 0, w, h), d = id.data, n = w * h;
    if (f === 'magic' || f === 'bw') {
      const bg = backgroundMap(src);
      for (let i = 0; i < d.length; i += 4) {
        let r = (d[i] / Math.max(bg[i], 1)) * 255, g = (d[i + 1] / Math.max(bg[i + 1], 1)) * 255, b = (d[i + 2] / Math.max(bg[i + 2], 1)) * 255;
        if (f === 'bw') {
          const l = 0.299 * r + 0.587 * g + 0.114 * b, v = clamp((l - 150) * 4.2, 0, 255);
          d[i] = d[i + 1] = d[i + 2] = v;
        } else {
          r = (r - 128) * 1.18 + 140; g = (g - 128) * 1.18 + 140; b = (b - 128) * 1.18 + 140;
          const l = 0.299 * r + 0.587 * g + 0.114 * b;
          d[i] = l + (r - l) * 1.35; d[i + 1] = l + (g - l) * 1.35; d[i + 2] = l + (b - l) * 1.35;
        }
      }
    } else if (f === 'gray') {
      const lum = new Uint8Array(n), hist = new Uint32Array(256);
      for (let i = 0, j = 0; j < n; i += 4, j++) { const l = (d[i] * 77 + d[i + 1] * 150 + d[i + 2] * 29) >> 8; lum[j] = l; hist[l]++; }
      const [lo, hi] = percentiles(hist, n, 0.01, 0.99), s = 255 / (hi - lo);
      for (let i = 0, j = 0; j < n; i += 4, j++) { const v = (lum[j] - lo) * s; d[i] = d[i + 1] = d[i + 2] = v; }
    } else if (f === 'photo') {
      const hs = [new Uint32Array(256), new Uint32Array(256), new Uint32Array(256)];
      for (let i = 0; i < d.length; i += 4) { hs[0][d[i]]++; hs[1][d[i + 1]]++; hs[2][d[i + 2]]++; }
      const lv = hs.map((hh) => percentiles(hh, n, 0.005, 0.995));
      for (let i = 0; i < d.length; i += 4) {
        const r = ((d[i] - lv[0][0]) * 255) / (lv[0][1] - lv[0][0]);
        const g = ((d[i + 1] - lv[1][0]) * 255) / (lv[1][1] - lv[1][0]);
        const b = ((d[i + 2] - lv[2][0]) * 255) / (lv[2][1] - lv[2][0]);
        const l = 0.299 * r + 0.587 * g + 0.114 * b;
        d[i] = l + (r - l) * 1.12; d[i + 1] = l + (g - l) * 1.12; d[i + 2] = l + (b - l) * 1.12;
      }
    }
    x.putImageData(id, 0, 0);
    return c;
  }
  function rotateCanvas(c, deg) {
    const r = ((deg % 360) + 360) % 360;
    if (!r) return c;
    const sw = r % 180 ? c.height : c.width, sh = r % 180 ? c.width : c.height;
    const o = mkCanvas(sw, sh), x = o.getContext('2d');
    x.translate(sw / 2, sh / 2); x.rotate((r * Math.PI) / 180); x.drawImage(c, -c.width / 2, -c.height / 2);
    return o;
  }
  function renderPage(p) {
    if (!p.cache[p.filter]) p.cache[p.filter] = applyFilter(p.src, p.filter);
    return rotateCanvas(p.cache[p.filter], p.rot);
  }
  function thumbURL(c, max = 160) {
    const k = max / Math.max(c.width, c.height);
    const t = mkCanvas(Math.max(1, Math.round(c.width * k)), Math.max(1, Math.round(c.height * k)));
    const x = t.getContext('2d'); x.imageSmoothingQuality = 'high'; x.drawImage(c, 0, 0, t.width, t.height);
    return t.toDataURL('image/jpeg', 0.8);
  }

  /* --- demo scene: a sheet of paper on a desk, settling like a hand-held phone --- */
  const DEMO_PAGES = [
    { title: 'INVOICE', sub: 'INV-2026-114', color: '#4c5bff' },
    { title: 'RENTAL AGREEMENT', sub: 'Page 2 of 3', color: '#0d9488' },
    { title: 'RECEIPT', sub: 'Order #88231', color: '#e11d48' },
  ];
  function makePageTexture(n) {
    const p = DEMO_PAGES[n % DEMO_PAGES.length], w = 620, h = 877;
    const c = mkCanvas(w, h), x = c.getContext('2d');
    let seed = n * 7 + 3;
    const rnd = () => (seed = (seed * 9301 + 49297) % 233280) / 233280;
    x.fillStyle = '#f7f5ef'; x.fillRect(0, 0, w, h);
    x.fillStyle = p.color; x.beginPath(); x.arc(72, 80, 22, 0, Math.PI * 2); x.fill();
    x.fillStyle = '#1d2030'; x.font = '700 32px Inter, system-ui, sans-serif'; x.fillText(p.title, 108, 92);
    x.fillStyle = '#6b7080'; x.font = '500 17px Inter, system-ui, sans-serif'; x.fillText(p.sub, 110, 118);
    x.textAlign = 'right'; x.fillText('18 Nov 2026', w - 50, 92); x.textAlign = 'left';
    x.fillStyle = p.color; x.fillRect(48, 148, w - 96, 4);
    const words = 'lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua enim minim veniam quis nostrud'.split(' ');
    x.fillStyle = '#3a3e4d'; x.font = '400 15px Inter, system-ui, sans-serif';
    for (let y = 192; y < 330; y += 25) {
      let line = '';
      const maxW = (w - 96) * (y > 300 ? 0.55 : 0.88 + rnd() * 0.12);
      while (x.measureText(`${line} ${words[0]}`).width < maxW) line += `${line ? ' ' : ''}${words[(rnd() * words.length) | 0]}`;
      x.fillText(line, 48, y);
    }
    // table
    const rows = [['Description', 'Qty', 'Amount'], ['Design services', '12', '$ 960.00'], ['Scanning & archive', '3', '$ 180.00'], ['On-device license', '1', '$ 144.00']];
    rows.forEach((r, i) => {
      const y = 372 + i * 46;
      if (i === 0) { x.fillStyle = `${p.color}22`; x.fillRect(48, y - 28, w - 96, 40); }
      x.fillStyle = i === 0 ? '#1d2030' : '#3a3e4d';
      x.font = `${i === 0 ? 600 : 400} 16px Inter, system-ui, sans-serif`;
      x.fillText(r[0], 62, y); x.fillText(r[1], 360, y);
      x.textAlign = 'right'; x.fillText(r[2], w - 62, y); x.textAlign = 'left';
      x.fillStyle = '#d9dbe3'; x.fillRect(48, y + 16, w - 96, 1);
    });
    x.fillStyle = '#1d2030'; x.font = '700 20px Inter, system-ui, sans-serif';
    x.fillText('TOTAL', 360, 600); x.textAlign = 'right'; x.fillText('$ 1,284.00', w - 62, 600); x.textAlign = 'left';
    // signature in blue ink (Magic Color keeps it vivid; B&W turns it black)
    x.strokeStyle = '#1f3fbf'; x.lineWidth = 3; x.lineCap = 'round'; x.beginPath();
    x.moveTo(370, 740); x.bezierCurveTo(390, 690, 410, 770, 430, 725); x.bezierCurveTo(445, 700, 455, 760, 480, 730); x.bezierCurveTo(500, 710, 520, 745, 548, 722);
    x.stroke();
    x.fillStyle = '#9a9eab'; x.fillRect(360, 760, 210, 1.5);
    x.font = '400 13px Inter, system-ui, sans-serif'; x.fillText('Authorized signature', 360, 782);
    x.fillText('Thank you for your business · pdfit.app', 48, h - 46);
    return c;
  }

  const Scanner = (() => {
    const el = $('#scanner'), cv = $('#camCanvas'), ctx = cv.getContext('2d', { willReadFrequently: true });
    const small = mkCanvas(160, 160), sctx = small.getContext('2d', { willReadFrequently: true });
    const quadSvg = $('#quad'), poly = $('#quadPoly'), cornersG = $('#quadCorners');
    const pages = [];
    const sim = { bg: null, tex: null, page: 0, start: 0, rot: 0 };
    let W = 0, H = 0, dpr = 1, raf = 0, stream = null, video = null, useCamera = false;
    let running = false, paused = false, capturing = false;
    let smooth = null, lost = 0, stableMs = 0, lastDetect = 0, frame = 0, cooldownUntil = 0, locked = false, status = null;
    let mode = 'auto', torch = false;
    const LOCK_MS = 300, CAPTURE_MS = 1000, STILL = 0.008;

    function resize() {
      dpr = Math.min(window.devicePixelRatio || 1, 2);
      W = Math.max(1, Math.round(el.clientWidth * dpr)); H = Math.max(1, Math.round(el.clientHeight * dpr));
      cv.width = W; cv.height = H;
      quadSvg.setAttribute('viewBox', `0 0 ${W} ${H}`);
      small.width = 160; small.height = Math.max(1, Math.round((160 * H) / W));
      sim.bg = null; smooth = null;
    }

    function makeDesk() {
      const c = mkCanvas(W, H), x = c.getContext('2d');
      const g = x.createLinearGradient(0, 0, W, H);
      g.addColorStop(0, '#3b2a1c'); g.addColorStop(1, '#1f150d');
      x.fillStyle = g; x.fillRect(0, 0, W, H);
      x.globalAlpha = 0.18;
      for (let i = 0; i < 70; i++) {
        const y = (i / 70) * H + Math.sin(i * 12.9) * 20;
        x.strokeStyle = i % 2 ? '#5a4030' : '#140d07';
        x.lineWidth = (1 + (i % 4)) * dpr;
        x.beginPath(); x.moveTo(0, y);
        for (let xx = 0; xx <= W; xx += W / 10) x.lineTo(xx, y + Math.sin((xx / W) * 6 + i) * 8 * dpr);
        x.stroke();
      }
      x.globalAlpha = 1;
      const v = x.createRadialGradient(W / 2, H / 2, Math.min(W, H) * 0.2, W / 2, H / 2, Math.max(W, H) * 0.75);
      v.addColorStop(0, 'rgba(0,0,0,0)'); v.addColorStop(1, 'rgba(0,0,0,.55)');
      x.fillStyle = v; x.fillRect(0, 0, W, H);
      return c;
    }
    function newSimPage(t) { sim.tex = makePageTexture(sim.page++); sim.start = t; sim.rot = (Math.random() - 0.5) * 0.16; }
    function drawSim(t) {
      if (!sim.bg) sim.bg = makeDesk();
      if (!sim.tex) newSimPage(t);
      ctx.drawImage(sim.bg, 0, 0);
      const age = Math.max(0, t - sim.start);
      const A = 0.02 + 0.98 * Math.exp(-age / 1100);              // hand shake, settling
      const e = 1 - (1 - Math.min(1, age / 500)) ** 3;              // slide-in
      let pw = W * 0.7, ph = pw * 1.414;
      if (ph > H * 0.62) { ph = H * 0.62; pw = ph / 1.414; }
      const cx = W / 2 + A * W * 0.14 * Math.sin(t / 260);
      const cy = H * 0.47 + A * H * 0.05 * Math.sin(t / 340 + 1) + (1 - e) * H * 0.75;
      const rot = sim.rot + A * 0.16 * Math.sin(t / 330 + 2);
      const sc = 1 + A * 0.06 * Math.sin(t / 410);
      ctx.save();
      ctx.translate(cx, cy); ctx.rotate(rot); ctx.scale(sc, sc);
      ctx.shadowColor = 'rgba(0,0,0,.6)'; ctx.shadowBlur = 28 * dpr; ctx.shadowOffsetY = 14 * dpr;
      ctx.fillStyle = '#f7f5ef'; ctx.fillRect(-pw / 2, -ph / 2, pw, ph);
      ctx.shadowColor = 'transparent';
      ctx.drawImage(sim.tex, -pw / 2, -ph / 2, pw, ph);
      const lg = ctx.createLinearGradient(-pw / 2, -ph / 2, pw / 2, ph / 2); // uneven light, for Magic Color to fix
      lg.addColorStop(0, 'rgba(255,248,230,0)'); lg.addColorStop(0.55, 'rgba(70,50,30,.10)'); lg.addColorStop(1, 'rgba(40,28,15,.32)');
      ctx.fillStyle = lg; ctx.fillRect(-pw / 2, -ph / 2, pw, ph);
      ctx.restore();
    }
    function coverRect() {
      const vw = video.videoWidth, vh = video.videoHeight, s = Math.max(W / vw, H / vh);
      return { s, ox: (W - vw * s) / 2, oy: (H - vh * s) / 2, vw, vh };
    }
    function drawCam() {
      if (!video || !video.videoWidth) { ctx.fillStyle = '#000'; ctx.fillRect(0, 0, W, H); return; }
      const r = coverRect();
      ctx.drawImage(video, r.ox, r.oy, r.vw * r.s, r.vh * r.s);
    }

    function setStatus(s) {
      if (s === status) return;
      status = s;
      $('#scanStatus').className = `scan-status${s === 'steady' ? ' steady' : s === 'locked' || s === 'captured' ? ' locked' : ''}`;
      $('#scanStatusText').textContent = {
        search: 'Looking for document…',
        steady: 'Hold steady',
        locked: mode === 'auto' ? 'Document detected · hold still' : 'Document detected · tap shutter',
        captured: `Page ${pages.length} captured`,
      }[s];
      quadSvg.classList.toggle('locked', s === 'locked' || s === 'captured');
    }
    function drawQuad() {
      quadSvg.classList.toggle('hidden', !smooth);
      if (!smooth) return;
      poly.setAttribute('points', smooth.map((p) => p.join(',')).join(' '));
      cornersG.innerHTML = smooth.map(([x, y]) => `<circle cx="${x}" cy="${y}" r="${7 * dpr}"/>`).join('');
      poly.style.strokeWidth = 3 * dpr;
    }

    function track(q, dt, t) {
      const kx = W / small.width, ky = H / small.height;
      if (q) {
        q = q.map(([x, y]) => [(x + 0.5) * kx, (y + 0.5) * ky]);
        lost = 0;
        if (!smooth) { smooth = q; stableMs = 0; }
        else {
          const diag = Math.hypot(W, H);
          const move = Math.max(...q.map((p, i) => Math.hypot(p[0] - smooth[i][0], p[1] - smooth[i][1]))) / diag;
          smooth = smooth.map((p, i) => [p[0] + (q[i][0] - p[0]) * 0.45, p[1] + (q[i][1] - p[1]) * 0.45]);
          stableMs = move < STILL ? stableMs + dt : Math.max(0, stableMs - dt * 2);
        }
      } else if (++lost > 5) { smooth = null; stableMs = 0; }

      const cooling = t < cooldownUntil;
      const isLocked = !!smooth && stableMs > LOCK_MS && !cooling;
      if (isLocked && !locked) haptic('light');
      locked = isLocked;
      drawQuad();
      const prog = mode === 'auto' && isLocked ? clamp((stableMs - LOCK_MS) / (CAPTURE_MS - LOCK_MS), 0, 1) : 0;
      $('#ringProg').style.strokeDashoffset = 239 * (1 - prog);
      setStatus(cooling && pages.length ? 'captured' : !smooth ? 'search' : isLocked ? 'locked' : 'steady');
      if (prog >= 1 && !capturing) capture();
    }

    function loop(t) {
      if (!running) return;
      raf = requestAnimationFrame(loop);
      if (paused) return;
      if (useCamera) drawCam(); else drawSim(t);
      if (++frame % 2) return; // detect every other frame
      const dt = lastDetect ? Math.min(150, t - lastDetect) : 33;
      lastDetect = t;
      sctx.drawImage(cv, 0, 0, small.width, small.height);
      track(detectQuad(sctx.getImageData(0, 0, small.width, small.height)), dt, t);
    }

    function updateBatch() {
      $('#batchCount').textContent = pages.length;
      $('#batchCount').hidden = !pages.length;
      const last = pages[pages.length - 1];
      if (last?.thumb) $('#batchImg').src = last.thumb; else $('#batchImg').removeAttribute('src');
      $('#scanDone').disabled = !pages.length;
      $('#scanDone').textContent = pages.length ? `Done (${pages.length})` : 'Done';
    }

    async function capture() {
      if (capturing || !running) return;
      capturing = true;
      let q = smooth ? smooth.map((p) => [...p]) : [[0, 0], [W, 0], [W, H], [0, H]];
      if (smooth) { // pull corners in slightly so no desk shows on the edges
        const cx = q.reduce((a, p) => a + p[0], 0) / 4, cy = q.reduce((a, p) => a + p[1], 0) / 4;
        q = q.map(([x, y]) => [x + (cx - x) * 0.01, y + (cy - y) * 0.01]);
      }
      let src;
      if (useCamera && video?.videoWidth) { // warp from the full-resolution video frame, not the preview
        const r = coverRect();
        const vc = mkCanvas(r.vw, r.vh), vx = vc.getContext('2d', { willReadFrequently: true });
        vx.drawImage(video, 0, 0);
        src = vx.getImageData(0, 0, r.vw, r.vh);
        q = q.map(([x, y]) => [(x - r.ox) / r.s, (y - r.oy) / r.s]);
      } else {
        src = ctx.getImageData(0, 0, W, H);
      }
      const fx = $('#flashFx'); fx.classList.remove('go'); void fx.offsetWidth; fx.classList.add('go');
      haptic('medium');
      await nextFrame();
      const page = { id: `p${Date.now()}`, src: warp(src, q), filter: settings.defaultFilter, rot: 0, cache: {} };
      page.thumb = thumbURL(renderPage(page));
      pages.push(page);
      cooldownUntil = performance.now() + 1400;
      stableMs = 0; smooth = null; locked = false; status = null;
      if (!useCamera) newSimPage(performance.now() + 350);
      updateBatch();
      const bt = $('#batchThumb'); bt.classList.remove('bump'); void bt.offsetWidth; bt.classList.add('bump');
      capturing = false;
    }

    function stopStream() {
      if (stream) stream.getTracks().forEach((tr) => tr.stop());
      stream = null; video = null; torch = false;
      $('#flashBtn').innerHTML = ic('zap-off'); icons();
    }
    function setSource(kind) {
      const b = $('#scanSource');
      b.dataset.kind = kind;
      b.innerHTML = kind === 'camera' ? `${ic('camera')}Live camera · tap for demo scene`
        : kind === 'sim' ? `${ic('sparkles')}Demo scene · tap to use camera` : 'Starting camera…';
      icons();
    }
    function useSim(reason) {
      stopStream(); useCamera = false; sim.tex = null; smooth = null;
      setSource('sim');
      if (reason) toast(reason, 'camera-off');
    }
    async function startCamera() {
      setSource('starting');
      if (!navigator.mediaDevices?.getUserMedia) return useSim('');
      try {
        const s = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: 'environment' }, width: { ideal: 1920 }, height: { ideal: 1080 } }, audio: false });
        if (!running) { s.getTracks().forEach((tr) => tr.stop()); return; }
        stream = s;
        video = document.createElement('video');
        video.playsInline = true; video.muted = true; video.srcObject = stream;
        await video.play();
        useCamera = true; smooth = null;
        setSource('camera');
      } catch (e) {
        useSim(e && e.name === 'NotAllowedError' ? 'Camera blocked · demo scene' : 'No camera · demo scene');
      }
    }

    function setMode(m) {
      mode = m;
      $$('.mode').forEach((b) => b.classList.toggle('on', b.dataset.mode === m));
      status = null;
    }

    async function open() {
      if (running) return;
      el.classList.add('open'); el.setAttribute('aria-hidden', 'false');
      $('#device').classList.add('dark-chrome');
      haptic('light');
      await nextFrame();
      resize();
      running = true; paused = false; lastDetect = 0; smooth = null; stableMs = 0; locked = false; status = null; cooldownUntil = 0;
      setMode(settings.autoCapture ? 'auto' : 'manual');
      updateBatch();
      raf = requestAnimationFrame(loop);
      await startCamera();
    }
    function close(force) {
      if (pages.length && !force) {
        openSheet(`${sheetHead('Discard this scan?', `${plural(pages.length, 'page')} not saved yet`, 'triangle-alert', 'pdf')}
          <div class="btn-col"><button class="btn danger" id="discardYes">Discard pages</button><button class="btn ghost" id="discardNo">Keep scanning</button></div>`, (b) => {
          b.querySelector('#discardYes').onclick = () => { closeSheet(); close(true); };
          b.querySelector('#discardNo').onclick = closeSheet;
        });
        return;
      }
      running = false; cancelAnimationFrame(raf); stopStream();
      pages.length = 0; sim.tex = null;
      el.classList.remove('open'); el.setAttribute('aria-hidden', 'true');
      $('#device').classList.remove('dark-chrome');
    }
    async function toggleFlash() {
      const track = stream?.getVideoTracks?.()[0];
      const caps = track?.getCapabilities?.();
      if (!caps || !caps.torch) { toast('Flash isn’t available on this device', 'zap-off'); return; }
      torch = !torch;
      try { await track.applyConstraints({ advanced: [{ torch }] }); } catch { torch = false; }
      $('#flashBtn').innerHTML = ic(torch ? 'zap' : 'zap-off'); icons();
      haptic('select');
    }

    $('#scanClose').addEventListener('click', () => close(false));
    $('#flashBtn').addEventListener('click', toggleFlash);
    $('#shutter').addEventListener('click', () => capture());
    $('#scanSource').addEventListener('click', () => { haptic('select'); if ($('#scanSource').dataset.kind === 'camera') useSim(''); else startCamera(); });
    $$('.mode').forEach((b) => b.addEventListener('click', () => { haptic('select'); setMode(b.dataset.mode); }));
    const toReview = () => { if (pages.length) { paused = true; Review.open(); } };
    $('#scanDone').addEventListener('click', toReview);
    $('#batchThumb').addEventListener('click', toReview);
    window.addEventListener('resize', () => { if (running) resize(); });

    return { open, close, pages, updateBatch, resume: () => { paused = false; status = null; }, isOpen: () => running };
  })();

  /* ----------------------------------------------------- review + save */
  const FILTERS = [['original', 'Original', 'image'], ['magic', 'Magic Color', 'sparkles'], ['gray', 'Grayscale', 'contrast'], ['bw', 'B&W', 'file-text'], ['photo', 'Photo', 'sun']];

  const Review = (() => {
    const el = $('#review'), stage = $('#stage');
    let idx = 0, applyAll = false;
    const pages = Scanner.pages;

    function open(i = pages.length - 1) {
      idx = i;
      el.classList.add('open'); el.setAttribute('aria-hidden', 'false');
      $('#device').classList.remove('dark-chrome');
      render();
    }
    function close() {
      el.classList.remove('open'); el.setAttribute('aria-hidden', 'true');
      if (Scanner.isOpen()) { $('#device').classList.add('dark-chrome'); Scanner.updateBatch(); Scanner.resume(); }
    }
    async function render() {
      if (!pages.length) { close(); return; }
      idx = clamp(idx, 0, pages.length - 1);
      const p = pages[idx];
      $('#reviewTitle').textContent = `Page ${idx + 1} of ${pages.length}`;
      $('#filterRow').innerHTML = FILTERS.map(([id, label, icn]) => `<button class="chip${p.filter === id ? ' on' : ''}" role="radio" aria-checked="${p.filter === id}" data-f="${id}">${ic(icn)}${label}</button>`).join('');
      $('#raAll').classList.toggle('on', applyAll);
      $('#raAll').setAttribute('aria-pressed', String(applyAll));
      icons();
      if (!p.cache[p.filter]) { stage.classList.add('busy'); await nextFrame(); }
      const c = renderPage(p);
      stage.classList.remove('busy');
      const old = stage.querySelector('canvas');
      if (old) old.replaceWith(c); else stage.prepend(c);
      p.thumb = thumbURL(c);
      $('#pageStrip').innerHTML = pages.map((pg, i) => `<button class="pthumb${i === idx ? ' on' : ''}" data-i="${i}" aria-label="Page ${i + 1}"><img src="${pg.thumb}" alt=""><span>${i + 1}</span></button>`).join('');
      // Scroll only the strip (scrollIntoView would also scroll the clipped device frame).
      const strip = $('#pageStrip'), on = strip.querySelector('.pthumb.on');
      if (on) strip.scrollTo({ left: on.offsetLeft - (strip.clientWidth - on.offsetWidth) / 2, behavior: 'smooth' });
    }

    $('#filterRow').addEventListener('click', async (e) => {
      const f = e.target.closest('[data-f]')?.dataset.f;
      if (!f) return;
      haptic('select');
      if (!applyAll) { pages[idx].filter = f; render(); return; }
      pages.forEach((p) => { p.filter = f; });
      await render(); // current page first, then refresh the other thumbnails
      await nextFrame();
      pages.forEach((p, i) => { if (i !== idx) p.thumb = thumbURL(renderPage(p)); });
      render();
    });
    $('#pageStrip').addEventListener('click', (e) => { const b = e.target.closest('[data-i]'); if (b) { idx = Number(b.dataset.i); haptic('select'); render(); } });
    $('#raRotate').addEventListener('click', () => { pages[idx].rot += 90; haptic('select'); render(); });
    $('#raAll').addEventListener('click', () => { applyAll = !applyAll; haptic('select'); render(); if (applyAll) toast('Filter changes now apply to all pages', 'copy-check'); });
    $('#raDelete').addEventListener('click', () => { pages.splice(idx, 1); haptic('warn'); if (!pages.length) close(); else render(); });
    $('#raAdd').addEventListener('click', close);
    $('#reviewBack').addEventListener('click', close);
    $('#reviewSave').addEventListener('click', openSave);

    function openSave() {
      const def = `Scan ${new Date().toLocaleDateString([], { day: 'numeric', month: 'short', year: 'numeric' })}`;
      const folderNames = [...new Set(['Scans', ...docs.map((d) => d.folder)])];
      let fmt = 'pdf', folder = 'Scans';
      openSheet(`${sheetHead('Save document', `${plural(pages.length, 'page')} · stored on this device`, 'file-check', 'scan')}
        <label class="field">Name<input class="input" id="saveName" value="${esc(def)}" maxlength="80" autocomplete="off"></label>
        <div class="field">Folder<div class="chips">${folderNames.map((f) => `<button class="chip${f === folder ? ' on' : ''}" data-folder-pick="${esc(f)}">${esc(f)}</button>`).join('')}</div></div>
        <div class="field">Format<div class="chips"><button class="chip on" data-fmt="pdf">PDF</button><button class="chip" data-fmt="jpg">JPG images</button></div></div>
        <div class="btn-row"><button class="btn ghost" id="saveShare">${ic('share')}Save & share</button><button class="btn primary" id="saveGo">${ic('check')}Save</button></div>`, (body) => {
        body.addEventListener('click', (e) => {
          const f = e.target.closest('[data-folder-pick]'), m = e.target.closest('[data-fmt]');
          if (f) { folder = f.dataset.folderPick; $$('[data-folder-pick]', body).forEach((c) => c.classList.toggle('on', c === f)); haptic('select'); }
          if (m) { fmt = m.dataset.fmt; $$('[data-fmt]', body).forEach((c) => c.classList.toggle('on', c === m)); haptic('select'); }
        });
        let saving = false;
        const commit = async (share) => {
          if (saving) return;
          saving = true;
          body.querySelectorAll('.btn').forEach((b) => { b.disabled = true; });
          const name = (body.querySelector('#saveName').value.trim() || def).slice(0, 80);
          const canvases = pages.map(renderPage);
          let size = 0;
          const blobs = [];
          for (const c of canvases) { const b = await toBlob(c, 'image/jpeg', 0.85); blobs.push(b); size += b.size; }
          const doc = {
            id: `s${Date.now()}`, name, kind: fmt === 'pdf' ? 'pdf' : 'img', pages: canvases.length,
            size: size + (fmt === 'pdf' ? 1200 + canvases.length * 350 : 0), date: Date.now(), folder, starred: false,
            thumb: thumbURL(canvases[0], 120), canvases, sample: false, isNew: true,
          };
          docs.unshift(doc);
          closeSheet(); close(); Scanner.close(true);
          setTab('home'); refreshAll(); haptic('success');
          toast(`Saved · ${plural(doc.pages, 'page')} · ${fmtSize(doc.size)}`);
          if (!share) return;
          if (fmt === 'pdf') { exportPdf(doc); return; }
          const files = blobs.map((b, i) => new File([b], `${safeName(name)}-${i + 1}.jpg`, { type: 'image/jpeg' }));
          if (navigator.canShare && navigator.canShare({ files })) { try { await navigator.share({ files, title: name }); } catch { /* cancelled */ } }
          else files.forEach((f) => shareOrDownload(f, f.name));
        };
        body.querySelector('#saveGo').addEventListener('click', () => commit(false));
        body.querySelector('#saveShare').addEventListener('click', () => commit(true));
        body.querySelector('#saveName').addEventListener('keydown', (e) => { if (e.key === 'Enter') commit(false); });
      });
    }
    return { open, close };
  })();

  /* ------------------------------------------------------------ navigation */
  function setTab(name) {
    $$('.tab').forEach((b) => { b.classList.toggle('on', b.dataset.tab === name); b.setAttribute('aria-current', b.dataset.tab === name ? 'page' : 'false'); });
    $$('.screen').forEach((s) => s.classList.toggle('active', s.dataset.screen === name));
  }

  function renderTools() {
    const groups = [['PDF', ['merge', 'split', 'compress', 'sign']], ['Image', ['target', 'resize']], ['Convert', ['convert', 'pdf2img', 'heic']], ['Capture', ['scan']]];
    $('#toolsBody').innerHTML = groups.map(([g, ids]) => `<h3>${g}</h3><div class="rows glass">${ids.map((id) => {
      const t = TOOLS[id];
      return `<button class="row" data-tool="${id}"><span class="ti c-${t.cat}">${ic(t.icon)}</span><span class="rt"><b>${t.name}</b><span>${t.desc}</span></span>${t.native ? '<span class="pill">Native</span>' : ''}${ic('chevron-right', 'chev')}</button>`;
    }).join('')}</div>`).join('');
  }

  function renderSettings() {
    $('#setAuto').checked = settings.autoCapture;
    $('#setHaptics').checked = settings.haptics;
    $('#setFilter').innerHTML = FILTERS.map(([id, label]) => `<button class="chip${settings.defaultFilter === id ? ' on' : ''}" data-default-filter="${id}">${label}</button>`).join('');
  }

  document.addEventListener('click', (e) => {
    const t = e.target;
    if (t.closest('#sheet')) return; // sheets handle their own clicks
    const tool = t.closest('[data-tool]');
    if (tool) return openTool(tool.dataset.tool);
    const tab = t.closest('[data-tab]');
    if (tab) { haptic('select'); return setTab(tab.dataset.tab); }
    const go = t.closest('[data-goto]');
    if (go) { haptic('select'); return setTab(go.dataset.goto); }
    const doc = t.closest('[data-doc]');
    if (doc) return openDocSheet(doc.dataset.doc);
    const folder = t.closest('[data-folder]');
    if (folder) { haptic('select'); filesState.folder = folder.dataset.folder; filesState.view = 'all'; return renderFiles(); }
    if (t.closest('#clearFolder')) { filesState.folder = null; return renderFiles(); }
    const nat = t.closest('[data-native]');
    if (nat) return toast(`${nat.dataset.native} ships in the native build`, 'info');
    const df = t.closest('[data-default-filter]');
    if (df) { settings.defaultFilter = df.dataset.defaultFilter; saveSettings(); haptic('select'); return renderSettings(); }
    const th = t.closest('#themeSeg [data-theme]');
    if (th) { settings.theme = th.dataset.theme; saveSettings(); haptic('select'); return applyTheme(); }
  });

  $('#fab').addEventListener('click', () => Scanner.open());
  $('#themeQuick').addEventListener('click', () => { settings.theme = isDark() ? 'light' : 'dark'; saveSettings(); haptic('select'); applyTheme(); });
  $('#scrim').addEventListener('click', closeSheet);
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeSheet(); });
  $('#homeSearch').addEventListener('focus', () => { setTab('files'); setTimeout(() => $('#filesSearch').focus(), 60); });
  $('#filesSearch').addEventListener('input', (e) => { filesState.q = e.target.value; renderFiles(); });
  $('#sortSel').addEventListener('change', (e) => { filesState.sort = e.target.value; renderFiles(); });
  $('#filesSeg').addEventListener('click', (e) => {
    const b = e.target.closest('[data-view]');
    if (!b) return;
    haptic('select'); filesState.view = b.dataset.view; filesState.folder = null; renderFiles();
  });
  $('#setAuto').addEventListener('change', (e) => { settings.autoCapture = e.target.checked; saveSettings(); haptic('select'); });
  $('#setHaptics').addEventListener('change', (e) => { settings.haptics = e.target.checked; saveSettings(); haptic('select'); });

  /* ------------------------------------------------------------------ boot */
  function tickClock() {
    const d = new Date();
    $('#clock').textContent = d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }).replace(/\s?[AP]M$/i, '');
    const h = d.getHours();
    $('#greeting').textContent = h < 5 ? 'Working late' : h < 12 ? 'Good morning' : h < 18 ? 'Good afternoon' : 'Good evening';
  }
  tickClock(); setInterval(tickClock, 30000);
  renderQuickTools();
  renderTools();
  renderSettings();
  applyTheme();
  renderHome(true);          // skeleton first …
  renderFiles();
  setTimeout(() => renderHome(false), 700); // … then content (simulates the DB read)
  icons();

  window.PDFit = { Scanner, Review, docs }; // handy for poking around in devtools
})();
