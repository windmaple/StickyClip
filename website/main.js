// StickyClip home page — small, dependency-free interactions.
(() => {
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

  /* ---------- menu-bar clock (like the real one) ---------- */
  const clock = $('#clock');
  const tick = () => {
    const d = new Date();
    clock.textContent = d.toLocaleString(undefined, { weekday: 'short', day: 'numeric', month: 'short' }) +
      '  ' + d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
  };
  tick();
  setInterval(tick, 15_000);

  /* ---------- toast ---------- */
  const toast = $('#toast');
  let toastTimer;
  const showToast = (msg) => {
    toast.textContent = msg;
    toast.classList.add('is-visible');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove('is-visible'), 1800);
  };

  const copyText = async (text) => {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch {
      // Fallback for non-secure contexts / older browsers.
      const ta = Object.assign(document.createElement('textarea'), { value: text });
      ta.style.cssText = 'position:fixed;opacity:0';
      document.body.append(ta);
      ta.select();
      const ok = document.execCommand('copy');
      ta.remove();
      return ok;
    }
  };

  /* ---------- the clothesline ---------- */
  const line = $('#line');
  const notes = $$('.note[role="option"]', line);
  let selected = -1;

  const select = (i) => {
    selected = (i + notes.length) % notes.length;
    notes.forEach((n, j) => {
      n.classList.toggle('is-selected', j === selected);
      n.setAttribute('aria-selected', j === selected);
    });
    notes[selected].scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'smooth' });
  };

  const pick = async (note) => {
    const text = note.dataset.copy;
    if (!text) {
      showToast('In the app, images paste as images ✨');
      return;
    }
    if (await copyText(text)) showToast('Copied! Now press ⌘V anywhere');
  };

  notes.forEach((note, i) => {
    note.addEventListener('click', () => { select(i); pick(note); });
  });

  line.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowRight' || (e.key === 'Tab' && !e.shiftKey && selected < notes.length - 1)) {
      e.preventDefault(); select(selected + 1);
    } else if (e.key === 'ArrowLeft' || (e.key === 'Tab' && e.shiftKey && selected > 0)) {
      e.preventDefault(); select(selected - 1);
    } else if (e.key === 'Enter' && selected >= 0) {
      e.preventDefault(); pick(notes[selected]);
    } else if (e.metaKey && /^[1-6]$/.test(e.key)) {
      e.preventDefault(); const i = +e.key - 1; select(i); pick(notes[i]);
    } else if (e.key === 'Escape') {
      selected = -1; notes.forEach((n) => n.classList.remove('is-selected')); line.blur();
    }
  });
  line.addEventListener('focus', () => { if (selected < 0) select(0); });

  // Re-run the drop-down: switching animation-name restarts it.
  const replay = () => {
    line.classList.toggle('is-replaying');
    $('#top').scrollIntoView({ behavior: 'smooth' });
  };
  $('#replay').addEventListener('click', replay);
  document.addEventListener('keydown', (e) => {
    if (e.shiftKey && (e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'v') {
      e.preventDefault();
      replay();
    }
  });

  /* ---------- styles switcher ---------- */
  const captions = {
    clothesline: 'Notes swing in on clothespins. Slide along the line with ← → or scroll.',
    whiteboard: 'A clean whiteboard, with magnets and markers.',
    cork: 'Pushpins on cork — for the analogue at heart.',
    chalkboard: 'Chalk on slate. Easy on the eyes after dark.',
  };
  const stylesEl = $('.styles');
  const tabs = $$('[role="tab"]', stylesEl);
  const imgs = $$('.styles__stage img', stylesEl);
  const caption = $('#style-caption');
  const panel = $('#style-panel');

  const setStyle = (name, focus = false) => {
    stylesEl.dataset.active = name;
    tabs.forEach((t) => {
      const on = t.dataset.style === name;
      t.setAttribute('aria-selected', on);
      t.tabIndex = on ? 0 : -1;
      if (on) { panel.setAttribute('aria-labelledby', t.id); if (focus) t.focus(); }
    });
    imgs.forEach((img) => img.classList.toggle('is-active', img.dataset.style === name));
    caption.textContent = captions[name];
  };

  tabs.forEach((t, i) => {
    t.tabIndex = i === 0 ? 0 : -1;
    t.addEventListener('click', () => setStyle(t.dataset.style));
    t.addEventListener('keydown', (e) => {
      const dir = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0;
      if (!dir) return;
      e.preventDefault();
      setStyle(tabs[(i + dir + tabs.length) % tabs.length].dataset.style, true);
    });
  });

  /* ---------- code copy buttons ---------- */
  $$('.code__copy').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const text = document.getElementById(btn.dataset.copyTarget).textContent;
      if (await copyText(text)) {
        btn.textContent = 'Copied';
        btn.classList.add('is-done');
        setTimeout(() => { btn.textContent = 'Copy'; btn.classList.remove('is-done'); }, 1600);
      }
    });
  });
})();
