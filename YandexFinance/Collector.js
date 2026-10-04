// Runs only on the bank history page, on an explicit user action.
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const text = el => (el?.innerText || '').replace(/\u200b/g, '').trim();
const controls = () => [...document.querySelectorAll('button,[role="button"]')];
const moneyPattern = /[+−–-]\s*[\d\s.,]+\s*₽/;
const onCard = () => location.pathname.replace(/\/$/, '') === '/my/transactions-history/operation';
const controlName = el => [text(el), el.getAttribute('aria-label'), el.getAttribute('title')].filter(Boolean).join(' ').trim();
const rows = () => {
  if (onCard()) return [];
  const candidates = controls().filter(el => el.getClientRects?.().length !== 0 && moneyPattern.test(text(el)));
  return candidates.filter(el => !candidates.some(other => other !== el && el.contains(other)));
};
// WebKit can place inline label/value pairs on one line or separate them with tabs.
function cardLines(value) {
  const labels = ['Категория', 'MCC', 'Статус', 'Назначение', 'Способ оплаты'];
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
  // A desktop main/dialog may remain mounted behind a mobile portal.
  // Check each candidate instead of allowing an empty first match to mask the body.
  const roots = [...document.querySelectorAll('[role="dialog"],main'), document.body];
  for (const root of roots) {
    const value = text(root);
    const lines = cardLines(value);
    const statusIndex = lines.indexOf('Статус');
    if (statusIndex >= 0 && lines[statusIndex + 1] && moneyPattern.test(value)) return value;
  }
  return null;
}
function isVisible(el) {
  return el.getClientRects?.().length !== 0 && !el.closest?.('[hidden],[aria-hidden="true"]');
}
function activeSwitches() {
  return [...document.querySelectorAll('[role="switch"],input[type="checkbox"]')].filter(isVisible);
}
async function closeHistoryFilters() {
  const switches = activeSwitches();
  if (!switches.length) return;
  if (switches.some(el => el.getAttribute('aria-checked') === 'true' || el.checked))
    throw Error('Выключите скрытие типов операций и нажмите «Выбрать».');
  // Mobile has an explicit Apply button. Prefer it over hidden desktop close controls.
  const visibleControls = controls().filter(isVisible);
  const apply = visibleControls.filter(el => text(el) === 'Выбрать');
  const close = apply.length === 1 ? apply[0] : visibleControls.find(el => /^(Закрыть|Готово)(?: |$)/.test(controlName(el)));
  if (!close) throw Error('Закройте фильтры кнопкой «Выбрать» и повторите обновление.');
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
    if (window.__financeCancelled) throw Error('Чтение отменено. Ничего не сохранено.');
    const list = rows();
    // A footer loader may stay mounted alongside usable rows. Only an empty list blocks reading.
    if (list.length) return list;
    await sleep(250);
  }
  const failure = Error('Не появились строки операций за 45 секунд. Повторите обновление позже.');
  failure.code = 'HISTORY_ROWS_TIMEOUT';
  throw failure;
}
async function nextHistoryWindow(list) {
  const before = rowSignature(list);
  const movement = scrollHistory(list);
  // At the bottom allow a full network request, rather than stopping on a skeleton.
  const deadline = Date.now() + (movement.atBottom ? 15000 : 1500);
  while (Date.now() < deadline) {
    if (window.__financeCancelled) throw Error('Чтение отменено. Ничего не сохранено.');
    let next = rows();
    if (!next.length) next = await waitForHistoryRows();
    if (rowSignature(next) !== before) return {list: next, changed: true, movement};
    await sleep(250);
  }
  const next = await waitForHistoryRows();
  return {list: next, changed: rowSignature(next) !== before, movement};
}
function assertHistory() {
  if (location.hostname !== 'bank.yandex.ru' || !location.pathname.startsWith('/my/transactions-history'))
    throw Error('Откройте историю и войдите в банк.');
  if (/captcha|вы не робот|automated traffic/i.test(document.body.innerText))
    throw Error('Проверка браузера: завершите её вручную.');
}
async function waitFor(fn, timeout = 20000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    if (window.__financeCancelled) throw Error('Чтение отменено. Ничего не сохранено.');
    const value = fn(); if (value) return value;
    await sleep(250);
  }
  throw Error('Страница не загрузилась вовремя. Ничего не сохранено.');
}
function amount(value) {
  const clean = value.replace(/[\s₽]/g, '').replace(/[−–]/g, '-').replace(',', '.');
  const match = /^([+-])(\d+)(?:\.(\d{1,2}))?$/.exec(clean);
  if (!match) throw Error('Не распознана сумма.');
  const result = (Number(match[2]) * 100 + Number((match[3] || '').padEnd(2, '0'))) * (match[1] === '-' ? -1 : 1);
  if (!Number.isSafeInteger(result)) throw Error('Сумма вне допустимого диапазона.');
  return result;
}
function parseCard(url, cardText, rowText, now = new Date()) {
  const route = new URL(url);
  if (route.hostname !== 'bank.yandex.ru' || route.pathname !== '/my/transactions-history/operation')
    throw Error('Не открылась карточка операции.');
  const embedded = (route.searchParams.get('id') || '').match(/(\[\{.*\}\])/);
  if (!embedded) throw Error('Изменился формат банковского идентификатора.');
  const refs = JSON.parse(embedded[1]);
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
  const lines = cardLines(cardText);
  // Read only the card header after its date; WebKit may split sign, digits,
  // fraction and currency across text lines. Amounts in details are unrelated.
  const header = cardText.replace(/\u200b/g, '').split('Подробнее')[0];
  const headerDates = [...header.matchAll(/(?:Сегодня|Вчера|\d{1,2} [а-яё]+(?: \d{4})?),\s*\d{2}:\d{2}/g)];
  if (headerDates.length !== 1) throw Error('Не удалось выделить заголовок одной карточки (версия 9).');
  const dateMark = headerDates[0];
  const amountArea = header.slice(dateMark.index + dateMark[0].length);
  const amounts = amountArea.match(/[+−–-]\s*\d[\d\s.,]*\s*₽/g) || [];
  if (amounts.length !== 1) throw Error('В заголовке найдено сумм: ' + amounts.length + '. Ожидалась одна (версия 9).');
  const kopecks = amount(amounts[0]);
  const listed = rowText.match(moneyPattern);
  if (listed && amount(listed[0]) !== kopecks) throw Error('Сумма не совпала со списком.');
  const detail = label => { const index = lines.indexOf(label); return index < 0 ? null : lines[index + 1] || null; };
  const status = detail('Статус');
  if (!status) throw Error('Не загрузился статус операции.');
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
  const category = detail('Категория');
  const purpose = detail('Назначение');
  const installment = providers.includes('BNPL') && /Плат[её]ж/i.test(rowText + ' ' + (purpose || ''));
  const summary = lines.includes('Подробнее') ? lines.slice(0, lines.indexOf('Подробнее')) : lines;
  const refund = category === 'Возврат' || summary.includes('Возврат');
  const transfer = ['Перевод','Пополнение','Переводы между своими счетами'].includes(category);
  const dateIndex = lines.findIndex(line => /^(Сегодня|Вчера|\d{1,2} [а-яё]+(?: \d{4})?),\s*\d{2}:\d{2}$/.test(line));
  const description = dateIndex > 0 ? lines[dateIndex - 1] : lines[0];
  return {identity: JSON.stringify(identities), occurredAt: occurred.toISOString(),
    timePrecision: dates.length ? 'source_timestamp' : 'display_minute',
    description, amountKopecks: kopecks, currency: 'RUB', status,
    category: category || (installment ? 'Платежи Сплита' : 'Не определено'),
    mcc: detail('MCC'), purpose, paymentMethod: detail('Способ оплаты'), providers,
    kind: installment ? 'installment_payment' : refund ? 'refund' : transfer ? 'transfer' : kopecks > 0 ? 'unclassified_income' : 'expense'};
}
try {
assertHistory();
window.__financeCancelled = false;
window.__financeProgress = 'Подготовка истории…';
if (mode === 'card') {
  if (!location.pathname.endsWith('/operation')) throw Error('Откройте подробности одной операции.');
  // Mobile history opens a full page rather than an ARIA dialog.
  let cardText;
  try { cardText = await waitFor(currentCardText, 6000); }
  catch (error) {
    if (window.__financeCancelled) throw error;
    throw Error('Не найдены сумма и статус в тексте карточки (версия 9).');
  }
  return JSON.stringify({operations: [parseCard(location.href, cardText, '')], stopReason: 'single_card'});
}
if (onCard()) throw Error('Закройте карточку и вернитесь к списку.');
let filter = controls().find(el => /Какие операции скрывать|Фильтры/i.test(controlName(el)));
if (!filter) {
  // The mobile filter is the unlabeled icon immediately left of the month selector.
  const month = controls().find(el => /^(Январь|Февраль|Март|Апрель|Май|Июнь|Июль|Август|Сентябрь|Октябрь|Ноябрь|Декабрь)(?:\s+\d{4})?$/.test(text(el)));
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
await waitForHistoryRows();
const cutoff = Date.now() - 30 * 86400000;
const found = new Map();
let index = 0, stalls = 0, opened = 0, scrollSteps = 0, stopReason = 'loaded_rows_exhausted';
while (opened < 300 && scrollSteps < 150) {
  assertHistory();
  if (window.__financeCancelled) throw Error('Чтение отменено. Ничего не сохранено.');
  const list = await waitForHistoryRows();
  if (index >= list.length) {
    window.__financeProgress = 'Прочитано ' + found.size + '. Догружаю более ранние операции…';
    const before = list.map(text);
    let result;
    try { result = await nextHistoryWindow(list); }
    catch (error) {
      if (error.code !== 'HISTORY_ROWS_TIMEOUT') throw error;
      stopReason = 'loading_timeout';
      break;
    }
    scrollSteps++;
    if (result.changed) {
      const appended = result.list.length > before.length && before.every((value, i) => value === text(result.list[i]));
      if (!appended) index = 0;
      stalls = 0;
    } else if (!result.movement.moved && result.movement.atBottom) {
      if (++stalls >= 2) break;
    } else {
      stalls = 0;
    }
    continue;
  }
  const rowText = text(list[index]);
  list[index].click();
  opened++;
  const cardText = await waitFor(() => onCard() && currentCardText());
  const operation = parseCard(location.href, cardText, rowText);
  // Reuse the site's navigation, which also preserves its month and account filters.
  const back = controls().find(el => el.getClientRects?.().length !== 0 && /^(Назад|Вернуться)(?: |$)/.test(controlName(el)));
  if (back) back.click();
  else window.history.back();
  await waitFor(() => !onCard());
  await closeHistoryFilters();
  await waitForHistoryRows();
  if (Date.parse(operation.occurredAt) < cutoff) { stopReason = 'lookback_reached'; break; }
  found.set(operation.identity, operation);
  window.__financeProgress = 'Прочитано ' + found.size + '. Продолжаю чтение истории…';
  index++;
}
if (opened >= 300 || scrollSteps >= 150) stopReason = 'limit_reached';
await closeHistoryFilters();
if (!found.size) throw Error('Не прочитано ни одной операции.');
return JSON.stringify({operations: [...found.values()], stopReason});

} catch (error) {
  // Return failures as data so WebKit preserves the actionable parser message.
  return JSON.stringify({error: String(error?.message || 'Не удалось прочитать страницу.')});
}
