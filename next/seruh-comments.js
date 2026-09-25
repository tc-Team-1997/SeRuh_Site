/* ─────────────────────────────────────────────────────────────
   Comments on quotes and on wall posts, added to the live site
   without its source.

   The deployed app is a 777 KB minified bundle whose source does not
   exist anywhere, so this cannot be a component. It is a widget that
   attaches itself to the page the app renders:

     · every card carries a button labelled "Copy this quote" or
       "Copy this feeling", and a <blockquote> holding the text;
     · that text is matched against quotes_public / feelings_public
       to recover the id, because the DOM carries none of its own;
     · a 💬 button is appended to the card's own action row;
     · the thread opens in an overlay attached to <body>, outside
       React's tree, so a re-render cannot tear it down mid-sentence.

   React owns the cards and will re-render them. A MutationObserver
   re-attaches the button whenever that happens.

   Nothing here may break the page it is bolted onto. Every entry
   point is wrapped, and any failure leaves the site exactly as it
   was, minus a button.
   ───────────────────────────────────────────────────────────── */
(function () {
  'use strict';

  var API = 'https://stowxeobdtvhapkzsvaq.supabase.co';
  var KEY = 'sb_publishable_TolsckXYt02Y9zydXVy8ZQ_64XaJ-FO';
  var SCHEMA = 'public';            // this project's default is not `public`
  var MARK = 'data-seruh-comments'; // so a card is only enhanced once

  /* Reuse the app's own visitor id, so a comment belongs to the same
     person the rest of the site already thinks you are. */
  function visitor() {
    try {
      var v = localStorage.getItem('seruh_visitor_id');
      if (!v || !/^[0-9a-f-]{36}$/i.test(v)) {
        v = (crypto.randomUUID && crypto.randomUUID()) ||
            'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
              var r = (Math.random() * 16) | 0;
              return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
            });
        localStorage.setItem('seruh_visitor_id', v);
      }
      return v;
    } catch (e) { return '00000000-0000-4000-8000-000000000000'; }
  }
  var VISITOR = visitor();

  function rpc(fn, args) {
    return fetch(API + '/rest/v1/rpc/' + fn, {
      method: 'POST',
      headers: { apikey: KEY, 'Content-Type': 'application/json', 'Content-Profile': SCHEMA },
      body: JSON.stringify(args || {}),
    }).then(function (r) {
      if (!r.ok) { var e = new Error(fn + ' ' + r.status); e.status = r.status; throw e; }
      return r.status === 204 ? null : r.json();
    });
  }

  /* A feeling card renders its text as [ “ , content , ” ] — the app
     adds the curly quotes — while a quote card renders the text bare.
     Strip any wrapping quote mark from both sides so a card's
     textContent can be compared with what the API returns. */
  var norm = function (s) {
    return String(s || '')
      .replace(/\s+/g, ' ')
      .replace(/^[\s"'\u201C\u201D\u2018\u2019\u00AB\u00BB]+/, '')
      .replace(/[\s"'\u201C\u201D\u2018\u2019\u00AB\u00BB]+$/, '')
      .trim().toLowerCase();
  };

  /* ── styles, borrowed from the page's own palette ── */
  var CSS = ''
    + '.sqc-btn{display:inline-flex;align-items:center;gap:.4rem;border:0;background:none;cursor:pointer;'
    + 'border-radius:999px;padding:.375rem .75rem;font-size:.8rem;color:#6f6674;transition:color .3s,background .3s}'
    + '.sqc-btn:hover{color:#9a545f;background:rgba(244,227,226,.6)}'
    + '.sqc-scrim{position:fixed;inset:0;background:rgba(46,42,51,.5);backdrop-filter:blur(3px);z-index:9998;'
    + 'opacity:0;visibility:hidden;pointer-events:none;transition:opacity .22s,visibility .22s}'
    + '.sqc-scrim.on{opacity:1;visibility:visible;pointer-events:auto}'
    + '.sqc-sheet{position:fixed;left:0;right:0;bottom:0;z-index:9999;background:#fffdf8;color:#2e2a33;'
    + 'border-radius:22px 22px 0 0;padding:20px 20px calc(20px + env(safe-area-inset-bottom));max-height:88vh;'
    + 'overflow-y:auto;transform:translateY(102%);visibility:hidden;pointer-events:none;'
    + 'transition:transform .3s cubic-bezier(.22,1,.36,1),visibility .3s;'
    + 'font-family:ui-sans-serif,system-ui,sans-serif;box-shadow:0 -10px 40px -16px rgba(0,0,0,.35)}'
    + '.sqc-sheet.on{transform:none;visibility:visible;pointer-events:auto}'
    + '@media(min-width:640px){.sqc-sheet{left:50%;right:auto;bottom:auto;top:50%;width:min(560px,92vw);'
    + 'border-radius:20px;transform:translate(-50%,-46%);opacity:0}'
    + '.sqc-sheet.on{transform:translate(-50%,-50%);opacity:1;visibility:visible;pointer-events:auto}}'
    + '.sqc-q{font-family:Georgia,serif;font-size:1.02rem;line-height:1.5;color:#2e2a33;white-space:pre-line;'
    + 'padding-bottom:14px;border-bottom:1px solid #e9e0d1;margin:0 0 14px}'
    + '.sqc-item{border-bottom:1px solid #e9e0d1;padding:12px 0}'
    + '.sqc-item p{margin:0 0 5px;font-family:Georgia,serif;font-size:.98rem;line-height:1.5;color:#2e2a33;white-space:pre-line}'
    + '.sqc-meta{font-size:.73rem;color:#a49aa8;display:flex;gap:10px;align-items:center}'
    + '.sqc-meta button{border:0;background:none;cursor:pointer;font-size:.73rem;font-weight:600;color:#6f6674;padding:0}'
    + '.sqc-meta button:hover{color:#9a545f}'
    + '.sqc-empty{color:#a49aa8;font-size:.9rem;margin:0 0 14px}'
    + '.sqc-ta{width:100%;min-height:80px;border:1px solid #e9e0d1;border-radius:12px;background:#faf6ef;'
    + 'padding:11px 13px;font-family:Georgia,serif;font-size:.98rem;line-height:1.5;color:#2e2a33;resize:vertical;margin-top:14px}'
    + '.sqc-ta:focus{outline:none;border-color:#b76e79}'
    + '.sqc-send{margin-top:10px;width:100%;border:0;cursor:pointer;border-radius:999px;background:#2e2a33;color:#faf6ef;'
    + 'padding:12px 20px;font-size:.9rem;font-weight:600}'
    + '.sqc-send:disabled{opacity:.6}'

    /* ── a lighter setting ──────────────────────────────────────
       The page reads large: card text near 1.3rem in a serif, with
       section padding to match, so a phone shows very few words per
       screen and the gaps read as empty rather than calm. This trims
       both a notch. It is one block on purpose — every number is in
       one place, so it is easy to tune or delete. */
    + '.font-display{font-size:0.94em}'
    + 'blockquote.font-display{font-size:1.04rem;line-height:1.5}'
    + '@media(min-width:640px){blockquote.font-display{font-size:1.1rem}}'
    + 'section.py-24,div.py-24{padding-top:3.25rem;padding-bottom:3.25rem}'
    + '@media(min-width:640px){section.sm\\:py-28,div.sm\\:py-28{padding-top:4rem;padding-bottom:4rem}}'
    + '.gap-10{gap:1.75rem}.gap-8{gap:1.5rem}.mb-12{margin-bottom:2rem}.mb-14{margin-bottom:2.25rem}'
    + '.sqc-toast{position:fixed;left:50%;bottom:26px;transform:translate(-50%,14px);z-index:10000;background:#2e2a33;'
    + 'color:#faf6ef;padding:11px 18px;border-radius:999px;font-size:.86rem;font-family:ui-sans-serif,system-ui,sans-serif;'
    + 'opacity:0;pointer-events:none;transition:.25s;max-width:88vw;text-align:center}.sqc-toast.on{opacity:1;transform:translate(-50%,0)}';

  function el(tag, props, kids) {
    var n = document.createElement(tag);
    if (props) Object.keys(props).forEach(function (k) {
      if (k === 'text') n.textContent = props[k]; else n.setAttribute(k, props[k]);
    });
    (kids || []).forEach(function (k) { if (k) n.appendChild(k); });
    return n;
  }

  var toastEl, toastT;
  function toast(msg) {
    try {
      if (!toastEl) { toastEl = el('div', { class: 'sqc-toast' }); document.body.appendChild(toastEl); }
      toastEl.textContent = msg; toastEl.classList.add('on');
      clearTimeout(toastT); toastT = setTimeout(function () { toastEl.classList.remove('on'); }, 3000);
    } catch (e) {}
  }

  function ago(iso) {
    var d = (Date.now() - new Date(iso)) / 6e4;
    if (d < 1) return 'just now';
    if (d < 60) return Math.floor(d) + 'm ago';
    if (d < 1440) return Math.floor(d / 60) + 'h ago';
    if (d < 10080) return Math.floor(d / 1440) + 'd ago';
    return new Date(iso).toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
  }

  /* ── the overlay, owned by us and attached to <body> so React
        re-rendering a card cannot close it mid-sentence ── */
  var scrim, sheet;
  function ensureSheet() {
    if (sheet) return;
    scrim = el('div', { class: 'sqc-scrim' });
    sheet = el('div', { class: 'sqc-sheet', role: 'dialog', 'aria-modal': 'true', 'aria-label': 'Comments' });
    scrim.addEventListener('click', closeSheet);
    document.body.appendChild(scrim); document.body.appendChild(sheet);
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape') closeSheet(); });
  }
  function openSheet() { ensureSheet(); scrim.classList.add('on'); sheet.classList.add('on'); }
  function closeSheet() { if (sheet) { sheet.classList.remove('on'); scrim.classList.remove('on'); } }

  // 'quote' and 'feeling' are two parents of one comments table, so
  // only the RPC names differ.
  var RPCS = {
    quote:   { list: 'get_quote_comments',   add: 'add_quote_comment',   count: 'count_quote_comments',   key: 'p_quote' },
    feeling: { list: 'get_feeling_comments', add: 'add_feeling_comment', count: 'count_feeling_comments', key: 'p_feeling' },
  };

  function render(kind, id, text, countEl) {
    var api = RPCS[kind];
    ensureSheet();
    sheet.textContent = '';
    sheet.appendChild(el('p', { class: 'sqc-q', text: text }));
    var list = el('div');
    sheet.appendChild(list);

    var ta = el('textarea', { class: 'sqc-ta', maxlength: '500',
      placeholder: 'Say something about this…', 'aria-label': 'Your comment' });
    var send = el('button', { class: 'sqc-send', type: 'button', text: 'Comment anonymously' });
    sheet.appendChild(ta); sheet.appendChild(send);

    function load() {
      var args = { p_visitor: VISITOR, p_page: 0 }; args[api.key] = id;
      rpc(api.list, args)
        .then(function (rows) {
          rows = rows || [];
          list.textContent = '';
          if (countEl) countEl.textContent = rows.length ? String(rows.length) : '';
          if (!rows.length) {
            list.appendChild(el('p', { class: 'sqc-empty', text: 'No one has said anything yet. You could be first.' }));
            return;
          }
          rows.forEach(function (c) {
            var meta = el('div', { class: 'sqc-meta' }, [el('span', { text: 'Anonymous · ' + ago(c.created_at) })]);
            var act = el('button', { type: 'button', text: c.mine ? 'Delete' : 'Report' });
            act.addEventListener('click', function () {
              var fn = c.mine ? 'delete_my_quote_comment' : 'report_quote_comment';
              var args = c.mine ? { p_id: c.id, p_visitor: VISITOR }
                                : { p_id: c.id, p_visitor: VISITOR, p_reason: 'Other' };
              rpc(fn, args).then(function () {
                toast(c.mine ? 'Gone.' : 'Thank you. Someone will look.');
                if (c.mine) load();
              }).catch(function () { toast('That didn’t work. Try again?'); });
            });
            meta.appendChild(act);
            list.appendChild(el('div', { class: 'sqc-item' },
              [el('p', { text: c.body }), meta]));
          });
        })
        .catch(function () {
          list.textContent = '';
          list.appendChild(el('p', { class: 'sqc-empty', text: 'Couldn’t load comments just now.' }));
        });
    }

    send.addEventListener('click', function () {
      var v = (ta.value || '').trim();
      if (v.length < 2) { toast('A few words, whenever you’re ready.'); ta.focus(); return; }
      send.disabled = true; send.textContent = 'Posting…';
      var post = { p_visitor: VISITOR, p_body: v }; post[api.key] = id;
      rpc(api.add, post)
        .then(function (r) {
          if (r && r.ok === false) toast(r.message || 'That one couldn’t be posted.');
          else { toast((r && r.message) || 'Posted. \u{1F90D}'); ta.value = ''; load(); }
        })
        .catch(function (e) {
          toast(e.status === 404 ? 'Comments aren’t switched on yet.' : 'Something went wrong. Please try again.');
        })
        .then(function () { send.disabled = false; send.textContent = 'Comment anonymously'; });
    });

    load();
    openSheet();
  }


  /* ── the share card, refitted ─────────────────────────────────
     The app draws its card at 1080×1350 with a fixed 64px face, so
     a long poem runs straight off the edge and over the wordmark.
     It cannot be fixed in the app — no source — so the canvas is
     repainted after the app has drawn it, at a size that actually
     fits. The background is sampled from the app's own render, so
     the theme swatches keep working without knowing their colours.

     Text that still cannot fit at the smallest readable size is cut
     with an ellipsis rather than overflowing: a card that is honest
     about being an excerpt beats one that is unreadable. */

  var CARD_SEL = 'canvas[aria-label="Share card preview"]';

  function wrap(ctx, text, maxWidth) {
    var lines = [];
    String(text).split('\n').forEach(function (para) {
      if (!para.trim()) { lines.push(''); return; }
      var line = '';
      para.trim().split(/\s+/).forEach(function (w) {
        var test = line ? line + ' ' + w : w;
        if (ctx.measureText(test).width > maxWidth && line) { lines.push(line); line = w; }
        else line = test;
      });
      lines.push(line);
    });
    return lines;
  }

  function repaintCard(text) {
    var cv = document.querySelector(CARD_SEL);
    if (!cv || !cv.width || !text) return false;
    var ctx = cv.getContext('2d');
    if (!ctx) return false;

    var W = cv.width, H = cv.height;

    // sample the theme the app just painted
    var bg = '#faf6ef', ink = '#2e2a33';
    try {
      var px = ctx.getImageData(6, 6, 1, 1).data;
      bg = 'rgb(' + px[0] + ',' + px[1] + ',' + px[2] + ')';
      var dark = (px[0] * 299 + px[1] * 587 + px[2] * 114) / 1000 < 128;
      ink = dark ? '#f3ece3' : '#2e2a33';
    } catch (e) {}

    var padX = Math.round(W * 0.11), padTop = Math.round(H * 0.13);
    var footer = Math.round(H * 0.16);
    var maxW = W - padX * 2, maxH = H - padTop - footer;

    // largest size that fits, then trim if even the smallest will not
    var size = 64, lines = [], lh = 1;
    for (; size >= 22; size -= 2) {
      ctx.font = 'italic 500 ' + size + 'px "Cormorant Garamond", Georgia, serif';
      lh = size * 1.42;
      lines = wrap(ctx, text, maxW);
      if (lines.length * lh <= maxH) break;
    }
    var fits = Math.floor(maxH / lh);
    var cut = lines.length > fits;
    if (cut) { lines = lines.slice(0, Math.max(1, fits - 1)); lines.push('…'); }

    ctx.fillStyle = bg; ctx.fillRect(0, 0, W, H);

    // the frame the original card has
    ctx.strokeStyle = ink; ctx.globalAlpha = 0.16; ctx.lineWidth = 2;
    ctx.strokeRect(padX * 0.55, padX * 0.55, W - padX * 1.1, H - padX * 1.1);
    ctx.globalAlpha = 1;

    ctx.fillStyle = ink;
    ctx.textAlign = 'center';
    ctx.font = 'italic 500 ' + size + 'px "Cormorant Garamond", Georgia, serif';
    var blockH = lines.length * lh;
    var y = padTop + Math.max(0, (maxH - blockH) / 2) + lh * 0.78;
    lines.forEach(function (l) { ctx.fillText(l, W / 2, y); y += lh; });

    // wordmark, on its own ground so nothing can ever sit on it
    ctx.font = '500 46px "Cormorant Garamond", Georgia, serif';
    ctx.fillText('SeRuh', W / 2, H - footer * 0.52);
    ctx.globalAlpha = 0.6;
    ctx.font = '400 26px Karla, ui-sans-serif, system-ui, sans-serif';
    ctx.fillText('Where Feelings Find Words', W / 2, H - footer * 0.28);
    ctx.globalAlpha = 1;
    ctx.textAlign = 'start';
    return true;
  }

  /* The app repaints on open and on every theme swatch, so retry for
     a moment and repaint again after any click inside the dialog. */
  var shareText = null;
  function chaseCard() {
    if (!shareText) return;
    var tries = 0;
    var t = setInterval(function () {
      if (repaintCard(shareText) || ++tries > 16) clearInterval(t);
      else tries++;
    }, 140);
  }

  document.addEventListener('click', function (e) {
    try {
      var t = e.target && e.target.closest ? e.target.closest('button') : null;
      if (!t) return;
      var label = t.getAttribute('aria-label') || '';
      if (label === 'Share this feeling' || label === 'Share this quote') {
        var card = t, bq = null, hops = 0;
        while (card && hops++ < 8) { bq = card.querySelector && card.querySelector('blockquote'); if (bq) break; card = card.parentElement; }
        shareText = bq ? bq.textContent.replace(/^[\s“"']+|[\s”"']+$/g, '') : null;
        chaseCard();
      } else if (shareText && document.querySelector(CARD_SEL)) {
        // a theme swatch or another control inside the open dialog
        setTimeout(function () { repaintCard(shareText); }, 120);
      }
    } catch (err) {}
  }, true);

  /* ── attach to the cards the app renders ── */
  var maps = null;   // { quote: {text:id}, feeling: {text:id} }

  function enhance() {
    if (!maps) return;
    var copies = document.querySelectorAll(
      'button[aria-label="Copy this quote"], button[aria-label="Copy this feeling"]');
    for (var i = 0; i < copies.length; i++) {
      var btn = copies[i];
      var kind = btn.getAttribute('aria-label') === 'Copy this feeling' ? 'feeling' : 'quote';
      var row = btn.parentElement;
      if (!row || row.hasAttribute(MARK)) continue;

      // walk up until we find the card that holds the quote text
      var card = row, bq = null, hops = 0;
      while (card && hops++ < 6) {
        bq = card.querySelector ? card.querySelector('blockquote') : null;
        if (bq) break;
        card = card.parentElement;
      }
      if (!bq) continue;

      var id = maps[kind][norm(bq.textContent)];
      if (!id) continue;                       // something we don't have an id for

      row.setAttribute(MARK, '1');
      (function (kind, id, text, row) {
        var count = el('span', { text: '' });
        var b = el('button', { class: 'sqc-btn', type: 'button',
          'aria-label': 'Comments on this ' + kind });
        b.appendChild(document.createTextNode('\u{1F4AC} '));
        b.appendChild(count);
        b.addEventListener('click', function (e) { e.preventDefault(); render(kind, id, text, count); });
        row.appendChild(b);

        var cargs = {}; cargs[RPCS[kind].key] = id;
        rpc(RPCS[kind].count, cargs)
          .then(function (n) { if (n) count.textContent = String(n); })
          .catch(function () {});
      })(kind, id, bq.textContent, row);
    }
  }

  var pending;
  function schedule() { clearTimeout(pending); pending = setTimeout(function () { try { enhance(); } catch (e) {} }, 180); }

  function start() {
    // does the backend have comments at all? if not, add nothing.
    rpc('get_quote_comments', { p_quote: '00000000-0000-0000-0000-000000000000', p_visitor: VISITOR, p_page: 0 })
      .then(function () {
        var h = { headers: { apikey: KEY, 'Accept-Profile': SCHEMA } };
        return Promise.all([
          fetch(API + '/rest/v1/quotes_public?select=id,quote&limit=1000', h).then(function (r) { return r.json(); }),
          fetch(API + '/rest/v1/feelings_public?select=id,content&limit=1000', h).then(function (r) { return r.json(); }),
        ]);
      })
      .then(function (both) {
        maps = { quote: {}, feeling: {} };
        (both[0] || []).forEach(function (q) { maps.quote[norm(q.quote)] = q.id; });
        (both[1] || []).forEach(function (f) { maps.feeling[norm(f.content)] = f.id; });
        document.head.appendChild(el('style', { text: CSS }));
        enhance();
        new MutationObserver(schedule).observe(document.body, { childList: true, subtree: true });
      })
      .catch(function () { /* comments unavailable — leave the page untouched */ });
  }

  try {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
    else start();
  } catch (e) { /* never break the page */ }
})();
