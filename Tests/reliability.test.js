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

// Returning from a full-page operation must survive an unlabeled icon-only back
// control and a swallowed History API back navigation. The icon is retried after
// history.back() because the bank shell can change layers without changing route.
(async () => {
  let screen = 'card', clock = 0, arrowClicks = 0, historyBacks = 0;
  const location = new URL('https://bank.yandex.ru/my/transactions-history/operation?id=x');
  const arrow = {
    innerText: '',
    getClientRects: () => [{}],
    closest: () => null,
    querySelector: selector => selector === 'svg' ? {} : null,
    getBoundingClientRect: () => ({left: 24, right: 68, top: 90, width: 44, height: 44}),
    getAttribute: () => null,
    click() {
      arrowClicks++;
      if (arrowClicks >= 2) {
        screen = 'list';
        location.href = 'https://bank.yandex.ru/my/transactions-history';
      }
    }
  };
  const body = {get innerText() { return screen === 'card' ? purchase : 'История'; }};
  const document = {body, querySelectorAll(selector) {
    if (selector === 'button,[role="button"],a[href]') return screen === 'card' ? [arrow] : [];
    if (selector === 'button,[role="button"]') return [];
    if (selector.includes('switch') || selector.includes('checkbox')) return [];
    if (selector.includes('[role="option"]')) return [];
    return [];
  }};
  const window = {innerWidth: 390, history: {back() { historyBacks++; /* intentionally swallowed */ }}};
  class FakeDate extends Date { static now() { return clock; } }
  const context = vm.createContext({URL, Date: FakeDate, setTimeout: (fn, ms) => { clock += ms; fn(); },
    window, location, document});
  const leave = vm.runInContext('(function(){' + helpers + '; return leaveOperationCard;})()', context);
  assert.equal(await leave(), true);
  assert.equal(screen, 'list');
  assert.equal(historyBacks, 1, 'history.back must be attempted after the first arrow click fails');
  assert.equal(arrowClicks, 2, 'the unlabeled top-left arrow must be retried after a swallowed history.back');
  console.log('Card navigation: unlabeled arrow + swallowed history.back recovers without a 20-second stall.');
})().catch(error => { console.error(error); process.exitCode = 1; });

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
  assert.equal(batch.warning, null, 'Cancellation must not append a contradictory warning');
  console.log('Cancellation: already parsed operations are returned for saving without contradictory warning text.');
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

// v16: regression guards and project consistency.
{
  const models = fs.readFileSync(path.join(__dirname, '../YandexFinance/Models.swift'), 'utf8');
  const project = fs.readFileSync(path.join(__dirname, '../YandexFinance.xcodeproj/project.pbxproj'), 'utf8');
  const workflow = fs.readFileSync(path.join(__dirname, '../.github/workflows/build-ios.yml'), 'utf8');
  const readme = fs.readFileSync(path.join(__dirname, '../README.md'), 'utf8');
  const freeSetup = fs.readFileSync(path.join(__dirname, '../FREE-SETUP.md'), 'utf8');

  assert.ok(!source.includes('Ничего не сохранено'), 'Cancellation/timeout text must not contradict checkpoint saving');
  const exhaustedCase = swift.match(/case "full_history_exhausted":([\s\S]*?)case "history_beginning_reached":/)?.[1] || '';
  assert.match(exhaustedCase, /fullHistoryImported\s*=\s*true/, 'A skipped card must not block completion after the history boundary was reached');
  assert.ok(!/skipped\s*==\s*0[\s\S]*fullHistoryImported\s*=\s*true/.test(swift), 'Full completion must not require zero parser skips');
  assert.match(swift, /fullHistoryResumeOrdinal/, 'Interrupted full sync must persist a resume month');
  assert.match(models, /oldestMonthOrdinal:\s*Int\?/, 'Batch must carry the oldest reached month');
  assert.match(models, /monthsVisited:\s*Int\?/, 'Batch must carry month traversal evidence');
  assert.match(workflow, /node Tests\/reliability\.test\.js/, 'GitHub build must execute reliability tests, not only parser tests');
  assert.equal((project.match(/CURRENT_PROJECT_VERSION = 16;/g) || []).length, 2, 'Debug and Release build number must both be 16');
  assert.match(readme, /текущий номер сборки — 16/);
  assert.ok(!/первый запуск Actions ещё не выполнен/.test(freeSetup));

  const monthParser = new Function(helpers + '\nreturn parseMonthLabel;')();
  assert.deepEqual(monthParser('Октябрь'), {month: 9, year: null});
  assert.deepEqual(monthParser('Период: Октябрь, 2026'), {month: 9, year: 2026});
  assert.deepEqual(monthParser('Выбран Сентябрь · 2025'), {month: 8, year: 2025});
  assert.match(source, /const status = detail\('Статус'\) \|\| 'Не указан'/, 'Status must be optional for operation cards');
  assert.match(source, /internal_transfer/, 'Internal own-account transfers must have a dedicated kind');
  assert.match(source, /interest_income/, 'Interest payouts must have a dedicated kind');
  assert.match(swift, /fullHistoryImportedV5/, 'v15 must invalidate old full-history completion so formerly skipped cards are revisited');
  assert.match(swift, /fullHistoryResumeOrdinalV2/, 'v15 must also invalidate old resume points so skipped cards in newer months are rescanned');
  assert.match(swift, /fullHistoryBoundaryOrdinalV2/, 'v15 must not reuse old boundary confirmation evidence');
  console.log('v16 static guards: completion, resume, cancellation wording, status-less cards, navigation fallback, workflow and docs passed.');
}

// A resumed full pass starts from the saved oldest month instead of rereading the current month.
(async () => {
  let screen = 'list', clock = Date.parse('2026-10-04T12:00:00Z'), picker = false, selectedMonth = 'Октябрь 2026';
  let openedOctober = 0, openedSeptember = 0;
  const location = new URL('https://bank.yandex.ru/my/transactions-history');
  const body = {get innerText() {
    if (screen === 'card-sep') return purchase;
    return selectedMonth.startsWith('Сентябрь') ? 'История\nЭто все операции' : 'История';
  }};
  const root = {scrollTop: 0, scrollHeight: 500, clientHeight: 500, isConnected: true, dispatchEvent() {}};
  const control = (label, click, aria = '') => ({innerText: label, click, parentElement: root,
    getClientRects: () => [{}], getAttribute: key => key === 'aria-label' ? aria : null, contains: () => false,
    closest: () => null, querySelector: sel => sel === 'svg' ? {} : null,
    getBoundingClientRect: () => ({left: 0, right: 0, top: 0, width: 1, height: 1})});
  const octRow = control('Октябрьская −2 013,84 ₽', () => {openedOctober++;});
  const sepRow = control('Сентябрьская −2 013,84 ₽', () => {
    openedSeptember++; screen = 'card-sep';
    location.href = url([{...ref, chainId: 'resume-sep', operationTimestamp: '2026-09-20T08:00:00Z'}]);
  });
  const filter = control('', () => {screen = 'filters';}, 'Какие операции скрывать');
  const chooseFilter = control('Выбрать', () => {screen = 'list';});
  const account = control('Все карты и счета', () => {});
  const monthButton = () => control('Период: ' + selectedMonth, () => {picker = true;});
  const sepChoice = control('Сентябрь 2026', () => {selectedMonth = 'Сентябрь 2026'; picker = false; root.scrollTop = 0;});
  const octChoice = control('Октябрь 2026', () => {selectedMonth = 'Октябрь 2026'; picker = false; root.scrollTop = 0;});
  const sw = {checked: false, getAttribute: () => 'false', getClientRects: () => [{}], closest: () => null};
  const actionables = () => {
    if (screen === 'filters') return [chooseFilter];
    if (screen !== 'list') return [];
    const list = selectedMonth.startsWith('Октябрь') ? [octRow] : [sepRow];
    const base = [filter, monthButton(), account, ...list];
    return picker ? [...base, sepChoice, octChoice] : base;
  };
  const document = {body, scrollingElement: root, documentElement: root, querySelectorAll(selector) {
    if (selector === '[role="dialog"],main') return [body];
    if (selector.includes('switch')) return screen === 'filters' ? [sw] : [];
    if (selector === 'button,[role="button"]' || selector.includes('[role="option"]')) return actionables();
    return [];
  }};
  const window = {history: {back() {screen = 'list'; location.href = 'https://bank.yandex.ru/my/transactions-history';}}};
  class FakeDate extends Date { static now() { return clock; } }
  const context = vm.createContext({URL, Date: FakeDate, setTimeout: fn => {clock += 250; fn();}, window, location, document,
    getComputedStyle: () => ({overflowY: 'auto'}), Event: class {}});
  const septemberOrdinal = 2026 * 12 + 8;
  const batch = JSON.parse(await vm.runInContext('(async function(mode, lookbackDays, resumeMonthOrdinal) {' + source + '})("history", null, ' + septemberOrdinal + ')', context));
  assert.equal(batch.error, undefined);
  assert.equal(batch.stopReason, 'full_history_exhausted');
  assert.equal(openedOctober, 0, 'Resume must not reread October');
  assert.equal(openedSeptember, 1);
  assert.ok(batch.operations.some(x => x.identity.includes('resume-sep')));
  assert.equal(batch.oldestMonthOrdinal, septemberOrdinal);
  assert.equal(selectedMonth, 'Октябрь 2026', 'Original visible month should be restored after the pass');
  console.log('v16 resume: incomplete full sync continues from the saved month instead of current month.');
})().catch(error => { console.error(error); process.exitCode = 1; });
