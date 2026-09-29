/* Mockup annotation layer for the /feature design gate.
 *
 * Injected into the designer's mockup.html by `design-gate.sh inject`, which also sets
 * window.PFA_RUN and window.PFA_REV (a hash of the mockup, so each revision gets fresh notes).
 *
 * Toggle "Annotate", click anything to pin a numbered note. Notes persist in this browser's
 * localStorage, so a reload keeps them.
 *
 * - Served by `design-gate.sh serve` (http://127.0.0.1): notes autosave to <run>/notes.json,
 *   and "Send notes" / "Approve design" hand the decision to the orchestrator, which is
 *   waiting on that file. The user never has to return to the terminal to say they're done.
 * - Opened as a file: "Copy notes" puts them on the clipboard to paste into the terminal.
 *
 * The only request this script makes is that POST to its own loopback origin.
 */
(function () {
  if (window.__pfAnnotate) return;
  window.__pfAnnotate = true;

  var RUN = window.PFA_RUN || 'mockup';
  // Keyed per run and revision so notes from an earlier mockup don't reappear on the next one.
  var KEY = 'pfa:' + RUN + ':' + (window.PFA_REV || '');
  var notes = load();
  var on = false;
  var hoverEl = null;
  // Served by the gate's local server: notes autosave to <run>/notes.json and "Done" hands off.
  var SERVED = location.protocol === 'http:';
  var syncTimer = null;

  function load() {
    try { return JSON.parse(localStorage.getItem(KEY) || '[]'); } catch (e) { return []; }
  }
  function save() {
    try { localStorage.setItem(KEY, JSON.stringify(notes)); } catch (e) { /* private window: notes live until reload */ }
    if (SERVED) { clearTimeout(syncTimer); syncTimer = setTimeout(function () { sync(false); }, 600); }
  }
  function sync(done, decision) {
    return fetch('/__notes', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        run: RUN, rev: window.PFA_REV || null, done: done, decision: decision || null,
        saved_at: new Date().toISOString(),
        notes: notes.map(function (n) { return { label: n.label, target: n.target, text: n.text }; })
      })
    }).then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); });
  }
  function clean(s, n) {
    s = (s || '').replace(/\s+/g, ' ').trim();
    return s.length > n ? s.slice(0, n - 1) + '…' : s;
  }

  // "2 · Loading, empty and error… › Price" — the section heading, then the card title.
  function labelFor(el) {
    var parts = [];
    var sec = el.closest('.section');
    var h = sec && sec.querySelector('h2');
    if (h) parts.push(clean(h.textContent, 60));
    var card = el.closest('section.card, .card');
    if (card) {
      var t = card.querySelector('.ch .t, .lh b, h1, h3');
      if (t) parts.push(clean(t.textContent, 40));
    }
    // Documents without mockup sections (the rendered plan): use the nearest heading above.
    if (!parts.length) {
      var hs = document.querySelectorAll('h1, h2, h3, h4');
      var near = null;
      for (var i = 0; i < hs.length; i++) {
        if (hs[i] === el || hs[i].contains(el) ||
            (hs[i].compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING)) near = hs[i];
      }
      if (near) parts.push(clean(near.textContent, 70));
    }
    return parts.join(' › ') || 'page';
  }

  // ---- styles -------------------------------------------------------------------
  var css = document.createElement('style');
  css.textContent = [
    '.pfa-panel{position:fixed;right:16px;bottom:16px;z-index:2147483000;width:340px;max-width:calc(100vw - 32px);',
    ' max-height:70vh;display:flex;flex-direction:column;background:#111827;color:#f3f4f6;border:1px solid #374151;',
    ' border-radius:12px;box-shadow:0 12px 40px rgba(0,0,0,.35);font:13px/1.45 system-ui,-apple-system,sans-serif}',
    '.pfa-panel.min .pfa-body{display:none}',
    '.pfa-head{display:flex;gap:6px;align-items:center;padding:10px 12px;border-bottom:1px solid #374151}',
    '.pfa-head b{flex:1;font-size:13px}',
    '.pfa-btn{background:#1f2937;color:#f3f4f6;border:1px solid #4b5563;border-radius:7px;padding:5px 9px;',
    ' font:600 12px system-ui,sans-serif;cursor:pointer}',
    '.pfa-btn:hover{border-color:#9ca3af}',
    '.pfa-btn.on{background:#0891b2;border-color:#0891b2;color:#fff}',
    '.pfa-body{overflow:auto;padding:8px 12px 12px}',
    '.pfa-hint{color:#9ca3af;font-size:12px;margin:4px 0 8px}',
    '.pfa-note{border:1px solid #374151;border-radius:8px;padding:8px;margin:0 0 8px}',
    '.pfa-note .lbl{display:flex;gap:6px;align-items:baseline;font-size:11px;color:#9ca3af;margin-bottom:4px}',
    '.pfa-note .lbl span{flex:1}',
    '.pfa-note textarea,.pfa-out{width:100%;box-sizing:border-box;background:#0b1220;color:#f3f4f6;border:1px solid #374151;',
    ' border-radius:6px;padding:6px;font:13px/1.4 system-ui,sans-serif;resize:vertical}',
    '.pfa-note textarea{min-height:52px}',
    '.pfa-x{background:none;border:none;color:#9ca3af;cursor:pointer;font-size:14px;padding:0 2px}',
    '.pfa-x:hover{color:#f87171}',
    '.pfa-foot{display:flex;gap:6px;flex-wrap:wrap;margin-top:4px}',
    '.pfa-out{margin-top:8px;min-height:90px;font:12px/1.4 ui-monospace,Menlo,monospace}',
    '.pfa-pin{position:absolute;z-index:2147482999;width:22px;height:22px;margin:-11px 0 0 -11px;border-radius:50%;',
    ' background:#f59e0b;color:#111827;border:2px solid #fff;font:700 11px/18px system-ui,sans-serif;text-align:center;',
    ' box-shadow:0 2px 8px rgba(0,0,0,.35);cursor:pointer}',
    '.pfa-pin.hl{background:#0891b2;color:#fff}',
    'body.pfa-on,body.pfa-on *{cursor:crosshair!important}',
    '.pfa-hover{outline:2px dashed #f59e0b!important;outline-offset:2px}',
    '.pfa-num{display:inline-block;min-width:18px;height:18px;border-radius:50%;background:#f59e0b;color:#111827;',
    ' text-align:center;font:700 11px/18px system-ui,sans-serif}'
  ].join('\n');
  document.head.appendChild(css);

  // ---- panel --------------------------------------------------------------------
  var panel = document.createElement('div');
  panel.className = 'pfa-panel';
  panel.innerHTML =
    '<div class="pfa-head"><b>Notes <span id="pfa-count"></span></b>' +
    '<button class="pfa-btn" id="pfa-toggle" type="button">Annotate</button>' +
    '<button class="pfa-btn" id="pfa-min" type="button" title="Minimise">–</button></div>' +
    '<div class="pfa-body">' +
    '<p class="pfa-hint">Turn on <b>Annotate</b>, click anything in the mockup and type a note ' +
    '(<b>Esc</b> stops annotating). ' +
    (SERVED ? 'Notes save automatically. Click <b>Send notes</b> to have the designer revise, or <b>' + (window.PFA_APPROVE_LABEL || 'Approve design') + '</b> ' +
      'to move on. Claude picks either up without you returning to the terminal.</p>'
            : 'When you are done, <b>Copy notes</b> and paste them into the terminal.</p>') +
    '<div id="pfa-list"></div>' +
    '<div class="pfa-foot">' +
    (SERVED ? '<button class="pfa-btn on" id="pfa-done" type="button">Send notes — revise</button>' +
              '<button class="pfa-btn" id="pfa-approve" type="button">' + (window.PFA_APPROVE_LABEL || 'Approve design') + '</button>' : '') +
    '<button class="pfa-btn" id="pfa-copy" type="button">Copy notes</button>' +
    '<button class="pfa-btn" id="pfa-clear" type="button">Clear all</button></div>' +
    '<textarea class="pfa-out" id="pfa-out" readonly hidden></textarea></div>';
  document.body.appendChild(panel);

  var $ = function (id) { return document.getElementById(id); };
  var pinLayer = document.createElement('div');
  document.body.appendChild(pinLayer);

  function render() {
    $('pfa-count').textContent = notes.length ? '(' + notes.length + ')' : '';
    var list = $('pfa-list');
    list.innerHTML = '';
    pinLayer.innerHTML = '';
    notes.forEach(function (n, i) {
      var row = document.createElement('div');
      row.className = 'pfa-note';
      row.innerHTML = '<div class="lbl"><span class="pfa-num">' + (i + 1) + '</span><span></span>' +
        '<button class="pfa-x" type="button" title="Delete note">✕</button></div><textarea></textarea>';
      row.querySelector('.lbl span:nth-child(2)').textContent = n.label + (n.target ? ' — “' + n.target + '”' : '');
      var ta = row.querySelector('textarea');
      ta.value = n.text;
      ta.placeholder = 'What should change here?';
      ta.addEventListener('input', function () { n.text = ta.value; save(); });
      row.querySelector('.pfa-x').addEventListener('click', function () {
        notes.splice(i, 1); save(); render();
      });
      list.appendChild(row);

      var pin = document.createElement('div');
      pin.className = 'pfa-pin';
      pin.textContent = i + 1;
      pin.style.left = n.x + 'px';
      pin.style.top = n.y + 'px';
      pin.title = n.text || n.label;
      pin.addEventListener('click', function (e) {
        e.stopPropagation();
        panel.classList.remove('min');
        ta.focus();
        ta.scrollIntoView({ block: 'nearest' });
      });
      pinLayer.appendChild(pin);
    });
  }

  function exportText() {
    var lines = ['Mockup notes — run ' + RUN + ' (' + notes.length + ')', ''];
    notes.forEach(function (n, i) {
      lines.push((i + 1) + '. [' + n.label + ']' + (n.target ? ' “' + n.target + '”' : '') + ': ' +
        (clean(n.text, 2000) || '(no text)'));
    });
    return lines.join('\n');
  }

  function copy(text) {
    var out = $('pfa-out');
    out.value = text;
    out.hidden = false;
    var done = function (ok) { $('pfa-copy').textContent = ok ? 'Copied ✓' : 'Select below and copy'; };
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () { done(true); }, function () { fallback(); });
        return;
      }
    } catch (e) { /* fall through */ }
    fallback();
    function fallback() {
      out.select();
      var ok = false;
      try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
      done(ok);
    }
  }

  function setOn(v) {
    on = v;
    $('pfa-toggle').classList.toggle('on', on);
    $('pfa-toggle').textContent = on ? 'Annotating…' : 'Annotate';
    document.body.classList.toggle('pfa-on', on);
    if (!on && hoverEl) { hoverEl.classList.remove('pfa-hover'); hoverEl = null; }
  }

  $('pfa-toggle').addEventListener('click', function () { setOn(!on); });
  $('pfa-min').addEventListener('click', function () { panel.classList.toggle('min'); });
  $('pfa-copy').addEventListener('click', function () { copy(exportText()); });
  if (SERVED) {
    var decide = function (btn, decision, sentLabel) {
      if (decision === 'revise' && !notes.some(function (n) { return (n.text || '').trim(); })) {
        $(btn).textContent = 'Add a note first';
        return;
      }
      clearTimeout(syncTimer);
      $(btn).textContent = 'Sending…';
      sync(true, decision).then(function () {
        setOn(false);
        $(btn).textContent = sentLabel;
      }, function () {
        $(btn).textContent = 'Could not reach Claude — use Copy notes';
      });
    };
    $('pfa-done').addEventListener('click', function () { decide('pfa-done', 'revise', 'Sent ✓ — revising'); });
    $('pfa-approve').addEventListener('click', function () {
      decide('pfa-approve', 'approve', 'Approved ✓ — see the terminal');
    });
  }
  var clearArmed = false;
  $('pfa-clear').addEventListener('click', function () {
    if (!notes.length) return;
    if (!clearArmed) {
      clearArmed = true;
      $('pfa-clear').textContent = 'Click again to clear';
      setTimeout(function () { clearArmed = false; $('pfa-clear').textContent = 'Clear all'; }, 3000);
      return;
    }
    clearArmed = false;
    $('pfa-clear').textContent = 'Clear all';
    notes = []; save(); render();
  });

  document.addEventListener('mouseover', function (e) {
    if (!on || panel.contains(e.target)) return;
    if (hoverEl) hoverEl.classList.remove('pfa-hover');
    hoverEl = e.target;
    hoverEl.classList.add('pfa-hover');
  }, true);

  // Capture phase so the mockup's own buttons (tabs, theme toggle) don't fire while annotating.
  document.addEventListener('click', function (e) {
    if (!on || panel.contains(e.target) || e.target.classList.contains('pfa-pin')) return;
    e.preventDefault();
    e.stopPropagation();
    var el = e.target;
    el.classList.remove('pfa-hover');
    notes.push({
      x: e.pageX, y: e.pageY,
      label: labelFor(el),
      target: clean(el.textContent, 40),
      text: ''
    });
    save();
    panel.classList.remove('min');
    render();
    var tas = $('pfa-list').querySelectorAll('textarea');
    if (tas.length) { tas[tas.length - 1].focus(); tas[tas.length - 1].scrollIntoView({ block: 'nearest' }); }
  }, true);

  document.addEventListener('keydown', function (e) { if (e.key === 'Escape' && on) setOn(false); });

  render();
})();
