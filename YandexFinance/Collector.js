// Runs only on the bank history page. V19 keeps the V19 fast path and hardens startup recovery from a half-open mobile period sheet.
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const text = el => (el?.innerText || '').replace(/\u200b/g, '').trim();
const controls = () => [...document.querySelectorAll('button,[role="button"]')];
const linkedRows = () => [...document.querySelectorAll('a[href*="/my/transactions-history/operation"]')];
const moneyPattern = /[+−–-]\s*[\d\s.,]+\s*₽/;
const onCard = () => location.pathname.replace(/\/$/, '') === '/my/transactions-history/operation';
const controlName = el => [text(el), el.getAttribute('aria-label'), el.getAttribute('title')].filter(Boolean).join(' ').trim();
const backActionables = () => [...document.querySelectorAll('button,[role="button"],a[href]')];
function operationBackCandidates() {
  const viewportWidth = Math.max(320, Number(window.innerWidth) || 430);
  return backActionables().filter(isVisible).map(el => {
    const rect = el.getBoundingClientRect?.() || {left: 9999, top: 9999, width: 0, height: 0};
    const name = controlName(el);
    const href = el.getAttribute?.('href') || '';
    const testID = [el.getAttribute?.('data-testid'), el.getAttribute?.('data-qa'), el.getAttribute?.('data-name')]
      .filter(Boolean).join(' ');
    const labelled = /(?:^|\s)(?:Назад|Вернуться|Back)(?:\s|$)/i.test(name + ' ' + testID);
    const directHistory = /\/my\/transactions-history\/?(?:[?#].*)?$/.test(href);
    const iconLike = !!el.querySelector?.('svg') && rect.width > 0 && rect.height > 0 &&
      rect.left <= Math.min(150, viewportWidth * 0.34) && rect.top <= 240 &&
      rect.width <= 150 && rect.height <= 130;
    const score = labelled ? 0 : directHistory ? 1 : iconLike ? 2 : 99;
    return {el, score, left: rect.left, top: rect.top};
  }).filter(x => x.score < 99)
    .sort((a, b) => a.score - b.score || a.top - b.top || a.left - b.left)
    .map(x => x.el);
}
function historyScreenReady() {
  if (onCard()) return false;
  if (!location.pathname.startsWith('/my/transactions-history')) return false;
  // Returning from a mobile operation can briefly reopen the history filter sheet.
  // The route has already left /operation, so accept that state and let the normal
  // filter cleanup below close the sheet before scanning continues.
  return activeSwitches().length > 0 || rows().length > 0 || !!selectedMonthControl() ||
    controls().some(el => /История/i.test(controlName(el))) || /(?:^|\n)История(?:\n|$)/i.test(text(document.body));
}
async function waitForHistoryReturn(timeout = 2200) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (window.__financeCancelled) throw Error('Чтение отменено пользователем.');
    if (historyScreenReady()) return true;
    await sleep(70);
  }
  return historyScreenReady();
}
async function leaveOperationCard() {
  if (!onCard()) return true;
  const tried = new Set();
  const candidates = operationBackCandidates();
  for (const back of candidates) {
    if (tried.has(back)) continue;
    tried.add(back);
    try { back.click(); } catch { continue; }
    if (await waitForHistoryReturn(1800)) return true;
  }
  try { window.history.back(); } catch { }
  if (await waitForHistoryReturn(2600)) return true;

  // Some bank shells swallow the first History API navigation while keeping the
  // operation route mounted. Retry any still-visible back control once more after
  // the failed history.back(), because the shell may have changed its active layer.
  for (const back of operationBackCandidates()) {
    try { back.click(); } catch { continue; }
    if (await waitForHistoryReturn(1800)) return true;
  }
  const failure = Error('Не удалось вернуться из карточки операции к списку истории. Уже прочитанные операции сохранены.');
  failure.code = 'NAVIGATION_FAILED';
  throw failure;
}
const rows = () => {
  if (onCard()) return [];
  let candidates = controls().filter(el => el.getClientRects?.().length !== 0 && moneyPattern.test(text(el)));
  // Some builds render operation rows as anchors instead of buttons. Query those
  // only when button-like rows are absent, avoiding unrelated footer/link churn.
  if (!candidates.length) candidates = linkedRows().filter(el => el.getClientRects?.().length !== 0 && moneyPattern.test(text(el)));
  return candidates.filter(el => !candidates.some(other => other !== el && el.contains(other)));
};
// WebKit can place inline label/value pairs on one line or separate them with tabs.
function cardLines(value) {
  const labels = ['Категория', 'MCC', 'Статус', 'Назначение', 'Способ оплаты', 'Со счёта', 'Куда'];
  return value.replace(/\u200b/g, '').split(/[\r\n\t]+/).flatMap(raw => {
    const line = raw.trim();
    for (const label of labels) {
      if (line.startsWith(label + ':') || line.startsWith(label + ' ') || line.startsWith(label + '\u00a0')) {
        const rest = line.slice(label.length).replace(/^[:\s]+/, '').trim();
        if (rest) return [label, rest];
      }
    }
    return line ? [line] : [];
  });
}
function currentCardText() {
  // Different bank operation types expose different detail fields. In particular,
  // internal transfers and interest payouts can have no «Статус» at all. Treat a
  // card as ready once its core header (date + signed amount) is present.
  // A desktop shell/dialog can stay mounted behind the real mobile card, so prefer
  // candidates with operation-specific markers and then the smallest candidate.
  const roots = [...document.querySelectorAll('[role="dialog"],main'), document.body];
  const candidates = [];
  for (const root of roots) {
    if (root !== document.body && !isVisible(root)) continue;
    const value = text(root);
    const hasDate = /(?:Сегодня|Вчера|\d{1,2} [а-яё]+(?: \d{4})?),\s*\d{2}:\d{2}/i.test(value);
    const hasAmount = moneyPattern.test(value);
    if (!hasDate || !hasAmount) continue;
    const hasOperationMarker = /(?:^|[\r\n\t])\s*(?:Подробнее|Категория|MCC|Статус|Назначение|Способ оплаты|Перевод|Пополнение|Чат с поддержкой|Получить квитанцию)(?:\s|$)/i.test(value);
    candidates.push({value, marker: hasOperationMarker ? 0 : 1, size: value.length});
  }
  candidates.sort((a, b) => a.marker - b.marker || a.size - b.size);
  return candidates[0]?.value || null;
}
function isVisible(el) {
  return el.getClientRects?.().length !== 0 && !el.closest?.('[hidden],[aria-hidden="true"]');
}
function activeSwitches() {
  return [...document.querySelectorAll('[role="switch"],input[type="checkbox"]')].filter(isVisible);
}
function historyPeriodSheetOpen() {
  const bodyText = text(document.body);
  if (!/Операции за период/i.test(bodyText)) return false;
  return controls().filter(isVisible).some(el => text(el) === 'Выбрать');
}
async function dismissHistoryPeriodSheet() {
  if (!historyPeriodSheetOpen()) return true;
  const visible = controls().filter(isVisible);
  let close = visible.find(el => /^(Закрыть|Отмена|Close)(?:\s|$)/i.test(controlName(el)));
  if (!close) {
    const viewportWidth = Math.max(320, Number(window.innerWidth) || 430);
    const icons = visible.map(el => ({el, rect: el.getBoundingClientRect?.()})).filter(x => {
      const r = x.rect;
      return r && !text(x.el) && !!x.el.querySelector?.('svg') && r.width > 0 && r.height > 0 &&
        r.left >= viewportWidth * 0.62 && r.top <= 360 && r.width <= 100 && r.height <= 100;
    }).sort((a, b) => a.rect.top - b.rect.top || b.rect.left - a.rect.left);
    close = icons[0]?.el || null;
  }
  if (close) {
    try { close.click(); } catch { }
    const deadline = Date.now() + 1800;
    while (Date.now() < deadline) {
      if (!historyPeriodSheetOpen()) return true;
      await sleep(70);
    }
  }
  try {
    document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', code: 'Escape', bubbles: true}));
    document.dispatchEvent(new KeyboardEvent('keyup', {key: 'Escape', code: 'Escape', bubbles: true}));
  } catch { }
  await sleep(120);
  return !historyPeriodSheetOpen();
}
async function closeHistoryFilters() {
  let switches = activeSwitches();
  if (!switches.length) return;
  const enabled = switches.filter(el => el.getAttribute('aria-checked') === 'true' || el.checked);
  for (const el of enabled) el.click();
  if (enabled.length) {
    await waitFor(() => activeSwitches().every(el => el.getAttribute('aria-checked') !== 'true' && !el.checked), 5000);
    switches = activeSwitches();
  }
  // Mobile has an explicit Apply button. Prefer it over hidden desktop close controls.
  const visibleControls = controls().filter(isVisible);
  const apply = visibleControls.filter(el => text(el) === 'Выбрать');
  const close = apply.length === 1 ? apply[0] : visibleControls.find(el => /^(Закрыть|Готово)(?: |$)/.test(controlName(el)));
  if (!close) throw Error('Не удалось применить фильтр «показывать все операции».');
  close.click();
  await waitFor(() => activeSwitches().length === 0, 5000);
}
function rowSignature(list) { return JSON.stringify(list.map(text)); }
let historyScrollContainer = null;
function historyContainer(list) {
  let parent = list[list.length - 1]?.parentElement;
  while (parent && parent !== document.body) {
    if (parent.scrollHeight > parent.clientHeight + 20 && /(auto|scroll)/.test(getComputedStyle(parent).overflowY)) {
      historyScrollContainer = parent;
      return parent;
    }
    parent = parent.parentElement;
  }
  if (historyScrollContainer && historyScrollContainer.isConnected !== false) return historyScrollContainer;
  return document.scrollingElement || document.documentElement;
}
function scrollHistory(list) {
  const root = historyContainer(list);
  const before = root.scrollTop;
  const step = Math.max(200, root.clientHeight * 0.8);
  root.scrollTop = Math.min(root.scrollHeight - root.clientHeight, before + step);
  root.dispatchEvent(new Event('scroll', {bubbles: true}));
  return {moved: root.scrollTop > before + 1,
    atBottom: root.scrollTop + root.clientHeight >= root.scrollHeight - 2};
}
async function waitForHistoryRows(timeout = 45000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    assertHistory();
    if (window.__financeCancelled) throw Error('Чтение отменено пользователем.');
    const list = rows();
    // A footer loader may stay mounted alongside usable rows. Only an empty list blocks reading.
    if (list.length) return list;
    await sleep(90);
  }
  const failure = Error('Не появились строки операций за 45 секунд. Повторите обновление позже.');
  failure.code = 'HISTORY_ROWS_TIMEOUT';
  throw failure;
}
async function nextHistoryWindow(list) {
  const before = rowSignature(list);
  const movement = scrollHistory(list);
  // At the bottom allow a full network request, rather than stopping on a skeleton.
  const deadline = Date.now() + (movement.atBottom ? 8000 : 700);
  while (Date.now() < deadline) {
    if (window.__financeCancelled) throw Error('Чтение отменено пользователем.');
    let next = rows();
    if (!next.length) next = await waitForHistoryRows();
    if (rowSignature(next) !== before) return {list: next, changed: true, movement};
    await sleep(90);
  }
  const next = await waitForHistoryRows();
  return {list: next, changed: rowSignature(next) !== before, movement};
}

const historyMonthNames = ['Январь','Февраль','Март','Апрель','Май','Июнь','Июль','Август','Сентябрь','Октябрь','Ноябрь','Декабрь'];
const monthNameSource = '(Январь|Февраль|Март|Апрель|Май|Июнь|Июль|Август|Сентябрь|Октябрь|Ноябрь|Декабрь)';
const monthLabelPattern = new RegExp(monthNameSource + '(?:[^0-9]{0,8}(\\d{4}))?', 'i');
const actionables = () => [...document.querySelectorAll('button,[role="button"],[role="option"],[role="menuitem"],[role="gridcell"]')];
function parseMonthLabel(value) {
  const match = String(value || '').replace(/\s+/g, ' ').trim().match(monthLabelPattern);
  if (!match) return null;
  const canonical = historyMonthNames.find(name => name.toLowerCase() === match[1].toLowerCase());
  if (!canonical) return null;
  return {month: historyMonthNames.indexOf(canonical), year: match[2] ? Number(match[2]) : null};
}
function selectedMonthControl() {
  const candidates = controls().filter(isVisible).map(el => {
    const raw = controlName(el);
    const parsed = parseMonthLabel(raw);
    if (!parsed || moneyPattern.test(raw)) return null;
    // Prefer compact controls: this avoids mistaking a large history row/container for the selector.
    const score = (text(el).length <= 24 ? 0 : 10) + (raw.length <= 48 ? 0 : 10);
    return {el, score};
  }).filter(Boolean).sort((a, b) => a.score - b.score);
  return candidates[0]?.el || null;
}
function parseMonthCursor(now = new Date()) {
  const control = selectedMonthControl();
  if (!control) throw Error('Не найден переключатель месяца истории.');
  const parsed = parseMonthLabel(controlName(control));
  if (!parsed) throw Error('Не распознана подпись периода истории.');
  const month = parsed.month;
  let year = parsed.year ?? now.getFullYear();
  if (parsed.year === null && month > now.getMonth()) year -= 1;
  return {month, year};
}
function previousMonth(cursor) {
  return cursor.month === 0 ? {month: 11, year: cursor.year - 1} : {month: cursor.month - 1, year: cursor.year};
}
function visibleMonthChoices(exclude) {
  return actionables().filter(el => el !== exclude && isVisible(el)).map(el => {
    const parsed = parseMonthLabel(controlName(el));
    if (!parsed || moneyPattern.test(controlName(el))) return null;
    return {el, month: parsed.month, year: parsed.year};
  }).filter(Boolean);
}
async function openMonthPicker(anchor) {
  anchor.click();
  try { return await waitFor(() => {
    const choices = visibleMonthChoices(anchor);
    return choices.length ? choices : null;
  }, 5000); }
  catch { return []; }
}
async function switchPickerYear(targetYear, currentYear, anchor) {
  if (targetYear === currentYear) return true;
  let visible = actionables().filter(el => el !== anchor && isVisible(el));
  let directYear = visible.find(el => text(el) === String(targetYear));
  if (directYear) { directYear.click(); await sleep(120); return true; }
  const currentYearControl = visible.find(el => text(el) === String(currentYear));
  if (currentYearControl) {
    currentYearControl.click(); await sleep(90);
    visible = actionables().filter(el => el !== anchor && isVisible(el));
    directYear = visible.find(el => text(el) === String(targetYear));
    if (directYear) { directYear.click(); await sleep(120); return true; }
  }
  visible = actionables().filter(el => el !== anchor && isVisible(el));
  const prevYear = visible.find(el => /предыдущ(?:ий|его).*год|год.*назад|previous.*year/i.test(controlName(el)));
  if (prevYear && targetYear === currentYear - 1) { prevYear.click(); await sleep(120); return true; }
  const nextYear = visible.find(el => /следующ(?:ий|его).*год|год.*впер[её]д|next.*year/i.test(controlName(el)));
  if (nextYear && targetYear === currentYear + 1) { nextYear.click(); await sleep(120); return true; }
  return false;
}
function monthOrdinal(cursor) { return cursor.year * 12 + cursor.month; }
function normalizedChoice(choice, assumedYear) {
  return {el: choice.el, month: choice.month, year: choice.year === null ? assumedYear : choice.year};
}
async function applyHistoryMonthChoice(candidate, target, previousRowsSignature) {
  candidate.el.click();
  historyScrollContainer = null;
  await sleep(120);

  // Mobile Yandex Bank first fills the date-range sheet and requires «Выбрать».
  const applyPeriod = controls().filter(isVisible).filter(el => text(el) === 'Выбрать');
  if (!activeSwitches().length && applyPeriod.length === 1) {
    applyPeriod[0].click();
    await sleep(180);
  }

  let periodConfirmed = false;
  try {
    await waitFor(() => {
      const current = selectedMonthControl();
      if (!current) return false;
      const parsed = parseMonthLabel(controlName(current));
      return parsed && parsed.month === target.month &&
        (parsed.year === null || parsed.year === target.year);
    }, 8000);
    periodConfirmed = true;
  } catch { }

  let rowsChanged = false;
  try {
    await waitFor(() => {
      const nextRows = rows();
      return nextRows.length && (!previousRowsSignature || rowSignature(nextRows) !== previousRowsSignature);
    }, 15000);
    rowsChanged = true;
  } catch { }

  if (!periodConfirmed && !rowsChanged) {
    await dismissHistoryPeriodSheet();
    return {status: 'unavailable'};
  }
  await dismissHistoryPeriodSheet();
  return {status: 'moved', cursor: target};
}
async function selectPreviousHistoryMonth(cursor, previousRowsSignature) {
  const anchor = selectedMonthControl();
  if (!anchor) return {status: 'unavailable', cursor};
  let choices = await openMonthPicker(anchor);
  if (!choices.length) return {status: 'unavailable', cursor};

  // Do not assume that every calendar month contains operations. Pick the nearest
  // actually available older month from the visible picker (e.g. Oct -> Aug when
  // September is empty) instead of declaring the history complete.
  let normalized = choices.map(x => normalizedChoice(x, cursor.year));
  let older = normalized.filter(x => monthOrdinal(x) < monthOrdinal(cursor))
    .sort((a, b) => monthOrdinal(b) - monthOrdinal(a));
  let candidate = older[0] || null;

  if (!candidate) {
    // A whole year can contain no operations. Walk backwards year-by-year rather
    // than assuming that only one year transition is ever needed.
    let pickerYear = cursor.year;
    for (let attempts = 0; attempts < 20 && !candidate; attempts++) {
      const targetYear = pickerYear - 1;
      const currentAnchor = selectedMonthControl() || anchor;
      const changedYear = await switchPickerYear(targetYear, pickerYear, currentAnchor);
      if (!changedYear) break;
      pickerYear = targetYear;
      await sleep(90);
      choices = visibleMonthChoices(currentAnchor);
      if (!choices.length) {
        const reopened = selectedMonthControl();
        if (reopened) choices = await openMonthPicker(reopened);
      }
      normalized = choices.map(x => normalizedChoice(x, pickerYear));
      older = normalized.filter(x => monthOrdinal(x) < monthOrdinal(cursor))
        .sort((a, b) => monthOrdinal(b) - monthOrdinal(a));
      candidate = older[0] || null;
    }
  }

  if (!candidate) {
    // Only an explicit bank message may prove that there is no older history.
    // Missing picker items can also mean an empty month or a changed DOM.
    const explicitEnd = /более ранних операций нет|нет более ранних операций|операций за более ранний период нет|дальше операций нет|вы дошли до начала истории|начало истории|это все операции/i.test(document.body?.innerText || '');
    await dismissHistoryPeriodSheet();
    if (explicitEnd) return {status: 'end', cursor};
    return {status: 'unavailable', cursor};
  }

  const applied = await applyHistoryMonthChoice(candidate, {month: candidate.month, year: candidate.year}, previousRowsSignature);
  return applied.status === 'moved' ? applied : {status: 'unavailable', cursor};
}
async function restoreHistoryMonth(target, cursor) {
  if (!target || (target.month === cursor.month && target.year === cursor.year)) return true;
  const anchor = selectedMonthControl();
  if (!anchor) return false;
  let choices = await openMonthPicker(anchor);
  if (!choices.length) { await dismissHistoryPeriodSheet(); return false; }
  let assumedYear = cursor.year;
  let candidate = choices.map(x => normalizedChoice(x, assumedYear))
    .find(x => x.month === target.month && x.year === target.year);
  if (!candidate && target.year !== cursor.year) {
    // Resume/restore may span several years. Walk one year at a time when the
    // picker does not expose the target year directly.
    let pickerYear = cursor.year;
    let attempts = 0;
    while (!candidate && pickerYear !== target.year && attempts++ < 30) {
      const stepYear = pickerYear + (target.year < pickerYear ? -1 : 1);
      const currentAnchor = selectedMonthControl() || anchor;
      const changedYear = await switchPickerYear(stepYear, pickerYear, currentAnchor);
      if (!changedYear) break;
      pickerYear = stepYear;
      await sleep(90);
      choices = visibleMonthChoices(currentAnchor);
      if (!choices.length) {
        const reopened = selectedMonthControl();
        if (reopened) choices = await openMonthPicker(reopened);
      }
      assumedYear = pickerYear;
      candidate = choices.map(x => normalizedChoice(x, assumedYear))
        .find(x => x.month === target.month && x.year === target.year);
    }
  }
  if (!candidate) { await dismissHistoryPeriodSheet(); return false; }
  const before = rowSignature(rows());
  const applied = await applyHistoryMonthChoice(candidate, target, before);
  if (applied.status !== 'moved') await dismissHistoryPeriodSheet();
  return applied.status === 'moved';
}

function assertHistory() {
  if (location.hostname !== 'bank.yandex.ru' || !location.pathname.startsWith('/my/transactions-history'))
    throw Error('Откройте историю и войдите в банк.');
  if (/captcha|вы не робот|automated traffic/i.test(document.body.innerText))
    throw Error('Проверка браузера: завершите её вручную.');
}
async function waitFor(fn, timeout = 8000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    if (window.__financeCancelled) throw Error('Чтение отменено пользователем.');
    const value = fn(); if (value) return value;
    await sleep(90);
  }
  throw Error('Страница не загрузилась вовремя.');
}
function amount(value) {
  const clean = value.replace(/[\s₽]/g, '').replace(/[−–]/g, '-').replace(',', '.');
  const match = /^([+-])(\d+)(?:\.(\d{1,2}))?$/.exec(clean);
  if (!match) throw Error('Не распознана сумма.');
  const result = (Number(match[2]) * 100 + Number((match[3] || '').padEnd(2, '0'))) * (match[1] === '-' ? -1 : 1);
  if (!Number.isSafeInteger(result)) throw Error('Сумма вне допустимого диапазона.');
  return result;
}
function parseOperationReference(url) {
  const base = typeof location !== 'undefined' && location && location.href ? location.href : 'https://bank.yandex.ru/';
  const route = new URL(url, base);
  if (route.hostname !== 'bank.yandex.ru' || route.pathname !== '/my/transactions-history/operation')
    throw Error('Не открылась карточка операции.');
  const embedded = (route.searchParams.get('id') || '').match(/(\[\{.*\}\])/);
  if (!embedded) throw Error('Изменился формат банковского идентификатора.');
  let refs;
  try { refs = JSON.parse(embedded[1]); }
  catch { throw Error('Не удалось разобрать банковский идентификатор.'); }
  if (!Array.isArray(refs) || !refs.length) throw Error('Пустой идентификатор.');
  const identities = refs.map(ref => {
    if (!ref.type || !(ref.chainId || ref.operationId)) throw Error('Неполный идентификатор.');
    return [String(ref.type), String(ref.chainId || ref.operationId)];
  }).sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b), 'en'));
  const dates = refs.filter(ref => ref.operationTimestamp).map(ref => {
    if (!/(Z|[+-]\d\d:\d\d)$/.test(ref.operationTimestamp)) throw Error('Не определён часовой пояс.');
    const stamp = Date.parse(ref.operationTimestamp);
    if (!Number.isFinite(stamp)) throw Error('Не распознана дата.');
    return stamp;
  });
  return {identity: JSON.stringify(identities), identities, dates, href: route.href};
}
function operationURLFromRow(row) {
  try {
    let href = '';
    if (row?.matches?.('a[href*="/my/transactions-history/operation"]')) href = row.getAttribute?.('href') || row.href || '';
    if (!href) {
      const link = row?.querySelector?.('a[href*="/my/transactions-history/operation"]');
      href = link?.getAttribute?.('href') || link?.href || '';
    }
    if (!href) href = row?.getAttribute?.('data-href') || row?.getAttribute?.('data-url') || '';
    if (!href) return null;
    const route = new URL(href, location.href);
    if (route.hostname !== 'bank.yandex.ru' || route.pathname !== '/my/transactions-history/operation') return null;
    return route.href;
  } catch { return null; }
}
function parseKnownOperations(value) {
  let list = [];
  try { list = JSON.parse(typeof value === 'string' ? value : '[]'); } catch { return new Map(); }
  if (!Array.isArray(list)) return new Map();
  const result = new Map();
  for (const item of list) {
    if (!item || typeof item.identity !== 'string' || !item.identity) continue;
    result.set(item.identity, item);
  }
  return result;
}
function rowAmountKopecks(rowText) {
  try {
    const values = [...String(rowText || '').matchAll(/[+−–-]\s*\d[\d\s.,]*\s*₽/g)].map(x => amount(x[0]));
    const distinct = [...new Set(values)];
    return distinct.length === 1 ? distinct[0] : null;
  } catch { return null; }
}
function stableKnownRow(rowText, known, nowMs = Date.now()) {
  // v20: identity + amount cannot prove unchanged status/category.
  // Reopen cards until the bank exposes a verified revision contract.
  return false;
}
function parseCard(url, cardText, rowText, now = new Date()) {
  const reference = parseOperationReference(url);
  const identities = reference.identities;
  const dates = reference.dates;

  const lines = cardLines(cardText);
  const normalized = cardText.replace(/\u200b/g, '');
  const datePattern = /(?:Сегодня|Вчера|\d{1,2} [а-яё]+(?: \d{4})?),\s*\d{2}:\d{2}/gi;
  const dateMarks = [...normalized.matchAll(datePattern)];
  if (dateMarks.length > 1) throw Error('Найдено несколько карточек. Не удалось выбрать активную.');
  if (!dateMarks.length) throw Error('Не удалось найти дату карточки (версия 21).');

  // The list row is the strongest amount disambiguator during history import.
  // This lets us tolerate cashback/fee values in the same rendered card header.
  const listedValues = [...rowText.matchAll(/[+−–-]\s*\d[\d\s.,]*\s*₽/g)].map(x => amount(x[0]));
  const listedKopecks = [...new Set(listedValues)];
  const amountCandidates = [];
  for (let i = 0; i < dateMarks.length; i++) {
    const mark = dateMarks[i];
    const start = mark.index + mark[0].length;
    const nextDate = i + 1 < dateMarks.length ? dateMarks[i + 1].index : normalized.length;
    let end = nextDate;
    const tail = normalized.slice(start, end);
    const detail = tail.search(/(?:^|[\r\n\t])\s*(?:Подробнее|Категория|MCC|Статус|Назначение|Способ оплаты)(?=\s|$)/i);
    if (detail >= 0) end = start + detail;
    const area = normalized.slice(start, end);
    for (const match of area.matchAll(/[+−–-]\s*\d[\d\s.,]*\s*₽/g)) {
      amountCandidates.push({dateMark: mark, amountText: match[0], kopecks: amount(match[0])});
    }
  }

  let selected;
  if (listedKopecks.length) {
    const matching = amountCandidates.filter(x => listedKopecks.includes(x.kopecks));
    const distinctMatching = [...new Set(matching.map(x => x.kopecks))];
    if (!matching.length) throw Error('Сумма не совпала со списком.');
    if (distinctMatching.length !== 1) throw Error('Не удалось однозначно сопоставить сумму карточки со списком.');
    selected = matching.find(x => x.kopecks === distinctMatching[0]);
  } else {
    if (amountCandidates.length !== 1)
      throw Error('В карточке найдено сумм: ' + amountCandidates.length + '. Ожидалась одна (версия 21).');
    selected = amountCandidates[0];
  }
  const kopecks = selected.kopecks;

  const detail = label => { const index = lines.indexOf(label); return index < 0 ? null : lines[index + 1] || null; };
  const status = detail('Статус') || 'Не указан';
  let occurred;
  if (dates.length) occurred = new Date(Math.min(...dates));
  else {
    const displayed = lines.map(line => line.match(/^(Сегодня|Вчера|\d{1,2} [а-яё]+(?: \d{4})?),\s*(\d{2}):(\d{2})$/)).find(Boolean);
    if (!displayed) throw Error('Не распознано время операции.');
    occurred = new Date(now);
    const day = displayed[1];
    if (day === 'Вчера') occurred.setDate(occurred.getDate() - 1);
    else if (day !== 'Сегодня') {
      const parts = day.split(' ');
      const months = ['января','февраля','марта','апреля','мая','июня','июля','августа','сентября','октября','ноября','декабря'];
      const month = months.indexOf(parts[1]);
      if (month < 0) throw Error('Не распознан месяц.');
      occurred = new Date(Number(parts[2] || now.getFullYear()), month, Number(parts[0]));
      if (!parts[2] && occurred > now) occurred.setFullYear(occurred.getFullYear() - 1);
    }
    occurred.setHours(Number(displayed[2]), Number(displayed[3]), 0, 0);
  }
  const providers = [...new Set(identities.map(x => x[0]))].sort();
  const rawCategory = detail('Категория');
  const purpose = detail('Назначение');
  const detailsIndex = lines.indexOf('Подробнее');
  const details = detailsIndex >= 0 ? lines.slice(detailsIndex + 1) : [];
  const hasDetailHeading = heading => details.some(line => line === heading);
  const dateIndex = lines.findIndex(line => /^(Сегодня|Вчера|\d{1,2} [а-яё]+(?: \d{4})?),\s*\d{2}:\d{2}$/.test(line));
  const description = dateIndex > 0 ? lines[dateIndex - 1] : lines[0];
  if (!description) throw Error('Не удалось определить описание операции.');

  const summary = detailsIndex >= 0 ? lines.slice(0, detailsIndex) : lines;
  const combined = [description, rowText, ...details].filter(Boolean).join(' ');
  const installment = providers.includes('BNPL') && /Плат[её]ж/i.test(rowText + ' ' + (purpose || ''));
  const refund = rawCategory === 'Возврат' || summary.includes('Возврат');
  const interestIncome = kopecks > 0 && /(?:выплат[аы]?|начислени[ея])\s+процент|процент(?:ы|ов|ный доход)/i.test(combined);
  const sourceAccount = detail('Со счёта');
  const destinationAccount = detail('Куда');
  const ownAccountHint = /(?:сейв|карт[ау]\s+п[эе]й|сч[её]т(?:\s+в)?\s+п[эе]й|яндекс\s+п[эе]й)/i;
  const arrowParts = description.split('→').map(x => x.trim()).filter(Boolean);
  const internalTransfer = (arrowParts.length === 2 && ownAccountHint.test(arrowParts[0]) && ownAccountHint.test(arrowParts[1])) ||
    (hasDetailHeading('Перевод') && !!sourceAccount && !!destinationAccount &&
      ownAccountHint.test(sourceAccount) && ownAccountHint.test(destinationAccount));
  const transfer = internalTransfer || ['Перевод','Пополнение','Переводы между своими счетами'].includes(rawCategory) ||
    hasDetailHeading('Перевод');
  const category = rawCategory || (installment ? 'Платежи Сплита'
    : interestIncome ? 'Проценты'
    : internalTransfer ? 'Переводы между своими счетами'
    : hasDetailHeading('Перевод') ? 'Перевод'
    : hasDetailHeading('Пополнение') ? 'Пополнение'
    : 'Не определено');

  return {identity: JSON.stringify(identities), verifiedAt: new Date().toISOString(), occurredAt: occurred.toISOString(),
    timePrecision: dates.length ? 'source_timestamp' : 'display_minute',
    description, amountKopecks: kopecks, currency: 'RUB', status,
    category, mcc: detail('MCC'), purpose, paymentMethod: detail('Способ оплаты'), providers,
    kind: installment ? 'installment_payment' : refund ? 'refund' : interestIncome ? 'interest_income'
      : internalTransfer ? 'internal_transfer' : transfer ? 'transfer' : kopecks > 0 ? 'unclassified_income' : 'expense'};
}

const found = new Map();
let effectiveLookbackDays = null;
let skippedCount = 0;
let lastWarning = '';
let initialMonthCursor = null;
let monthCursor = null;
let fastSkippedCount = 0;
let openedCardCount = 0;
let monthsVisited = 0;
let checkpointSequence = 0;
window.__financeRunID = typeof runID === 'string' ? runID : 'test-run';
window.__financeCancelled = false;
window.__financeCheckpointQueue = [];
window.__financeCheckpointMonth = null;
window.__financeIssues = [];
const knownOperationMap = parseKnownOperations(typeof knownOperationsJson === 'undefined' ? '[]' : knownOperationsJson);

try {
assertHistory();
if (historyPeriodSheetOpen()) {
  const closed = await dismissHistoryPeriodSheet();
  if (!closed) throw Error('Не удалось закрыть окно выбора периода. Закройте его крестиком и повторите обновление.');
}
window.__financeCancelled = false;
window.__financeCheckpointQueue = [];
window.__financeProgress = 'Подготовка истории…';
const retryIssue = typeof retryIssueJson === 'string' ? JSON.parse(retryIssueJson) : null;
if (mode === 'card' || mode === 'retry_card') {
  if (!location.pathname.endsWith('/operation')) throw Error('Откройте подробности одной операции.');
  let cardText;
  try { cardText = await waitFor(currentCardText, 3500); }
  catch (error) {
    if (window.__financeCancelled) throw error;
    throw Error('Не найдены дата и сумма в тексте карточки (версия 21).');
  }
  const operation = parseCard(location.href, cardText, '');
  if (retryIssue?.identity && operation.identity !== retryIssue.identity) throw Error('Открылась другая операция. Повторное чтение не сохранено.');
  return JSON.stringify({operations: [operation], stopReason: 'single_card', skippedCount: 0});
}
if (onCard()) throw Error('Закройте карточку и вернитесь к списку.');

let filter = controls().find(el => /Какие операции скрывать|Фильтры/i.test(controlName(el)));
if (!filter) {
  // The mobile filter is the unlabeled icon immediately left of the month selector.
  const month = selectedMonthControl();
  if (month) {
    const anchor = month.getBoundingClientRect();
    const icons = controls().filter(el => {
      const rect = el.getBoundingClientRect();
      return !text(el) && el.querySelector('svg') && rect.width > 0 && rect.height > 0 &&
        rect.right <= anchor.left + 2 && anchor.left - rect.right < 40 && Math.abs(rect.top - anchor.top) < 15;
    });
    if (icons.length === 1) filter = icons[0];
  }
}
if (!filter) throw Error('Не найдены фильтры истории. Мобильный вид требует проверки.');
if (!activeSwitches().length) filter.click();
await waitFor(() => activeSwitches().length);
await closeHistoryFilters();
if (!controls().some(el => text(el) === 'Все карты и счета')) throw Error('Выберите Все карты и счета.');

const rawLookback = typeof lookbackDays === 'undefined' ? 30 : lookbackDays;
const parsedLookback = rawLookback == null ? null : Number(rawLookback);
if (parsedLookback !== null && (!Number.isFinite(parsedLookback) || parsedLookback <= 0))
  throw Error('Некорректный период синхронизации.');
effectiveLookbackDays = parsedLookback === null ? null : Math.floor(parsedLookback);
const cutoff = effectiveLookbackDays === null ? null : Date.now() - effectiveLookbackDays * 86400000;
const rawResumeOrdinal = typeof resumeMonthOrdinal === 'undefined' ? null : resumeMonthOrdinal;
const parsedResumeOrdinal = rawResumeOrdinal == null ? null : Number(rawResumeOrdinal);
if (parsedResumeOrdinal !== null && (!Number.isInteger(parsedResumeOrdinal) || parsedResumeOrdinal < 0))
  throw Error('Некорректная точка продолжения полной синхронизации.');
function cursorFromOrdinal(value) {
  const year = Math.floor(value / 12);
  return {month: value - year * 12, year};
}

monthsVisited = 1;
let index = 0, stalls = 0, opened = 0, scrollSteps = 0, stopReason = 'running';
monthCursor = parseMonthCursor();
initialMonthCursor = {...monthCursor};
const nowForStart = new Date();
const currentMonthCursor = {month: nowForStart.getMonth(), year: nowForStart.getFullYear()};
const startCursor = parsedResumeOrdinal !== null ? cursorFromOrdinal(parsedResumeOrdinal) : currentMonthCursor;
if (monthCursor.month !== startCursor.month || monthCursor.year !== startCursor.year) {
  window.__financeProgress = parsedResumeOrdinal !== null
    ? 'Продолжаю синхронизацию с ' + historyMonthNames[startCursor.month].toLowerCase() + ' ' + startCursor.year + '…'
    : 'Возвращаю историю к текущему месяцу перед синхронизацией…';
  const movedToStart = await restoreHistoryMonth(startCursor, monthCursor);
  if (!movedToStart) {
    await dismissHistoryPeriodSheet();
    if (parsedResumeOrdinal !== null)
      throw Error('Не удалось продолжить синхронизацию с сохранённого месяца. Запустите «Синхронизировать 6 месяцев», чтобы начать заново.');
    throw Error('Не удалось перейти к текущему месяцу перед синхронизацией.');
  }
  monthCursor = startCursor;
}
const maxOpened = cutoff === null || effectiveLookbackDays > 30 ? 5000 : 300;
const maxScrollSteps = cutoff === null ? 2500 : 200;
const maxMonths = cutoff === null ? 240 : 24;
window.__financeProgress = cutoff === null
  ? 'Полная синхронизация: читаю доступную историю по месяцам…'
  : 'Обновляю последние ' + effectiveLookbackDays + ' дн.…';

mainLoop: while (opened < maxOpened && scrollSteps < maxScrollSteps && monthsVisited <= maxMonths) {
  window.__financeCheckpointMonth = monthCursor ? monthOrdinal(monthCursor) : null;
  assertHistory();
  if (window.__financeCancelled) throw Error('Чтение отменено пользователем.');

  let list;
  try { list = await waitForHistoryRows(); }
  catch (error) {
    if (window.__financeCancelled) throw error;
    if (error.code !== 'HISTORY_ROWS_TIMEOUT') throw error;
    // An empty month is not the end of the bank history. Try the nearest older
    // available month before giving up.
    if (mode === 'retry') { stopReason = 'issue_not_found'; break; }
    const move = await selectPreviousHistoryMonth(monthCursor, '');
    if (move.status === 'moved') {
      monthCursor = move.cursor;
      monthsVisited++;
      index = 0; stalls = 0;
      window.__financeProgress = 'Прочитано ' + found.size + '. Пустой месяц пропущен, перехожу к ' +
        historyMonthNames[monthCursor.month].toLowerCase() + ' ' + monthCursor.year + '…';
      continue;
    }
    stopReason = move.status === 'end'
      ? (cutoff === null ? 'full_history_exhausted' : 'history_beginning_reached')
      : 'month_navigation_unavailable';
    break;
  }

  if (index >= list.length) {
    window.__financeProgress = 'Прочитано ' + found.size + '. Догружаю операции за ' + historyMonthNames[monthCursor.month].toLowerCase() + '…';
    const before = list.map(text);
    let result;
    try { result = await nextHistoryWindow(list); }
    catch (error) {
      if (window.__financeCancelled) throw error;
      if (error.code !== 'HISTORY_ROWS_TIMEOUT') throw error;
      stopReason = 'loading_timeout';
      break;
    }
    scrollSteps++;
    if (result.changed) {
      const appended = result.list.length > before.length && before.every((value, i) => value === text(result.list[i]));
      if (!appended) index = 0;
      stalls = 0;
      continue;
    }
    // nextHistoryWindow already waited for a possible network append at the bottom.
    // Do not repeat the same end-of-month scroll a second time.
    if (!result.movement.moved && result.movement.atBottom) stalls = 2; else stalls = 0;
    if (stalls < 2) continue;

    if (mode === 'retry') { stopReason = 'issue_not_found'; break; }
    const move = await selectPreviousHistoryMonth(monthCursor, rowSignature(list));
    if (move.status === 'moved') {
      monthCursor = move.cursor;
      monthsVisited++;
      index = 0; stalls = 0;
      window.__financeProgress = 'Прочитано ' + found.size + '. Перехожу к ' + historyMonthNames[monthCursor.month].toLowerCase() + ' ' + monthCursor.year + '…';
      continue;
    }
    stopReason = move.status === 'end'
      ? (cutoff === null ? 'full_history_exhausted' : 'history_beginning_reached')
      : 'month_navigation_unavailable';
    break;
  }

  const row = list[index];
  const rowText = text(row);
  let operation = null;

  // Direct links verify identity, but do not establish unchanged details.
  const linkedURL = operationURLFromRow(row);
  let known = null;
  if (linkedURL) {
    try { known = knownOperationMap.get(parseOperationReference(linkedURL).identity) || null; } catch { known = null; }
  }
  if (mode === 'retry' && linkedURL && retryIssue?.identity) {
    try { if (parseOperationReference(linkedURL).identity !== retryIssue.identity) { index++; continue; } } catch {}
  }
  if (known && stableKnownRow(rowText, known)) {
    const knownTime = Date.parse(known.occurredAt || '');
    if (cutoff !== null && Number.isFinite(knownTime) && knownTime < cutoff) {
      stopReason = 'lookback_reached';
      break mainLoop;
    }
    fastSkippedCount++;
    index++;
    window.__financeProgress = 'Проверено ' + (found.size + fastSkippedCount) + ': быстро ' + fastSkippedCount +
      ', карточек ' + openedCardCount + (skippedCount ? ', пропущено ' + skippedCount : '') + '…';
    continue;
  }

  row.click();
  opened++;
  openedCardCount++;
  try {
    const cardText = await waitFor(() => onCard() && currentCardText(), 8000);
    operation = parseCard(location.href, cardText, rowText);
    if (linkedURL && parseOperationReference(linkedURL).identity !== operation.identity) {
      operation = null;
      throw Error('Открылась другая карточка. Операция не сохранена.');
    }
  } catch (error) {
    if (window.__financeCancelled) throw error;
    skippedCount++;
    lastWarning = String(error?.message || 'Не удалось разобрать карточку.');
    let failedIdentity = null;
    try { failedIdentity = parseOperationReference(linkedURL || (onCard() ? location.href : '')).identity; } catch {}
    if (mode !== 'retry' || failedIdentity === retryIssue?.identity) window.__financeIssues.push({identity: failedIdentity, monthOrdinal: monthCursor ? monthOrdinal(monthCursor) : null,
      reason: lastWarning, rowSummary: rowText.slice(0, 500),
      operationURL: linkedURL || (onCard() ? location.href : null), observedAt: new Date().toISOString()});
  }

  const retryMatches = operation && (!retryIssue?.identity || operation.identity === retryIssue.identity);
  if (mode === 'retry' && !retryMatches) operation = null;
  const reachedCutoff = operation && cutoff !== null && Date.parse(operation.occurredAt) < cutoff;
  if (operation && !reachedCutoff) {
    // Save into the in-memory batch before any fragile UI cleanup. If closing the
    // bank overlay fails, the outer catch still returns this operation to Swift.
    found.set(operation.identity, operation);
    window.__financeIssues = window.__financeIssues.filter(issue => issue.identity !== operation.identity);
    window.__financeCheckpointQueue.push({sequence: ++checkpointSequence, operation});
    window.__financeProgress = 'Проверено ' + (found.size + fastSkippedCount) + ': быстро ' + fastSkippedCount +
      ', карточек ' + openedCardCount + (skippedCount ? ', пропущено ' + skippedCount : '') + '…';
  }

  if (onCard()) await leaveOperationCard();
  // Some mobile builds reopen the history filter sheet after returning from a
  // card. Close it only when it is actually present; failures preserve `found`.
  if (activeSwitches().length) await closeHistoryFilters();

  if (mode === 'retry' && retryMatches) { stopReason = 'issue_retry_completed'; break mainLoop; }
  if (reachedCutoff) {
    stopReason = 'lookback_reached';
    break mainLoop;
  }
  index++;
}

if (stopReason === 'running' && (opened >= maxOpened || scrollSteps >= maxScrollSteps || monthsVisited > maxMonths))
  stopReason = 'limit_reached';
if (stopReason === 'running') stopReason = 'interrupted';

// Best effort: leave the bank on the period where this run started so a later
// 7-day refresh does not accidentally begin from the oldest visited month.
if (!window.__financeCancelled && initialMonthCursor && monthCursor) {
  try { await restoreHistoryMonth(initialMonthCursor, monthCursor); } catch { }
}

return JSON.stringify({operations: [...found.values()], stopReason,
  issues: window.__financeIssues, lookbackDays: effectiveLookbackDays, skippedCount, warning: lastWarning || null,
  oldestMonthOrdinal: monthCursor ? monthOrdinal(monthCursor) : null, monthsVisited,
  fastSkippedCount, openedCardCount});

} catch (error) {
  try { await dismissHistoryPeriodSheet(); } catch { }
  const detail = String(error?.message || 'Не удалось прочитать страницу.');
  const wasCancelled = !!window.__financeCancelled;
  // Cancellation is a normal partial-success state. Return a batch even when the
  // current in-memory map is empty: checkpoints may already have been persisted by
  // Swift, and the UI must never claim that saved work was discarded.
  if (found.size || wasCancelled) {
    return JSON.stringify({operations: [...found.values()],
      stopReason: wasCancelled ? 'cancelled' : 'interrupted',
      issues: window.__financeIssues, lookbackDays: effectiveLookbackDays, skippedCount, warning: wasCancelled ? null : detail,
      oldestMonthOrdinal: monthCursor ? monthOrdinal(monthCursor) : null, monthsVisited: typeof monthsVisited === 'number' ? monthsVisited : 0,
      fastSkippedCount, openedCardCount});
  }
  return JSON.stringify({error: detail});
}
