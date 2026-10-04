// Reliability regressions for interrupted imports and defensive UI handling.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../YandexFinance/Collector.js'), 'utf8');
const swift = fs.readFileSync(path.join(__dirname, '../YandexFinance/BankBrowser.swift'), 'utf8');
const appSwift = fs.readFileSync(path.join(__dirname, '../YandexFinance/YandexFinanceApp.swift'), 'utf8');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
new AsyncFunction('mode', 'lookbackDays', source);

const helpers = source.split('\nconst found = new Map();')[0];
const parse = new Function(helpers + '\nreturn parseCard;')();
const url = refs => 'https://bank.yandex.ru/my/transactions-history/operation?id=' + encodeURIComponent(JSON.stringify(refs));
const ref = {type: 'DEPOT', chainId: 'test-chain', operationTimestamp: '2026-10-04T00:11:31.705Z'};
const purchase = 'Тестовый магазин\nСегодня, 06:11\n−2 013,84 ₽\nПодробнее\nКатегория\nРазвлечения\nСтатус\nВыполнено';

// Extra signed values in a card no longer poison history import when the list row
// gives an exact authoritative amount.
const withCashback = purchase.replace('−2 013,84 ₽', '−2 013,84 ₽\nКэшбэк +100 ₽');
assert.equal(parse(url([ref]), withCashback, 'Тестовый магазин −2 013,84 ₽').amountKopecks, -201384);
assert.throws(() => parse(url([ref]), withCashback, ''), /найдено сумм: 2/);

// currentCardText must prefer the actual small visible card over a persistent shell.
{
  const card = {innerText: purchase, getClientRects: () => [{}], closest: () => null};
  const shell = {innerText: 'История\n+50 ₽\n' + purchase + '\n' + purchase, getClientRects: () => [{}], closest: () => null};
  const body = {innerText: shell.innerText};
  const document = {body, querySelectorAll: selector => selector === '[role="dialog"],main' ? [shell, card] : []};
  const fn = new Function('document', helpers + '\nreturn currentCardText;')(document);
  assert.equal(fn(), purchase);
}

// Enabled "hide operation type" switches are automatically disabled before Apply.
(async () => {
  let enabled = true, closed = false, clock = 0;
  const sw = {checked: true, getAttribute: key => key === 'aria-checked' ? (enabled ? 'true' : 'false') : null,
    getClientRects: () => [{}], closest: () => null, click() { enabled = false; this.checked = false; }};
  const choose = {innerText: 'Выбрать', getClientRects: () => [{}], closest: () => null,
    getAttribute: () => null, click() { closed = true; }};
  const document = {body: {innerText: ''}, querySelectorAll(selector) {
    if (selector.includes('switch') || selector.includes('checkbox')) return closed ? [] : [sw];
    if (selector === 'button,[role="button"]') return [choose];
    return [];
  }};
  const fn = new Function('document','window','Date','setTimeout','location', helpers + '\nreturn closeHistoryFilters;')(
    document, {}, {now: () => clock}, (cb, ms) => {clock += ms; cb();}, new URL('https://bank.yandex.ru/my/transactions-history'));
  await fn();
  assert.equal(enabled, false);
  assert.equal(closed, true);
  console.log('Filter safety: enabled hide-switches are disabled and applied automatically.');
})().catch(error => { console.error(error); process.exitCode = 1; });

// A missing immediately previous month must jump to the nearest older visible month,
// not claim that the bank history ended.
(async () => {
  let clock = 0, picker = false, selectedMonth = 'Октябрь';
  const root = {scrollTop: 0, scrollHeight: 500, clientHeight: 500, isConnected: true, dispatchEvent() {}};
  const control = (label, click) => ({innerText: label, click, parentElement: root,
    getClientRects: () => [{}], getAttribute: () => null, contains: () => false, closest: () => null,
    querySelector: () => null, getBoundingClientRect: () => ({left: 0, right: 0, top: 0, width: 1, height: 1})});
  const monthButton = () => control(selectedMonth, () => {picker = true;});
  const oct = control('Октябрь', () => {selectedMonth = 'Октябрь'; picker = false;});
  const aug = control('Август', () => {selectedMonth = 'Август'; picker = false;});
  const octRow = control('Октябрьская −100 ₽', () => {});
  const augRow = control('Августовская −200 ₽', () => {});
  const actionables = () => {
    const base = [monthButton(), selectedMonth === 'Октябрь' ? octRow : augRow];
    return picker ? [...base, aug, oct] : base;
  };
  const document = {body: {innerText: 'История'}, scrollingElement: root, documentElement: root,
    querySelectorAll(selector) {
      if (selector === 'button,[role="button"]' || selector.includes('[role="option"]')) return actionables();
      if (selector.includes('switch')) return [];
      return [];
    }};
  const fn = new Function('document','window','Date','setTimeout','location','getComputedStyle','Event',
    helpers + '\nreturn selectPreviousHistoryMonth;')(
      document, {}, {now: () => clock}, (cb, ms) => {clock += ms; cb();},
      new URL('https://bank.yandex.ru/my/transactions-history'), () => ({overflowY: 'auto'}), class {});
  const result = await fn({month: 9, year: 2026}, JSON.stringify([octRow.innerText]));
  assert.equal(result.status, 'moved');
  assert.equal(result.cursor.month, 7);
  assert.equal(selectedMonth, 'Август');
  console.log('Month gap: October -> August is treated as a gap, not end-of-history.');
})().catch(error => { console.error(error); process.exitCode = 1; });

// Explicit cancellation after the first parsed operation must return that operation
// instead of turning the whole pass into an error.
(async () => {
  let screen = 'list', clock = Date.parse('2026-10-04T12:00:00Z'), cancelledAfterBack = false;
  const location = new URL('https://bank.yandex.ru/my/transactions-history');
  const root = {scrollTop: 0, scrollHeight: 500, clientHeight: 500, isConnected: true, dispatchEvent() {}};
  const control = (label, click, aria = '') => ({innerText: label, click, parentElement: root,
    getClientRects: () => [{}], getAttribute: key => key === 'aria-label' ? aria : null, contains: () => false,
    closest: () => null, querySelector: sel => sel === 'svg' ? {} : null,
    getBoundingClientRect: () => ({left: 0, right: 0, top: 0, width: 1, height: 1})});
  const row = control('Тестовый магазин −2 013,84 ₽', () => {
    screen = 'card'; location.href = url([{...ref, chainId: 'cancel-save'}]);
  });
  const filter = control('', () => {screen = 'filters';}, 'Какие операции скрывать');
  const month = control('Октябрь', () => {});
  const account = control('Все карты и счета', () => {});
  const choose = control('Выбрать', () => {screen = 'list';});
  const sw = {checked: false, getAttribute: () => 'false', getClientRects: () => [{}], closest: () => null};
  const body = {get innerText() { return screen === 'card' ? purchase : 'История'; }};
  const document = {body, scrollingElement: root, documentElement: root, querySelectorAll(selector) {
    if (selector === '[role="dialog"],main') return [body];
    if (selector.includes('switch')) return screen === 'filters' ? [sw] : [];
    if (selector === 'button,[role="button"]') {
      if (screen === 'list') return [filter, month, account, row];
      if (screen === 'filters') return [choose];
      return [];
    }
    if (selector.includes('[role="option"]')) return screen === 'list' ? [month] : [];
    return [];
  }};
  const window = {history: {back() {
    screen = 'list'; location.href = 'https://bank.yandex.ru/my/transactions-history';
    if (!cancelledAfterBack) { cancelledAfterBack = true; window.__financeCancelled = true; }
  }}};
  class FakeDate extends Date { static now() { return clock; } }
  const context = vm.createContext({URL, Date: FakeDate, setTimeout: fn => {clock += 250; fn();}, window, location, document,
    getComputedStyle: () => ({overflowY: 'auto'}), Event: class {}});
  const batch = JSON.parse(await vm.runInContext('(async function(mode, lookbackDays) {' + source + '})("history", 7)', context));
  assert.equal(batch.error, undefined);
  assert.equal(batch.stopReason, 'cancelled');
  assert.equal(batch.operations.length, 1);
  assert.ok(batch.operations[0].identity.includes('cancel-save'));
  console.log('Cancellation: already parsed operations are returned for saving.');
})().catch(error => { console.error(error); process.exitCode = 1; });

// Static guards for Swift-side regressions Grok identified.
assert.ok(!/var\s+byID\s*=\s*Dictionary\(uniqueKeysWithValues:/.test(swift), 'Duplicate IDs must not crash Dictionary initialization');
const inactiveBody = swift.match(/func becameInactive\(\) \{([\s\S]*?)\n    \}/)?.[1] || '';
assert.ok(!/if\s+busy\s*\{\s*cancel\(\)/.test(inactiveBody) && !/self\.cancel\(\)/.test(inactiveBody), '.inactive must not cancel an active import');
assert.ok(appSwift.includes('Синхронизировать всю историю'), 'Manual full-history retry button must exist');
assert.ok(source.includes("stopReason === 'running' && (opened >= maxOpened"), 'Limit must not overwrite a more specific stop reason');
assert.ok(!source.includes('enoughMonthChoices'), 'Picker-size heuristic must not mark full history complete');
assert.ok(source.includes('window.__financeCheckpointQueue.push(operation)'), 'Parsed operations must enter the checkpoint queue');
assert.ok(swift.includes('flushCheckpointFromWebView()'), 'Swift must periodically persist checkpointed operations');
console.log('Swift/static reliability guards passed.');

// One malformed card must not discard valid cards from the same run.
(async () => {
  let screen = 'list', clock = 0, picker = false;
  const location = new URL('https://bank.yandex.ru/my/transactions-history');
  const root = {scrollTop: 0, scrollHeight: 500, clientHeight: 500, isConnected: true, dispatchEvent() {}};
  const control = (label, click, aria = '') => ({innerText: label, click, parentElement: root,
    getClientRects: () => [{}], getAttribute: key => key === 'aria-label' ? aria : null, contains: () => false,
    closest: () => null, querySelector: sel => sel === 'svg' ? {} : null,
    getBoundingClientRect: () => ({left: 0, right: 0, top: 0, width: 1, height: 1})});
  let currentKey = '';
  const go = key => { currentKey = key; screen = 'card'; location.href = url([{...ref, chainId: key}]); };
  const rows = [
    control('Хорошая −2 013,84 ₽', () => go('good')),
    control('Кривая −999 ₽', () => go('bad'))
  ];
  const filter = control('', () => {screen = 'filters';}, 'Какие операции скрывать');
  const monthButton = control('Октябрь', () => {picker = true;});
  const monthChoice = control('Октябрь', () => {picker = false;});
  const account = control('Все карты и счета', () => {});
  const choose = control('Выбрать', () => {screen = 'list';});
  const sw = {checked: false, getAttribute: () => 'false', getClientRects: () => [{}], closest: () => null};
  const body = {get innerText() {
    if (screen === 'card') return purchase;
    return 'История\nНет более ранних операций';
  }};
  const actionables = () => {
    if (screen === 'filters') return [choose];
    if (screen !== 'list') return [];
    const base = [filter, monthButton, account, ...rows];
    return picker ? [...base, monthChoice] : base;
  };
  const document = {body, scrollingElement: root, documentElement: root, querySelectorAll(selector) {
    if (selector === '[role="dialog"],main') return [body];
    if (selector.includes('switch')) return screen === 'filters' ? [sw] : [];
    if (selector === 'button,[role="button"]' || selector.includes('[role="option"]')) return actionables();
    return [];
  }};
  const window = {history: {back() {screen = 'filters'; location.href = 'https://bank.yandex.ru/my/transactions-history';}}};
  class FakeDate extends Date { static now() { return clock; } }
  const context = vm.createContext({URL, Date: FakeDate, setTimeout: fn => {clock += 250; fn();}, window, location, document,
    getComputedStyle: () => ({overflowY: 'auto'}), Event: class {}});
  const batch = JSON.parse(await vm.runInContext('(async function(mode, lookbackDays) {' + source + '})("history", null)', context));
  assert.equal(batch.error, undefined);
  assert.equal(batch.operations.length, 1);
  assert.equal(batch.skippedCount, 1);
  assert.ok(batch.operations[0].identity.includes('good'));
  assert.match(batch.warning, /Сумма не совпала/);
  console.log('Malformed card: valid operations survive and the bad card is counted as skipped.');
})().catch(error => { console.error(error); process.exitCode = 1; });

// A failure while closing the post-card filter sheet must return the operation
// already parsed before the UI cleanup failed.
(async () => {
  let screen = 'list', clock = 0;
  const location = new URL('https://bank.yandex.ru/my/transactions-history');
  const root = {scrollTop: 0, scrollHeight: 500, clientHeight: 500, isConnected: true, dispatchEvent() {}};
  const control = (label, click, aria = '') => ({innerText: label, click, parentElement: root,
    getClientRects: () => [{}], getAttribute: key => key === 'aria-label' ? aria : null, contains: () => false,
    closest: () => null, querySelector: sel => sel === 'svg' ? {} : null,
    getBoundingClientRect: () => ({left: 0, right: 0, top: 0, width: 1, height: 1})});
  const row = control('Тестовый магазин −2 013,84 ₽', () => {screen = 'card'; location.href = url([{...ref, chainId: 'filter-failure'}]);});
  const filter = control('', () => {screen = 'filters-start';}, 'Какие операции скрывать');
  const month = control('Октябрь', () => {});
  const account = control('Все карты и счета', () => {});
  const choose = control('Выбрать', () => {screen = 'list';});
  const startSwitch = {checked: false, getAttribute: () => 'false', getClientRects: () => [{}], closest: () => null};
  const badSwitch = {checked: false, getAttribute: () => 'false', getClientRects: () => [{}], closest: () => null};
  const body = {get innerText() { return screen === 'card' ? purchase : 'История'; }};
  const document = {body, scrollingElement: root, documentElement: root, querySelectorAll(selector) {
    if (selector === '[role="dialog"],main') return [body];
    if (selector.includes('switch')) {
      if (screen === 'filters-start') return [startSwitch];
      if (screen === 'filters-broken') return [badSwitch];
      return [];
    }
    if (selector === 'button,[role="button"]') {
      if (screen === 'list') return [filter, month, account, row];
      if (screen === 'filters-start') return [choose];
      if (screen === 'filters-broken') return []; // no Apply/Close -> deliberate failure
      return [];
    }
    return [];
  }};
  const window = {history: {back() {screen = 'filters-broken'; location.href = 'https://bank.yandex.ru/my/transactions-history';}}};
  class FakeDate extends Date { static now() { return clock; } }
  const context = vm.createContext({URL, Date: FakeDate, setTimeout: fn => {clock += 250; fn();}, window, location, document,
    getComputedStyle: () => ({overflowY: 'auto'}), Event: class {}});
  const batch = JSON.parse(await vm.runInContext('(async function(mode, lookbackDays) {' + source + '})("history", 7)', context));
  assert.equal(batch.error, undefined);
  assert.equal(batch.stopReason, 'interrupted');
  assert.equal(batch.operations.length, 1);
  assert.ok(batch.operations[0].identity.includes('filter-failure'));
  assert.match(batch.warning, /применить фильтр/);
  console.log('Filter close failure: already parsed operations are returned for saving.');
})().catch(error => { console.error(error); process.exitCode = 1; });
