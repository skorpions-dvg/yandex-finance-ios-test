// Synthetic fixtures only. No bank data or credentials.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../YandexFinance/Collector.js'), 'utf8');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
new AsyncFunction('mode', source); // Validate the entire injected async function.
const parse = new Function(source.split('\ntry {\nassertHistory();')[0] + '\nreturn parseCard;')();
const url = refs => 'https://bank.yandex.ru/my/transactions-history/operation?id=' + encodeURIComponent(JSON.stringify(refs));
const ref = {type: 'DEPOT', chainId: 'test-chain', operationId: 'test-operation', operationTimestamp: '2026-10-04T00:11:31.705Z', chainVersionIds: ['v1']};
const purchase = 'Тестовый магазин\nСегодня, 06:11\n−2 013,84 ₽\nПодробнее\nКатегория\nРазвлечения\nMCC\n5816\nСтатус\nВыполнено';
const first = parse(url([ref]), purchase, 'Тестовый магазин −2 013,84 ₽');
assert.equal(first.amountKopecks, -201384);
assert.equal(first.occurredAt, ref.operationTimestamp);
assert.equal(first.mcc, '5816');
assert.equal(first.kind, 'expense');
const changedVersion = parse(url([{...ref, chainVersionIds: ['v2'], operationId: 'another-version'}]), purchase, '−2 013,84 ₽');
assert.equal(first.identity, changedVersion.identity);
const refund = parse(url([ref]), 'Тестовый магазин\nСегодня, 06:11\n+1 886 ₽\nВозврат\nПодробнее\nКатегория\nСупермаркеты\nСтатус\nВыполнено', '+1 886 ₽');
assert.equal(refund.kind, 'refund');
assert.equal(refund.category, 'Супермаркеты');
const split = parse(url([{type: 'BNPL', operationId: 'test-split'}]), 'Тест Сплита\n29 сентября, 14:32\n+15 299 ₽\nПодробнее\nНазначение\nПлатёж 3 из 4\nСтатус\nВыполнено', 'Платёж +15 299 ₽', new Date(2026, 9, 4, 12));
assert.equal(split.kind, 'installment_payment');
assert.equal(split.timePrecision, 'display_minute');
assert.equal(new Date(split.occurredAt).getDate(), 29);
assert.equal(new Date(split.occurredAt).getHours(), 14);
assert.throws(() => parse(url([ref]), purchase, '−2 000 ₽'), /Сумма не совпала/);
assert.throws(() => parse('https://example.com/my/transactions-history/operation', purchase, ''), /Не открылась/);
assert.throws(() => parse(url([{...ref, operationTimestamp: '2026-10-04T00:11:31'}]), purchase, ''), /часовой пояс/);
assert.throws(() => parse(url([ref]), purchase.replace('Статус\nВыполнено', ''), ''), /статус/);
console.log('Parser: purchase, refund, Split, stable identity, exact kopecks, and rejection cases passed.');

// Exercise the injected script with mobile full-page DOM and structured failures.
async function checkMobile() {
  const vm = require('node:vm');
  const run = async (href, pageText) => {
    const body = {innerText: pageText};
    const context = vm.createContext({URL, Date, setTimeout, window: {}, location: new URL(href),
      document: {body, querySelector: () => null, querySelectorAll: () => [{innerText: 'Список операций'}, {innerText: ''}]}});
    return JSON.parse(await vm.runInContext('(async function(mode) {' + source + '})("card")', context));
  };
  const mobile = await run(url([ref]), 'Назад\n' + purchase);
  assert.equal(mobile.operations[0].amountKopecks, -201384);
  assert.equal(mobile.operations[0].description, 'Тестовый магазин');
  assert.equal(mobile.stopReason, 'single_card');
  const inline = await run(url([ref]), purchase.replace('Статус\nВыполнено', 'Статус\tВыполнено'));
  assert.equal(inline.operations[0].status, 'Выполнено');
  const sameLine = await run(url([ref]), purchase.replace('Статус\nВыполнено', 'Статус: Выполнено'));
  assert.equal(sameLine.operations[0].status, 'Выполнено');
  const missingID = await run('https://bank.yandex.ru/my/transactions-history/operation', purchase);
  assert.match(missingID.error, /идентификатора/);
  assert.equal(missingID.operations, undefined);
  const wrongPage = await run('https://bank.yandex.ru/my/transactions-history', purchase);
  assert.match(wrongPage.error, /подробности/);
  const login = await run('https://passport.yandex.ru/', purchase);
  assert.match(login.error, /войдите/);
  console.log('Mobile full-page card and structured error cases passed.');
}
checkMobile().catch(error => { console.error(error); process.exitCode = 1; });

// WebKit mobile text layout: amount fragments, neighbouring list and detail sums.
for (const rendered of ['−\n2 013,84\n₽', '−2 013\n,84 ₽', '−\t2\u00a0013,84\t₽']) {
  const result = parse(url([ref]), purchase.replace('−2 013,84 ₽', rendered), '');
  assert.equal(result.amountKopecks, -201384);
}
const surrounding = parse(url([ref]), 'История\nДругая покупка −500 ₽\n' + purchase + '\nКомиссия\n−10 ₽', '');
assert.equal(surrounding.amountKopecks, -201384);
assert.equal(surrounding.description, 'Тестовый магазин');
assert.throws(() => parse(url([ref]), purchase.replace('−2 013,84 ₽', '−2 013,84 ₽\n−500 ₽'), ''), /найдено сумм: 2/);
assert.throws(() => parse(url([ref]), purchase.replace('−2 013,84 ₽', '2 013,84 ₽'), ''), /найдено сумм: 0/);
console.log('Mobile amount fragments, surrounding amounts, and ambiguous amount rejection passed.');

async function checkHistory() {
  const vm = require('node:vm');
  let screen = 'list', opened = 0, returned = 0, filtersClosed = 0;
  const location = new URL('https://bank.yandex.ru/my/transactions-history');
  const body = {get innerText() { return screen.startsWith('card') ? purchase.replace('−2 013,84 ₽', '−\n2 013,84\n₽') : 'История'; }};
  const control = (label, click, aria = '') => ({innerText: label, click,
    getAttribute: key => key === 'aria-label' ? aria : null, contains: () => false});
  const go = (index) => { screen = 'card' + index; opened++;
    location.href = url([{...ref, chainId: 'history-' + index,
      operationTimestamp: index === 0 ? new Date().toISOString() : '2000-01-01T00:00:00Z'}]); };
  const list = [control('Тестовый магазин −2 013,84 ₽', () => go(0)), control('Старый магазин −2 013,84 ₽', () => go(1))];
  const filter = control('', () => {screen = 'filters';}, 'Какие операции скрывать');
  const close = control('Выбрать', () => {screen = 'list'; filtersClosed++;});
  const hiddenClose = {...control('', () => {throw Error('Clicked hidden desktop close');}, 'Закрыть'), getClientRects: () => []};
  const account = control('Все карты и счета', () => {});
  const switches = [{checked: false, getAttribute: () => 'false'}];
  const doc = {body,
    querySelector: selector => selector.includes('switch') && screen === 'filters' ? switches[0] : null,
    querySelectorAll: selector => {
      if (selector === '[role="dialog"],main') return [{innerText: 'Постоянный диалог оболочки'}, body];
      if (selector.includes('switch')) return screen === 'filters' ? switches : [];
      if (selector === 'button,[role="button"]') return screen === 'list' ? [filter, account, ...list] : screen === 'filters' ? [hiddenClose, close] : [];
      return [];
    }};
  const window = {history: {back() {returned++; screen = 'filters'; location.href = 'https://bank.yandex.ru/my/transactions-history';}}};
  const context = vm.createContext({URL, Date, setTimeout: fn => {fn();}, window, location, document: doc});
  const batch = JSON.parse(await vm.runInContext('(async function(mode) {' + source + '})("history")', context));
  assert.equal(batch.error, undefined);
  assert.equal(batch.operations.length, 1);
  assert.equal(batch.operations[0].amountKopecks, -201384);
  assert.equal(batch.stopReason, 'lookback_reached');
  assert.equal(opened, 2);
  assert.equal(returned, 2);
  assert.equal(filtersClosed, 3);
  assert.equal(screen, 'list');
  console.log('History integration: persistent dialog, icon filter, mobile cards, back navigation, and date cutoff passed.');
}
checkHistory().catch(error => {console.error(error); process.exitCode = 1;});

// A fixed-size virtual list must be detected by contents, not only row count.
const signature = new Function(source.split('\ntry {\nassertHistory();')[0] + '\nreturn rowSignature;')();
assert.notEqual(signature([{innerText: 'A −10 ₽'}, {innerText: 'B −20 ₽'}]), signature([{innerText: 'B −20 ₽'}, {innerText: 'C −30 ₽'}]));
const scrollSource = source.split('\ntry {\nassertHistory();')[0] + '\nreturn scrollHistory;';
let scrollEvents = 0;
const scrollParent = {scrollHeight: 2000, clientHeight: 500, scrollTop: 0, dispatchEvent: () => scrollEvents++};
const scroller = new Function('document', 'window', 'getComputedStyle', 'Event', scrollSource)(
  {body: {}}, {scrollBy: () => {throw Error('Wrong scroll container');}}, () => ({overflowY: 'auto'}), class {});
scroller([{parentElement: scrollParent}]);
assert.equal(scrollParent.scrollTop, 400);
assert.equal(scrollEvents, 1);
console.log('Mobile apply-button cleanup, virtual-list changes and nested scrolling checks passed.');
