// TV remote.
const resource = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'xex_tv';
const $ = (id) => document.getElementById(id);

const icons = {
  play: '<path d="M7 4v16l13-8z" fill="currentColor" stroke="none"/>',
  pause: '<path d="M7 4h3v16H7zM14 4h3v16h-3z" fill="currentColor" stroke="none"/>',
  next: '<path d="M5 4v16l10-8z" fill="currentColor" stroke="none"/><path d="M19 5v14"/>',
  loop: '<path d="m17 2 4 4-4 4"/><path d="M3 11v-1a4 4 0 0 1 4-4h14"/><path d="m7 22-4-4 4-4"/><path d="M21 13v1a4 4 0 0 1-4 4H3"/>',
  resync: '<path d="M21 12a9 9 0 1 1-3-6.7L21 8"/><path d="M21 3v5h-5"/>',
  power: '<path d="M12 2v10"/><path d="M18.4 6.6a9 9 0 1 1-12.8 0"/>',
  remove: '<path d="M18 6 6 18M6 6l12 12"/>',
  chDown: '<path d="m6 9 6 6 6-6"/>',
  chUp: '<path d="m18 15-6-6-6 6"/>',
};

const svg = (name, size = 18) =>
  `<svg viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${icons[name]}</svg>`;

let texts = {};
let config = {};
let state = null;
let stateAt = 0;
let canControl = false;
let busy = false;
let toastTimer = null;
let pendingVolume = null;

const fmt = (s, ...args) => args.reduce((out, a) => out.replace('%s', a), s || '');

function post(name, body = {}) {
  return fetch(`https://${resource}/${name}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=UTF-8' },
    body: JSON.stringify(body),
  }).then((r) => r.json().catch(() => ({})));
}

function applyUi(ui) {
  const root = document.documentElement.style;
  if (ui.accent) {
    root.setProperty('--accent', ui.accent);
    const hex = ui.accent.replace('#', '');
    if (hex.length === 6) {
      const [r, g, b] = [0, 2, 4].map((i) => parseInt(hex.slice(i, i + 2), 16));
      root.setProperty('--accent-soft', `rgba(${r}, ${g}, ${b}, 0.12)`);
      // Dark text on light accents, light text on dark ones.
      root.setProperty('--on-accent', 0.299 * r + 0.587 * g + 0.114 * b > 150 ? '#0d1015' : '#ffffff');
    }
  }
  $('brand').textContent = ui.brand || '';
  $('title').textContent = ui.title || '';
}

function applyTexts() {
  document.querySelectorAll('[data-t]').forEach((el) => (el.textContent = texts[el.dataset.t] || ''));
  document.querySelectorAll('[data-title]').forEach((el) => (el.title = texts[el.dataset.title] || ''));
  $('source').placeholder = texts.ui_paste || '';

  // What the link field accepts on this server, in a fixed order.
  const sources = config.sources || {};
  const kinds = ['youtube', 'vimeo', 'archive', 'direct']
    .filter((kind) => sources[kind] && texts[`kind_${kind}`])
    .map((kind) => texts[`kind_${kind}`]);
  $('hint').textContent = kinds.length ? `${texts.ui_sources}: ${kinds.join(' · ')}` : '';
}

function clock(seconds) {
  seconds = Math.max(0, Math.floor(seconds || 0));
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = String(seconds % 60).padStart(2, '0');
  return h ? `${h}:${String(m).padStart(2, '0')}:${s}` : `${m}:${s}`;
}

function currentTime() {
  if (!state) return 0;
  let t = state.currentTime || 0;
  if (state.playing) t += (Date.now() - stateAt) / 1000;
  return state.duration ? Math.min(t, state.duration) : t;
}

function toast(message, ok = true) {
  const el = $('toast');
  el.textContent = message || '';
  el.className = `toast show${ok ? '' : ' error'}`;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (el.className = 'toast'), 3500);
}

function setVolumeFill(input) {
  input.style.setProperty('--fill', `${input.value}%`);
  $('volume-out').textContent = input.value;
}

function renderTimeline() {
  const timeline = $('timeline');
  if (!state) {
    timeline.hidden = true;
    return;
  }
  timeline.hidden = false;
  const track = $('track');
  // Channels show their progress but can't be seeked.
  const timed = !!(state.seekable || (state.channel && state.duration));
  const live = !timed || !state.duration;
  track.classList.toggle('live', !timed);
  track.classList.toggle('seekable', !!(state.seekable && state.duration && canControl));
  $('t-cur').textContent = timed ? clock(currentTime()) : texts.ui_live;
  $('t-dur').textContent = state.duration ? clock(state.duration) : '';
  $('track-fill').style.width = live ? '0%' : `${(currentTime() / state.duration) * 100}%`;
}

function render() {
  const on = !!state;
  const media = on ? state.media || {} : {};

  const onChannel = on && !!state.channel;
  const kind = $('kind');
  const channelName = onChannel ? [state.channelNumber, state.channelLabel || state.channel].filter(Boolean).join(' · ') : '';
  kind.textContent = !on ? texts.ui_off
    : onChannel ? `${texts.ui_on_air} · ${channelName}`
    : state.live ? `${texts.ui_live} · ${texts[`kind_${media.kind}`] || media.kind}`
    : texts[`kind_${media.kind}`] || media.kind;
  kind.className = `kind${on ? '' : ' off'}${onChannel || (on && state.live) ? ' air' : ''}`;
  $('by').textContent = on && state.updatedBy && !onChannel ? fmt(texts.ui_started_by, state.updatedBy) : '';
  $('now-title').textContent = on ? state.title || media.label || (onChannel ? texts.ui_starting : '') : '';
  $('now-title').hidden = !on;

  const toggle = $('btn-toggle');
  toggle.innerHTML = svg(on && state.playing ? 'pause' : 'play', 20);
  toggle.title = on && state.playing ? texts.ui_pause : texts.ui_resume;
  $('btn-next').innerHTML = svg('next');
  $('btn-loop').innerHTML = svg('loop');
  $('btn-resync').innerHTML = svg('resync');
  $('btn-stop').innerHTML = svg('power');
  $('btn-ch-down').innerHTML = svg('chDown', 20);
  $('btn-ch-up').innerHTML = svg('chUp', 20);
  $('btn-loop').setAttribute('aria-pressed', String(on && !!state.loop));

  const queue = on && Array.isArray(state.queue) ? state.queue : [];
  const controlsOff = !on || !canControl || busy;
  ['btn-resync', 'btn-stop'].forEach((id) => ($(id).disabled = controlsOff));
  // A channel follows the server: no pause, next or loop, but channel up and down like a TV.
  ['btn-toggle', 'btn-next', 'btn-loop'].forEach((id) => ($(id).hidden = onChannel));
  ['btn-ch-down', 'btn-ch-up'].forEach((id) => {
    $(id).hidden = !onChannel;
    $(id).disabled = controlsOff || channelList().length < 2;
  });
  $('btn-toggle').disabled = controlsOff;
  $('btn-loop').disabled = controlsOff;
  $('btn-next').disabled = controlsOff || queue.length === 0;
  $('channel-note').hidden = !onChannel;
  $('controls').hidden = !on;
  $('volume-row').hidden = !on;

  const volume = $('volume');
  if (on && document.activeElement !== volume) volume.value = state.volume ?? 0;
  volume.disabled = controlsOff;
  setVolumeFill(volume);

  $('locked').hidden = canControl;
  $('add').hidden = !canControl;
  $('btn-play').disabled = busy;
  $('btn-queue').disabled = busy;
  $('btn-queue').hidden = !(config.queue && config.queue.enabled) || onChannel;
  $('play-row').classList.toggle('single', $('btn-queue').hidden);

  const channels = channelList();
  $('btn-guide').hidden = channels.length === 0;
  $('guide-count').textContent = channels.length ? String(channels.length) : '';
  $('btn-library').hidden = !config.library;
  $('browse').hidden = $('btn-guide').hidden && $('btn-library').hidden;
  $('browse').classList.toggle('single', $('btn-guide').hidden !== $('btn-library').hidden);

  $('queue-box').hidden = !(config.queue && config.queue.enabled) || !on || onChannel;
  $('queue-count').textContent = queue.length ? `${queue.length}/${config.queue.maxItems}` : '';
  $('queue-empty').hidden = queue.length > 0;
  const list = $('queue');
  list.replaceChildren();
  queue.forEach((item, i) => {
    const li = document.createElement('li');
    const text = document.createElement('span');
    text.className = 'q-text';
    const k = document.createElement('span');
    k.className = 'q-kind';
    k.textContent = texts[`kind_${item.kind}`] || item.kind;
    text.append(k, document.createTextNode(item.label || ''));
    li.append(text);
    if (canControl) {
      const remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'icon-btn';
      remove.title = texts.ui_remove;
      remove.innerHTML = svg('remove', 14);
      remove.disabled = busy;
      remove.addEventListener('click', () => send('unqueue', i + 1));
      li.append(remove);
    } else {
      li.append(document.createElement('span'));
    }
    list.append(li);
  });

  renderTimeline();
  if (!$('library').hidden) renderLibrary();
  if (!$('guide').hidden) renderGuide();
}

// Channel guide -----------------------------------------------------------------------------------

const guide = { category: null };

function channelList() {
  return Array.isArray(config.channels) ? config.channels : [];
}

function tune(channel) {
  send('tune', { channel: channel.id, volume: Number($('volume').value) });
}

// Channel up / down, wrapping around like a TV.
function step(delta) {
  const channels = channelList();
  if (!state || !state.channel || channels.length < 2) return;
  const index = channels.findIndex((c) => c.id === state.channel);
  tune(channels[(index + delta + channels.length) % channels.length]);
}

const categoryLabel = (category) => texts[`category_${category}`] || category.charAt(0).toUpperCase() + category.slice(1);

function renderGuide() {
  const channels = channelList();
  const categories = [...new Set(channels.map((c) => c.category).filter(Boolean))];
  if (guide.category && !categories.includes(guide.category)) guide.category = null;

  const chips = $('guide-categories');
  chips.replaceChildren();
  chips.hidden = categories.length < 2;
  [null, ...categories].forEach((category) => {
    const chip = document.createElement('button');
    chip.type = 'button';
    chip.className = 'chip';
    chip.textContent = category ? categoryLabel(category) : texts.ui_all;
    chip.setAttribute('aria-pressed', String(guide.category === category));
    chip.addEventListener('click', () => {
      guide.category = category;
      renderGuide();
    });
    chips.append(chip);
  });

  const list = $('guide-list');
  list.replaceChildren();
  channels
    .filter((c) => !guide.category || c.category === guide.category)
    .forEach((channel) => {
      const li = document.createElement('li');
      const row = document.createElement('button');
      row.type = 'button';
      row.className = 'guide-row';
      row.disabled = busy || !canControl;
      row.setAttribute('aria-pressed', String(!!state && state.channel === channel.id));

      const number = document.createElement('span');
      number.className = 'guide-num';
      number.textContent = channel.number || '';

      const text = document.createElement('span');
      text.className = 'guide-text';
      const name = document.createElement('span');
      name.className = 'guide-name';
      name.textContent = channel.label;
      const now = document.createElement('span');
      now.className = 'guide-now';
      now.textContent = channel.title || (channel.kind ? texts[`kind_${channel.kind}`] : texts.ui_starting) || '';
      text.append(name, now);

      const tag = document.createElement('span');
      tag.className = `guide-tag${channel.live ? ' live' : ''}`;
      tag.textContent = channel.live ? texts.ui_live : channel.category ? categoryLabel(channel.category) : '';

      row.append(number, text, tag);
      row.addEventListener('click', () => tune(channel));
      li.append(row);
      list.append(li);
    });
}

async function toggleGuide(open) {
  $('guide').hidden = !open;
  if (!open) return;
  $('library').hidden = true;
  renderGuide();
  // What each channel airs changes over time: ask again when the guide opens.
  const res = await post('channels');
  if (res && Array.isArray(res.channels)) {
    config.channels = res.channels;
    render();
  }
}

// Library -----------------------------------------------------------------------------------------

const library = { query: '', genre: null, page: 1, items: [], hasMore: false, featured: true, loading: false, error: null };

function renderLibrary() {
  const genres = (config.library && config.library.genres) || [];
  const chips = $('lib-genres');
  chips.replaceChildren();
  genres.forEach((genre) => {
    const chip = document.createElement('button');
    chip.type = 'button';
    chip.className = 'chip';
    chip.textContent = texts[`genre_${genre}`] || genre;
    chip.setAttribute('aria-pressed', String(library.genre === genre));
    chip.disabled = library.loading;
    chip.addEventListener('click', () => {
      library.genre = library.genre === genre ? null : genre;
      loadLibrary(true);
    });
    chips.append(chip);
  });

  $('lib-heading').textContent = library.featured ? texts.ui_featured : texts.ui_results;

  const grid = $('lib-grid');
  grid.replaceChildren();
  library.items.forEach((item) => {
    const card = document.createElement('article');
    card.className = 'film';

    const poster = document.createElement('div');
    poster.className = 'poster';
    const initial = document.createElement('span');
    initial.className = 'poster-initial';
    initial.textContent = (item.title || '?').trim().charAt(0);
    const img = document.createElement('img');
    img.alt = '';
    img.loading = 'lazy';
    img.src = `https://archive.org/services/img/${encodeURIComponent(item.id)}`;
    img.addEventListener('error', () => img.remove());

    const actions = document.createElement('div');
    actions.className = 'film-actions';
    const watch = document.createElement('button');
    watch.type = 'button';
    watch.className = 'btn primary';
    watch.textContent = texts.ui_watch;
    watch.disabled = busy;
    watch.addEventListener('click', () =>
      send('play', { source: `archive:${item.id}`, volume: Number($('volume').value) }),
    );
    actions.append(watch);
    if (config.queue && config.queue.enabled && state && !state.channel) {
      const queue = document.createElement('button');
      queue.type = 'button';
      queue.className = 'btn ghost';
      queue.textContent = texts.ui_queue_short;
      queue.disabled = busy;
      queue.addEventListener('click', () => send('queue', { source: `archive:${item.id}` }));
      actions.append(queue);
    }
    poster.append(initial, img, actions);

    const title = document.createElement('p');
    title.className = 'film-title';
    title.textContent = item.title;
    title.title = item.title;
    const year = document.createElement('p');
    year.className = 'film-year';
    year.textContent = item.year || '';

    card.append(poster, title, year);
    grid.append(card);
  });

  const status = $('lib-status');
  const message = library.loading ? texts.ui_searching : library.error || (library.items.length ? '' : texts.ui_no_results);
  status.textContent = message || '';
  status.hidden = !message;
  status.classList.toggle('error', !!library.error && !library.loading);
  $('lib-more').hidden = library.loading || !library.hasMore;
}

async function loadLibrary(reset) {
  if (library.loading) return;
  if (reset) {
    library.page = 1;
    library.items = [];
  }
  library.loading = true;
  library.error = null;
  renderLibrary();

  const res = await post('library', { query: library.query, genre: library.genre, page: library.page });
  library.loading = false;
  if (res && res.ok) {
    const items = Array.isArray(res.items) ? res.items : [];
    library.items = reset ? items : library.items.concat(items);
    library.hasMore = !!res.hasMore;
    library.featured = !!res.featured;
  } else {
    if (!reset) library.page = Math.max(1, library.page - 1);
    library.error = (res && res.message) || texts.ui_no_results;
  }
  renderLibrary();
}

function toggleLibrary(open) {
  $('library').hidden = !open;
  if (!open) return;
  $('guide').hidden = true;
  renderLibrary();
  if (!library.items.length && !library.loading) loadLibrary(true);
  $('lib-query').focus();
}

async function send(action, value) {
  if (busy) return;
  busy = true;
  render();
  const res = await post('action', { action, value });
  busy = false;
  if (res && res.message) toast(res.message, res.ok);
  if (res && res.ok && (action === 'play' || action === 'queue')) $('source').value = '';
  render();
  if (pendingVolume !== null) {
    const volume = pendingVolume;
    pendingVolume = null;
    send('volume', volume);
  }
}

function setState(next) {
  state = next || null;
  stateAt = Date.now();
  render();
}

function close() {
  $('remote').hidden = true;
  $('library').hidden = true;
  $('guide').hidden = true;
  post('close');
}

// Controls ----------------------------------------------------------------------------------------

$('close').addEventListener('click', close);
$('btn-toggle').addEventListener('click', () => send('togglePause'));
$('btn-next').addEventListener('click', () => send('next'));
$('btn-loop').addEventListener('click', () => send('loop'));
$('btn-resync').addEventListener('click', () => send('refresh'));
$('btn-stop').addEventListener('click', () => send('stop'));
$('btn-ch-down').addEventListener('click', () => step(-1));
$('btn-ch-up').addEventListener('click', () => step(1));
$('btn-play').addEventListener('click', () => {
  const source = $('source').value.trim();
  if (source) send('play', { source, volume: Number($('volume').value) });
});
$('btn-queue').addEventListener('click', () => {
  const source = $('source').value.trim();
  if (source) send('queue', { source });
});
$('source').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') $('btn-play').click();
});

$('btn-library').addEventListener('click', () => toggleLibrary($('library').hidden));
$('lib-close').addEventListener('click', () => toggleLibrary(false));
$('btn-guide').addEventListener('click', () => toggleGuide($('guide').hidden));
$('guide-close').addEventListener('click', () => toggleGuide(false));
$('lib-form').addEventListener('submit', (e) => {
  e.preventDefault();
  library.query = $('lib-query').value.trim();
  loadLibrary(true);
});
$('lib-more').addEventListener('click', () => {
  library.page += 1;
  loadLibrary(false);
});

$('volume').addEventListener('input', (e) => setVolumeFill(e.target));
$('volume').addEventListener('change', (e) => {
  if (busy) pendingVolume = Number(e.target.value);
  else send('volume', Number(e.target.value));
});

$('track').addEventListener('click', (e) => {
  if (!state || !state.seekable || !state.duration || !canControl) return;
  const rect = e.currentTarget.getBoundingClientRect();
  const ratio = Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width));
  send('seek', Math.floor(ratio * state.duration));
});

$('mute').addEventListener('change', async () => {
  const res = await post('mute');
  $('mute').checked = !!res.localMute;
});

document.addEventListener('keydown', (e) => {
  if (e.key !== 'Escape' || $('remote').hidden) return;
  if (!$('library').hidden) toggleLibrary(false);
  else if (!$('guide').hidden) toggleGuide(false);
  else close();
});

setInterval(() => {
  if (!$('remote').hidden) renderTimeline();
}, 500);

window.addEventListener('message', ({ data }) => {
  if (!data || typeof data !== 'object') return;

  if (data.action === 'open') {
    texts = data.texts || {};
    config = { channels: data.channels, queue: data.queue, sources: data.sources, library: data.library };
    canControl = !!data.canControl;
    applyUi(data.ui || {});
    applyTexts();
    $('screen-label').textContent = data.screenLabel || '';
    $('mute').checked = !!data.localMute;
    $('source').value = '';
    $('lib-query').placeholder = texts.ui_library_search || '';
    $('library').hidden = true;
    $('guide').hidden = true;
    $('toast').className = 'toast';
    setState(data.state);
    $('remote').hidden = false;
    if (canControl) $('source').focus();
  } else if (data.action === 'state') {
    if ('localMute' in data) $('mute').checked = !!data.localMute;
    setState(data.state);
  }
});
