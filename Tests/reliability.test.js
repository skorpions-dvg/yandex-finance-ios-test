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
const purchase = 'Тестовый магазин\nСегодня, 06:11\n−1 234,56 ₽\nПодробнее\nКатегория\nРазвлечения\nСтатус\nВыполнено';

// Extra signed values in a card no longer poison history import when the list row
// gives an exact authoritative amount.
const withCashback = purchase.replace('−1 234,56 ₽', '−1 234,56 ₽\nКэшбэк +100 ₽');
assert.equal(parse(url([ref]), withCashback, 'Тестовый магазин −1 234,56 ₽').amountKopecks, -123456);
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

// A stale mobile "Operations for period" sheet must be dismissed instead of
// blocking automatic startup forever after a failed month-resume attempt.
(async () => {
  let sheet = true, closeClicks = 0, clock = 0;
  const choose = {innerText: 'Выбрать', getClientRects: () => sheet ? [{}] : [], closest: () => null,
    getAttribute: () => null, querySelector: () => null,
    getBoundingClientRect: () => ({left: 40, top: 500, width: 300, height: 60}), click() {}};
  const close = {innerText: '', getClientRects: () => sheet ? [{}] : [], closest: () => null,
    getAttribute: () => null, querySelector: sel => sel === 'svg' ? {} : null,
    getBoundingClientRect: () => ({left: 330, top: 110, width: 44, height: 44}),
    click() { closeClicks++; sheet = false; }};
  const document = {get body() { return {innerText: sheet ? 'Операции за период\nС этой даты\nПо эту дату' : 'История'}; },
    querySelectorAll(selector) {
      if (selector === 'button,[role="button"]') return sheet ? [choose, close] : [];
      if (selector.includes('switch') || selector.includes('checkbox')) return [];
      return [];
    }, dispatchEvent() {}};
  const window = {innerWidth: 390};
  class FakeDate extends Date { static now() { return clock; } }
  class FakeKeyboardEvent { constructor() {} }
  const fn = new Function('document','window','Date','setTimeout','KeyboardEvent','location', helpers + '\nreturn dismissHistoryPeriodSheet;')(
    document, window, FakeDate, (cb, ms) => { clock += ms; cb(); }, FakeKeyboardEvent,
    new URL('https://bank.yandex.ru/my/transactions-history'));
  assert.equal(await fn(), true);
  assert.equal(closeClicks, 1, 'the icon-only top-right close button must dismiss the stale period sheet');
  assert.equal(sheet, false);
  console.log('v19 startup recovery: stale period sheet is dismissed instead of hanging the app.');
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
  const row = control('Тестовый магазин −1 234,56 ₽', () => {
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
assert.ok(appSwift.includes('Импортировать выписку'), 'Manual six-month retry button must exist');
assert.ok(source.includes("stopReason === 'running' && (opened >= maxOpened"), 'Limit must not overwrite a more specific stop reason');
assert.ok(!source.includes('enoughMonthChoices'), 'Picker-size heuristic must not mark full history complete');
assert.ok(source.includes('window.__financeCheckpointQueue.push({sequence: ++checkpointSequence, operation})'), 'Parsed operations must enter the checkpoint queue');
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
    control('Хорошая −1 234,56 ₽', () => go('good')),
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
  assert.equal(batch.issues.length, 1);
  assert.ok(batch.issues[0].identity.includes('bad'));
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
  const row = control('Тестовый магазин −1 234,56 ₽', () => {screen = 'card'; location.href = url([{...ref, chainId: 'filter-failure'}]);});
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


// v20: even a known terminal operation must reopen to detect changed details.
(async () => {
  let screen = 'list', clock = Date.parse('2026-10-04T12:00:00Z'), rowClicks = 0, filters = false;
  const knownRef = {...ref, chainId: 'known-fast', operationTimestamp: '2026-09-29T08:00:00Z'};
  const knownURL = url([knownRef]);
  const location = new URL('https://bank.yandex.ru/my/transactions-history');
  const root = {scrollTop: 0, scrollHeight: 500, clientHeight: 500, isConnected: true, dispatchEvent() {}};
  const control = (label, click, aria = '') => ({innerText: label, click, parentElement: root,
    getClientRects: () => [{}], getAttribute: key => key === 'aria-label' ? aria : null, contains: () => false,
    closest: () => null, querySelector: () => null,
    getBoundingClientRect: () => ({left: 0, right: 0, top: 0, width: 1, height: 1})});
  const filter = control('', () => { filters = true; }, 'Какие операции скрывать');
  const choose = control('Выбрать', () => { filters = false; });
  const month = control('Октябрь 2026', () => {});
  const account = control('Все карты и счета', () => {});
  const row = {
    innerText: 'Тестовый магазин −1 234,56 ₽', href: knownURL, parentElement: root,
    click() { rowClicks++; screen = 'card'; location.href = knownURL; },
    matches(sel) { return sel.includes('a[href'); },
    getAttribute(key) { return key === 'href' ? knownURL : null; },
    getClientRects: () => [{}], contains: () => false, closest: () => null, querySelector: () => null
  };
  const sw = {checked: false, getAttribute: () => 'false', getClientRects: () => [{}], closest: () => null};
  const body = {get innerText() { return screen === 'card' ? purchase : 'История\nНет более ранних операций'; }};
  const document = {body, scrollingElement: root, documentElement: root, querySelectorAll(selector) {
    if (selector === '[role="dialog"],main') return [body];
    if (selector.includes('switch')) return filters ? [sw] : [];
    if (selector === 'button,[role="button"]') return filters ? [choose] : [filter, month, account];
    if (selector === 'a[href*="/my/transactions-history/operation"]') return filters ? [] : [row];
    if (selector.includes('[role="option"]')) return [];
    return [];
  }};
  const window = {history: {back() { screen = 'list'; location.href = 'https://bank.yandex.ru/my/transactions-history'; }}};
  class FakeDate extends Date { static now() { return clock; } }
  const known = [{identity: JSON.stringify([['DEPOT','known-fast']]), occurredAt: '2026-09-29T08:00:00.000Z',
    description: 'Тестовый магазин', amountKopecks: -123456, status: 'Выполнено'}];
  const context = vm.createContext({URL, Date: FakeDate, setTimeout: fn => {clock += 100; fn();}, window, location, document,
    getComputedStyle: () => ({overflowY: 'auto'}), Event: class {}});
  const batch = JSON.parse(await vm.runInContext('(async function(mode, lookbackDays, resumeMonthOrdinal, knownOperationsJson) {' + source + '})("history", 7, null, ' + JSON.stringify(JSON.stringify(known)) + ')', context));
  assert.equal(batch.error, undefined);
  assert.equal(rowClicks, 1, 'Known operations must reopen: old status does not prove current status');
  assert.equal(batch.fastSkippedCount, 0);
  assert.equal(batch.openedCardCount, 1);

  console.log('v20: saved linked operations reopen; no status change is hidden by the old fast path.');
})().catch(error => { console.error(error); process.exitCode = 1; });

// v19: regression guards and project consistency.
{
  const models = fs.readFileSync(path.join(__dirname, '../YandexFinance/Models.swift'), 'utf8');
  const project = fs.readFileSync(path.join(__dirname, '../YandexFinance.xcodeproj/project.pbxproj'), 'utf8');
  const workflow = fs.readFileSync(path.join(__dirname, '../.github/workflows/build-ios.yml'), 'utf8');
  const readme = fs.readFileSync(path.join(__dirname, '../README.md'), 'utf8');
  const freeSetup = fs.readFileSync(path.join(__dirname, '../FREE-SETUP.md'), 'utf8');
  const financeEngineForSync = fs.readFileSync(path.join(__dirname, '../YandexFinance/FinanceEngine.swift'), 'utf8');

  assert.ok(!source.includes('Ничего не сохранено'), 'Cancellation/timeout text must not contradict checkpoint saving');
  assert.match(models, /oldestMonthOrdinal:\s*Int\?/, 'Batch must carry the oldest reached month');
  assert.match(models, /monthsVisited:\s*Int\?/, 'Batch must carry month traversal evidence');
  assert.match(workflow, /node Tests\/reliability\.test\.js/, 'GitHub build must execute reliability tests, not only parser tests');
  const financeCompileLine = workflow.split('\n').find(line => /^\s*swiftc\s/.test(line) && line.includes('Tests/FinanceEngineTests.swift'));
  assert.ok(financeCompileLine, 'GitHub build must compile the Swift finance tests');
  const financeCompileArgs = financeCompileLine.trim().split(/\s+/);
  for (const required of ['-warnings-as-errors', '-parse-as-library', 'YandexFinance/FinanceEngine.swift',
                          'YandexFinance/PeriodSelectionLogic.swift', 'Tests/FinanceEngineTests.swift']) {
    assert.ok(financeCompileArgs.includes(required), `Finance test compilation is missing ${required}`);
  }
  assert.match(financeCompileLine, /-o \/tmp\/finance-tests\s*$/);
  assert.match(workflow, /^\s*\/tmp\/finance-tests\s*$/m, 'GitHub build must execute the compiled finance tests');
  const buildVersions = [...project.matchAll(/CURRENT_PROJECT_VERSION = ([0-9.]+);/g)].map(match => match[1]);
  assert.equal(buildVersions.length, 2, 'Debug and Release must both declare a build number');
  assert.equal(buildVersions[0], buildVersions[1], 'Debug and Release build numbers must agree');
  assert.ok(readme.includes(`Текущий номер сборки — ${buildVersions[0]}.`), 'README must match the actual build number');
  assert.ok(!/первый запуск Actions ещё не выполнен/.test(freeSetup));

  const incrementalBlock = swift.match(/private func incrementalPolicy[\s\S]*?private static func operationDate/)[0];
  assert.ok(!/unresolvedIssues/.test(incrementalBlock), 'Old import issues must not expand every automatic refresh');
  assert.match(incrementalBlock, /IncrementalSyncPolicy\.calculate/, 'BankBrowser must delegate incremental window logic to the tested policy');
  assert.match(financeEngineForSync, /static let noStatusWatchDays = 14/, 'Status-less cards must have a finite refresh horizon');
  assert.match(financeEngineForSync, /static let pendingWatchDays = 45/, 'Stale pending operations must have a finite automatic refresh horizon');
  assert.match(financeEngineForSync, /static func isPendingStatus/, 'Pending status classification must have one shared source of truth');
  assert.match(financeEngineForSync, /"в обработке", "обрабатыва", "ожида", "в процессе", "pending", "hold", "заблок"/, 'Pending status variants must stay synchronized');
  assert.match(financeEngineForSync, /static func isOpenStatus\(_ value: String\) -> Bool \{ FinancialEngine\.isPendingStatus\(value\) \}/, 'Incremental sync must reuse finance pending classification');
  assert.match(swift, /let runClean = counts\.rejected == 0 && \(batch\.skippedCount \?\? 0\) == 0 && acceptedIssues\.isEmpty/);
  assert.match(swift, /boundaryReached, runClean, !resumed/, 'Fresh coverage may advance when the current pass is clean even if an older retry issue remains');
  assert.match(swift, /automaticRun:\s*true/, 'Automatic history refresh must identify itself so stale-pending warnings do not spam every launch');
  assert.match(swift, /IncrementalSyncPolicy\.pendingWatchDays/, 'User-facing stale-pending warning must use the same watch-window constant');
  assert.match(appSwift, /Автообновление выключено/, 'UI must remind the user when automatic refresh is disabled');

  const monthParser = new Function(helpers + '\nreturn parseMonthLabel;')();
  assert.deepEqual(monthParser('Октябрь'), {month: 9, year: null});
  assert.deepEqual(monthParser('Период: Октябрь, 2026'), {month: 9, year: 2026});
  assert.deepEqual(monthParser('Выбран Сентябрь · 2025'), {month: 8, year: 2025});
  assert.match(source, /const status = detail\('Статус'\) \|\| 'Не указан'/, 'Status must be optional for operation cards');
  assert.match(source, /internal_transfer/, 'Internal own-account transfers must have a dedicated kind');
  assert.match(source, /interest_income/, 'Interest payouts must have a dedicated kind');
  assert.ok(!swift.includes('knownOperationsJson') && !swift.includes('forceVerification'), 'Unused full-history payload must not be serialized');
  assert.match(models, /fastSkippedCount:\s*Int\?/, 'Batch must expose fast-path metrics');
  assert.match(models, /openedCardCount:\s*Int\?/, 'Batch must expose opened-card metrics');
  assert.match(source, /waitFor\(\(\) => onCard\(\) && currentCardText\(\), 8000\)/, 'Card readiness timeout must be capped at 8 seconds');
  assert.match(source, /dismissHistoryPeriodSheet/, 'A failed month restore must be able to close the mobile period sheet');
  console.log('Project consistency, card timeout, navigation, workflow and documentation guards passed.');
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
  const octRow = control('Октябрьская −1 234,56 ₽', () => {openedOctober++;});
  const sepRow = control('Сентябрьская −1 234,56 ₽', () => {
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
  const batch = JSON.parse(await vm.runInContext('(async function(mode, lookbackDays, resumeMonthOrdinal) {' + source + '})("history", 183, ' + septemberOrdinal + ')', context));
  assert.equal(batch.error, undefined);
  assert.ok(['history_beginning_reached','full_history_exhausted'].includes(batch.stopReason));
  assert.equal(openedOctober, 0, 'Resume must not reread October');
  assert.equal(openedSeptember, 1);
  assert.ok(batch.operations.some(x => x.identity.includes('resume-sep')));
  assert.equal(batch.oldestMonthOrdinal, septemberOrdinal);
  assert.equal(selectedMonth, 'Октябрь 2026', 'Original visible month should be restored after the pass');
  console.log('v18 resume: incomplete six-month sync continues from the saved month instead of current month.');
})().catch(error => { console.error(error); process.exitCode = 1; });

// v20: two simultaneously rendered cards with equal amounts must not mix details.
assert.throws(() => parse(url([ref]), purchase + '\n' + purchase.replace('Тестовый магазин', 'Другой магазин'),
  'Другой магазин −1 234,56 ₽'), /несколько карточек/);
assert.match(swift, /checkpointInFlight/);
assert.match(swift, /activeRunID == runID/);
assert.match(swift, /sequence > throughSequence/);
assert.match(swift, /boundaryReached && runClean/);
assert.match(appSwift, /Продолжить загрузку истории/);
// Execute the actual acknowledgment JS, including a delayed acknowledgment after a new run.
const ack = swift.match(/if \(window.__financeRunID !== expectedRunID\) return false;[\s\S]*?return true;/)[0];
const acknowledge = new Function('window', 'expectedRunID', 'throughSequence', ack);
const checkpointWindow = {__financeRunID:'one', __financeCheckpointQueue:[{sequence:1},{sequence:2}]};
acknowledge(checkpointWindow, 'one', 1);
assert.deepEqual(checkpointWindow.__financeCheckpointQueue, [{sequence:2}]);
acknowledge(checkpointWindow, 'one', 1);
assert.deepEqual(checkpointWindow.__financeCheckpointQueue, [{sequence:2}]);
checkpointWindow.__financeRunID = 'two';
assert.equal(acknowledge(checkpointWindow, 'one', 2), false);
assert.deepEqual(checkpointWindow.__financeCheckpointQueue, [{sequence:2}]);
console.log('v20: ambiguous cards rejected; changed status rechecked; repeated/stale acknowledgments preserve new records.');

// v21: execute direct retry against a synthetic loaded card; verify identity guard.
(async () => {
  const card = {innerText: purchase, getClientRects: () => [{}], closest: () => null};
  const document = {body: card, querySelectorAll: selector => selector === '[role="dialog"],main' ? [card] : []};
  const run = async identity => {
    const context = vm.createContext({URL, Date, setTimeout, document, window: {}, location: new URL(url([ref]))});
    return JSON.parse(await vm.runInContext('(async function(mode,retryIssueJson){' + source +
      '})("retry_card",' + JSON.stringify(JSON.stringify({identity})) + ')', context));
  };
  const correct = await run(JSON.stringify([['DEPOT','test-chain']]));
  assert.equal(correct.operations.length, 1);
  assert.equal(correct.stopReason, 'single_card');
  const wrong = await run(JSON.stringify([['DEPOT','other-chain']]));
  assert.match(wrong.error, /другая операция/);
  assert.equal(wrong.operations, undefined);
  console.log('v21: direct retry reads the requested identity and rejects a different card.');
})().catch(error => { console.error(error); process.exitCode = 1; });

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
  const octRow = control('Октябрьская −1 234,56 ₽', () => {openedOctober++;});
  const sepRow = control('Сентябрьская −1 234,56 ₽', () => {
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
  const batch = JSON.parse(await vm.runInContext('(async function(mode, lookbackDays, resumeMonthOrdinal, retryIssueJson) {' + source + '})("retry", null, ' + septemberOrdinal + ', ' + JSON.stringify(JSON.stringify({identity: JSON.stringify([["DEPOT","resume-sep"]])})) + ')', context));
  assert.equal(batch.error, undefined);
  assert.equal(batch.stopReason, 'issue_retry_completed');
  assert.equal(openedOctober, 0, 'Resume must not reread October');
  assert.equal(openedSeptember, 1);
  assert.ok(batch.operations.some(x => x.identity.includes('resume-sep')));
  assert.equal(batch.oldestMonthOrdinal, septemberOrdinal);
  assert.equal(selectedMonth, 'Октябрь 2026', 'Original visible month should be restored after the pass');
  console.log('v21: legacy issue search scans its saved month and stops on the matching identity.');
})().catch(error => { console.error(error); process.exitCode = 1; });


// v23: fully synthetic grouped-card fixture; no user bank data.
const groupCard = 'Тестовый платёж\n17 марта, 12:02\n−1468 ₽\n2 операции\n17 марта, 12:34\n+312 ₽\n17 марта, 12:02\n−1780 ₽\nПодробнее\nСтатус\nВыполнено';
const groupRef = {type:'OHIO_LINKED_TXNS', chainId:'synthetic-group', operationTimestamp:'2026-03-17T06:02:00Z'};
const groupURL = url([groupRef]);
const parsedGroup = parse(groupURL, groupCard, 'Тестовый платёж −1468 ₽', new Date('2026-10-04T12:00:00Z'));
assert.equal(parsedGroup.kind, 'grouped_operation');
assert.equal(parsedGroup.amountKopecks, -146800);
assert.deepEqual(parsedGroup.components, [
  {displayDate:'17 марта, 12:34', amountKopecks:31200},
  {displayDate:'17 марта, 12:02', amountKopecks:-178000}
]);
assert.equal(parsedGroup.components.reduce((n,x) => n+x.amountKopecks,0), parsedGroup.amountKopecks);
assert.equal(parsedGroup.components.length, 2, 'Net total must not become a third component');
assert.equal(parse(groupURL, groupCard, '').identity, parsedGroup.identity, 'Reread keeps the bank group identity');
const sameAmounts = groupCard.replace('−1468 ₽','−3560 ₽').replace('+312 ₽','−1780 ₽');
assert.equal(parse(groupURL, sameAmounts, '').components.length, 2, 'Equal amounts are separate component occurrences');
const nextGroup = parse(url([{...groupRef, chainId:'synthetic-other-group'}]), groupCard, '');
assert.notEqual(nextGroup.identity, parsedGroup.identity, 'Equal amounts never merge distinct bank identities');
assert.throws(() => parse(groupURL, groupCard.replace('+312 ₽','+313 ₽'), ''), /не совпала/);
assert.throws(() => parse(groupURL, groupCard.replace('2 операции','3 операции'), ''), /все составляющие/);
assert.throws(() => parse(groupURL, groupCard.replace('17 марта, 12:34\n+312 ₽','Не загружено'), ''), /все составляющие/);
assert.throws(() => parse(groupURL, groupCard + '\n' + purchase, ''), /несколько карточек/);
assert.throws(() => parse(groupURL, groupCard + '\n' + groupCard, ''), /Несколько разделов/);
assert.match(appSwift, /TabView\(selection: \$browser.selectedTab\)/);
assert.match(swift, /selectedTab = 0/);
assert.match(appSwift, /Месяц сканера \(не дата платежа\)/);
(async () => {
  const card = {innerText:groupCard, getClientRects:()=>[{}], closest:()=>null};
  const context = vm.createContext({URL,Date,setTimeout,window:{},location:new URL(groupURL),
    document:{body:card,querySelectorAll:sel=>sel==='[role="dialog"],main'?[card]:[]}});
  const result = JSON.parse(await vm.runInContext('(async function(mode,retryIssueJson){'+source+
    '})("retry_card",'+JSON.stringify(JSON.stringify({identity:parsedGroup.identity}))+')',context));
  assert.equal(result.operations.length,1);
  assert.equal(result.operations[0].components.length,2);
  assert.equal(result.operations[0].identity, parsedGroup.identity);
  console.log('v23: grouped retry returns one bank identity with two reconciled components; duplicates, partial groups and mismatched totals tested.');
})().catch(error=>{console.error(error);process.exitCode=1;});


// v25: finance engine is part of the app target; diagnostics and robust period dates are visible.
const projectV25 = fs.readFileSync(path.join(__dirname, '../YandexFinance.xcodeproj/project.pbxproj'), 'utf8');
const financeEngine = fs.readFileSync(path.join(__dirname, '../YandexFinance/FinanceEngine.swift'), 'utf8');
const financeTests = fs.readFileSync(path.join(__dirname, 'FinanceEngineTests.swift'), 'utf8');
assert.match(projectV25, /FinanceEngine\.swift/);
// Build numbers and README consistency are checked together above.
assert.match(appSwift, /Label\("Финансы", systemImage: "chart\.pie"\)/);
assert.match(appSwift, /Банковские списания/);
assert.match(appSwift, /DisclosureGroup/);
assert.match(financeEngine, /case internalTransfer = "internal_transfer"/);
assert.match(financeEngine, /case interestIncome = "interest_income"/);
assert.match(financeEngine, /kind == "grouped_operation"/);
assert.match(financeEngine, /components are diagnostic detail only/i);
assert.match(financeTests, /positive unknown kind must not be guessed as income/);
assert.match(financeEngine, /includingFractionalSeconds:\s*true/);
assert.match(financeEngine, /date >= interval\.start && date < interval\.end/);
assert.match(appSwift, /Не распознано дат/);
assert.match(financeEngine, /Снятие наличных — перемещение денег, а не покупка/);
assert.match(financeTests, /cash withdrawal/);
assert.match(appSwift, /let report = FinancialEngine\.report/);
assert.match(appSwift, /resetLocalStorage/);
assert.match(swift, /Не сохранено после проверки/);
assert.match(source, /V34\.6\.3 keeps conservative verification/);
assert.match(source, /перевод между счетами одного клиента/);
assert.match(appSwift, /Section\(\"Сейв\"\)/);
assert.match(appSwift, /Карта ↔ Сейв/);
console.log('v25: finance engine handles fractional ISO8601 dates, half-open periods, and surfaces invalid dates.');


// v34.1: category hardening, storage recovery, bounded refresh, navigation, and diagnostics must stay wired.
assert.match(swift, /func retryOpenStorage\(\)/, 'storage failure must offer a non-destructive retry');
assert.match(swift, /storageRetryFailed/, 'destructive reset must be gated behind a failed retry');
assert.match(swift, /counts\.rejected == 0 && \(batch\.skippedCount/, 'rejected operations must prevent a run from being marked clean');
assert.match(swift, /IncrementalSyncPolicy\.calculate/, 'BankBrowser must use the tested incremental sync policy');
assert.match(appSwift, /Повторить открытие/, 'storage retry must be visible in the UI');
assert.match(appSwift, /автообновление после сброса будет выключено/i, 'reset warning must explain that automatic bootstrap is suppressed');
assert.match(financeEngine, /negative movement is an outflow/i, 'negative stale metadata must fall back by direction');
assert.match(financeEngine, /unknownDetails\.append\(FinanceLine/, 'unknown operations must expose per-operation diagnostics');
assert.match(financeEngine, /static func expenseCategory\(for operation:/, 'finance taxonomy must have one shared expense mapper');
assert.match(financeEngine, /operation\.mcc/, 'expense taxonomy should use MCC as a high-confidence fallback');
assert.match(financeEngine, /\"Еда\", \"Транспорт\", \"Покупки\", \"Обязательные\", \"Другое\"/, 'expense groups must use the agreed user-facing hierarchy');
assert.match(appSwift, /FinanceCategoryOperationsView/, 'subcategory taps must open a filtered operations list');
assert.match(appSwift, /selection: \.expense\(group: line\.title, subcategory: child\.title\)/, 'expense subcategory navigation must reuse the same taxonomy');
assert.match(appSwift, /selection: \.income\(subcategory: line\.title\)/, 'income subcategories must open their operations');

assert.match(financeEngine, /technical fallback into financial income|Collector uses .unclassified_income./s, 'unclassified positive movements must not be promoted blindly');
assert.match(financeTests, /technical unclassified income must stay unknown/, 'Swift tests must cover positive unclassified safety');
assert.match(financeTests, /cashback with percent text remains cashback income/, 'cashback must beat generic percent wording');
assert.ok(appSwift.includes('Text("Сборка \\(buildNumber)")'), 'finance screen must expose the installed build number');
assert.match(swift, /operationURL == operationURL/, 'identity-less issues should be deduplicated by operation URL');

// v34.4: period changes cannot be inferred solely from dynamic row updates.
(async () => {
  let clock = 0;
  const ctrl = {innerText:'Октябрь',getAttribute:()=>null,getClientRects:()=>[{}],closest:()=>null};
  const row = {innerText:'Новая строка −100 ₽',getAttribute:()=>null,getClientRects:()=>[{}],closest:()=>null,contains:()=>false};
  const document = {body:{innerText:'История'},querySelectorAll:sel=>sel==='button,[role="button"]'?[ctrl,row]:[]};
  const context = vm.createContext({document,window:{},Date:{now:()=>clock},setTimeout:(fn,ms)=>{clock+=ms;fn();}});
  const change = vm.runInContext('(function(){'+helpers+';return applyHistoryMonthChoice;})()',context);
  const result = await change({el:{click(){}}},{month:8,year:2026},'old rows');
  assert.equal(result.status,'unavailable','Changed rows with unchanged October selector do not prove September');
  console.log('v34.4: unrelated row update cannot confirm a different month.');
})().catch(e=>{console.error(e);process.exitCode=1;});
const month35 = new Function(helpers+'\nreturn parseMonthLabel;')();
assert.deepEqual(month35('01.10–04.10'),{month:9,year:null});
assert.deepEqual(month35('01.10.2026 — 04.10.2026'),{month:9,year:2026});
assert.equal(month35('29.09–04.10'),null);
assert.equal(month35('01.13–04.13'),null);
const noStamp35 = url([{type:'DEPOT',chainId:'synthetic-date'}]);
assert.throws(()=>parse(noStamp35,purchase.replace('Сегодня, 06:11','31 апреля, 06:11'),''),/календарная дата/);
assert.throws(()=>parse(noStamp35,purchase.replace('Сегодня, 06:11','Сегодня, 24:61'),''),/время/);
