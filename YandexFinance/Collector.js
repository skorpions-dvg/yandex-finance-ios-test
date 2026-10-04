// Runs only on the bank history page, on an explicit user action.
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const text = el => (el?.innerText || '').replace(/\u200b/g, '').trim();
const controls = () => [...document.querySelectorAll('button,[role="button"]')];
const moneyPattern = /[+−–-]\s*[\d\s.,]+\s*₽/;
const rows = () => controls().filter(el => !el.closest('[role="dialog"]') && moneyPattern.test(text(el)));
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
  const lines = cardText.replace(/\u200b/g, '').split('\n').map(x => x.trim()).filter(Boolean);
  const amounts = lines.filter(line => /^[+−–-]\s*[\d\s.,]+\s*₽$/.test(line));
  if (amounts.length !== 1) throw Error('Не найдена однозначная сумма.');
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
if (mode === 'card') {
  if (!location.pathname.endsWith('/operation')) throw Error('Откройте подробности одной операции.');
  // Mobile history opens a full page rather than an ARIA dialog.
  const card = await waitFor(() => {
    const root = document.querySelector('[role="dialog"]') || document.querySelector('main') || document.body;
    return text(root).split('\n').some(line => line.trim() === 'Статус') ? root : null;
  });
  return JSON.stringify({operations: [parseCard(location.href, text(card), '')], stopReason: 'single_card'});
}
if (document.querySelector('[role="dialog"]')) throw Error('Закройте карточку и вернитесь к списку.');
const filter = controls().find(el => text(el) === 'Какие операции скрывать');
if (!filter) throw Error('Не найдены фильтры истории. Мобильный вид требует проверки.');
filter.click();
await waitFor(() => document.querySelector('[role="switch"],input[type="checkbox"]'));
const switches = [...document.querySelectorAll('[role="switch"],input[type="checkbox"]')];
if (switches.some(el => el.getAttribute('aria-checked') === 'true' || el.checked))
  throw Error('Выключите скрытие типов операций и повторите чтение.');
const closeFilter = controls().find(el => (el.getAttribute('aria-label') || text(el)) === 'Закрыть');
if (!closeFilter) throw Error('Не найдена кнопка закрытия фильтров.');
closeFilter.click();
await sleep(400);
if (!controls().some(el => text(el) === 'Все карты и счета')) throw Error('Выберите Все карты и счета.');
await waitFor(() => rows().length);
const cutoff = Date.now() - 30 * 86400000;
const found = new Map();
let index = 0, stalls = 0, stopReason = 'loaded_rows_exhausted';
while (index < 300) {
  assertHistory();
  if (window.__financeCancelled) throw Error('Чтение отменено. Ничего не сохранено.');
  const list = rows();
  if (index >= list.length) {
    const last = list[list.length - 1];
    last?.scrollIntoView({block: 'end'});
    let parent = last?.parentElement;
    while (parent && parent !== document.body) {
      if (parent.scrollHeight > parent.clientHeight + 20 && /(auto|scroll)/.test(getComputedStyle(parent).overflowY))
        parent.scrollTop = parent.scrollHeight;
      parent = parent.parentElement;
    }
    window.scrollTo(0, document.documentElement.scrollHeight);
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline && rows().length <= list.length) {
      if (window.__financeCancelled) throw Error('Чтение отменено. Ничего не сохранено.');
      await sleep(250);
    }
    if (rows().length <= list.length) { if (++stalls >= 2) break; }
    else stalls = 0;
    continue;
  }
  const rowText = text(list[index]);
  list[index].click();
  const dialog = await waitFor(() => {
    const el = document.querySelector('[role="dialog"]');
    return el && text(el).split('\n').some(x => x.trim() === 'Статус') && location.pathname.endsWith('/operation') ? el : null;
  });
  const operation = parseCard(location.href, text(dialog), rowText);
  const back = [...dialog.querySelectorAll('button,[role="button"]')].find(el => (el.getAttribute('aria-label') || text(el)) === 'Назад');
  if (!back) throw Error('Не найдена кнопка возврата к истории.');
  back.click();
  await waitFor(() => !document.querySelector('[role="dialog"]'));
  if (Date.parse(operation.occurredAt) < cutoff) { stopReason = 'lookback_reached'; break; }
  found.set(operation.identity, operation);
  index++;
}
if (index >= 300) stopReason = 'limit_reached';
if (!found.size) throw Error('Не прочитано ни одной операции.');
return JSON.stringify({operations: [...found.values()], stopReason});

} catch (error) {
  // Return failures as data so WebKit preserves the actionable parser message.
  return JSON.stringify({error: String(error?.message || 'Не удалось прочитать страницу.')});
}
