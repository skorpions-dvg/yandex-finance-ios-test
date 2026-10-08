// Synthetic fixtures only. No bank data or credentials.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../YandexFinance/Collector.js'), 'utf8');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
new AsyncFunction('mode', source); // Validate the entire injected async function.
const parse = new Function(source.split('\nconst found = new Map();')[0] + '\nreturn parseCard;')();

// Stage 53: fictional independent cases. Run --known53 separately for desired behaviour that currently fails.
function audit53BankRows(knownOnly = false) {
  const makeCard = (title, amount, details = '') => `${title}\nСегодня, 10:30\n${amount} ₽\nПодробнее\nСтатус\nВыполнено\n${details}`;
  const cases = [
    ['interest-row', 'Выплата процентов Тест', '+2,03', 'Выплата процентов Тест +2,03 ₽ Счёт в Сейвах', '', 'Счёт в Сейвах', 'interest_income'],
    ['interest-destination', 'Начислены проценты Тест', '+3,17', 'Начислены проценты Тест +3,17 ₽', 'Пополнение\nНа счёт в Сейвах', 'Счёт в Сейвах', 'interest_income'],
    ['to-card-leg', 'Карта Пэй → Счёт в Сейвах', '−200,00', 'Счёт в Сейвах −200,00 ₽ Карта Пэй', '', 'Карта Пэй', 'internal_transfer'],
    ['to-save-leg', 'Карта Пэй → Счёт в Сейвах', '+200,00', 'Счёт в Сейвах +200,00 ₽ Счёт в Сейвах', '', 'Счёт в Сейвах', 'internal_transfer'],
    ['from-save-leg', 'Счёт в Сейвах → Карта Пэй', '−75,00', 'Карта Пэй −75,00 ₽ Счёт в Сейвах', '', 'Счёт в Сейвах', 'internal_transfer'],
    ['from-card-leg', 'Счёт в Сейвах → Карта Пэй', '+75,00', 'Карта Пэй +75,00 ₽ Карта Пэй', '', 'Карта Пэй', 'internal_transfer'],
    ['split-shop', 'Магазин Рассвет Тест', '−90,00', 'Магазин Рассвет Тест −90,00 ₽ Сплит', '', 'Сплит', 'expense'],
    ['points-shop', 'Магазин Радуга Тест', '−12,00', 'Магазин Радуга Тест −12,00 ₽ Баллы Плюса', '', 'Баллы Плюса', 'expense'],
    ['refund', 'Возврат покупки Тест', '+10,00', 'Возврат покупки Тест +10,00 ₽ Карта Пэй', 'Категория\nВозврат', 'Карта Пэй', 'refund'],
    ['bonus-icon', 'Магазин Рассвет Тест', '−83,00', 'Магазин Рассвет Тест −83,00 ₽ +60 Карта Пэй', '', 'Карта Пэй', 'expense'],
    ['explicit-card', 'Магазин Север Тест', '−80,00', 'Магазин Север Тест −80,00 ₽ Сплит', 'Способ оплаты\nКарта *2733', 'Карта *2733', 'expense'],
    ['explicit-save', 'Выплата процентов Тест', '+1,00', 'Выплата процентов Тест +1,00 ₽ Карта Пэй', 'Способ оплаты\nСчёт в Сейвах', 'Счёт в Сейвах', 'interest_income'],
    ['unlabelled', 'Магазин Север Тест', '−9,00', 'Магазин Север Тест −9,00 ₽', '', null, 'expense'],
    ['missing-row-sum', 'Магазин Север Тест', '−9,01', 'Магазин Север Тест', '', null, 'expense'],
    ['merchant-split-before-sum', 'Магазин Тест Сплит', '−19,00', 'Магазин Тест Сплит −19,00 ₽', '', null, 'expense'],
    ['merchant-card-before-sum', 'Магазин Тест Карта Пэй', '−18,00', 'Магазин Тест Карта Пэй −18,00 ₽', '', null, 'expense'],
    ['merchant-points-before-sum', 'Магазин Тест Баллы Плюса', '−17,00', 'Магазин Тест Баллы Плюса −17,00 ₽', '', null, 'expense'],
    ['merchant-split-no-sum', 'Магазин Тест Сплит', '−19,01', 'Магазин Тест Сплит', '', null, 'expense', true],
    ['merchant-card-no-sum', 'Магазин Тест Карта Пэй', '−18,01', 'Магазин Тест Карта Пэй', '', null, 'expense', true],
    ['merchant-points-no-sum', 'Магазин Тест Баллы Плюса', '−17,01', 'Магазин Тест Баллы Плюса', '', null, 'expense', true],
  ];
  let passed = 0;
  const failures = [];
  for (const [id, title, sum, row, details, method, kind, known] of cases) {
    if (!!known !== knownOnly) continue;
    const reference = {type: 'DEPOT', chainId: `audit53-${id}`, operationId: `audit53-${id}`, operationTimestamp: '2033-03-10T10:30:00Z'};
    const address = 'https://bank.yandex.ru/my/transactions-history/operation?id=' + encodeURIComponent(JSON.stringify([reference]));
    const actual = parse(address, makeCard(title, sum, details), row, new Date('2033-03-11T12:00:00Z'));
    try {
      assert.equal(actual.paymentMethod, method, id + ': account label must not come from the merchant name');
      assert.equal(actual.kind, kind, id + ': financial nature');
      assert.equal(actual.description, title, id + ': title is preserved');
      assert.equal(actual.amountKopecks, Math.round(Number(sum.replace('−', '-').replace(',', '.')) * 100), id + ': exact amount');
      passed++;
    } catch (error) {
      if (!knownOnly) throw error;
      failures.push({id, expected: method, actual: actual.paymentMethod, row, card: makeCard(title, sum, details)});
    }
  }
  console.log('BANK53 ' + JSON.stringify({passed, failures}));
  return failures;
}
if (process.argv.includes('--known53')) {
  const failures = audit53BankRows(true);
  process.exitCode = failures.length ? 1 : 0;
} else {
  audit53BankRows();
}
const url = refs => 'https://bank.yandex.ru/my/transactions-history/operation?id=' + encodeURIComponent(JSON.stringify(refs));
const ref = {type: 'DEPOT', chainId: 'test-chain', operationId: 'test-operation', operationTimestamp: '2026-09-18T08:15:31.705Z', chainVersionIds: ['v1']};
const purchase = 'Тестовый магазин\nСегодня, 06:11\n−1 234,56 ₽\nПодробнее\nКатегория\nРазвлечения\nMCC\n5816\nСтатус\nВыполнено';
const first = parse(url([ref]), purchase, 'Тестовый магазин −1 234,56 ₽');
assert.equal(first.amountKopecks, -123456);
assert.equal(first.occurredAt, ref.operationTimestamp);
assert.equal(first.mcc, '5816');
assert.equal(first.kind, 'expense');
const changedVersion = parse(url([{...ref, chainVersionIds: ['v2'], operationId: 'another-version'}]), purchase, '−1 234,56 ₽');
assert.equal(first.identity, changedVersion.identity);
const refund = parse(url([ref]), 'Тестовый магазин\nСегодня, 06:11\n+789,10 ₽\nВозврат\nПодробнее\nКатегория\nСупермаркеты\nСтатус\nВыполнено', '+789,10 ₽');
assert.equal(refund.kind, 'refund');
assert.equal(refund.category, 'Супермаркеты');
const split = parse(url([{type: 'BNPL', operationId: 'test-split'}]), 'Тест Сплита\n18 сентября, 14:32\n+4 321 ₽\nПодробнее\nНазначение\nПлатёж 3 из 4\nСтатус\nВыполнено', 'Платёж +4 321 ₽', new Date(2026, 9, 20, 12));
assert.equal(split.kind, 'installment_payment');
assert.equal(split.timePrecision, 'display_minute');
assert.equal(new Date(split.occurredAt).getDate(), 18);
assert.equal(new Date(split.occurredAt).getHours(), 14);
assert.throws(() => parse(url([ref]), purchase, '−2 000 ₽'), /Сумма не совпала/);
assert.throws(() => parse('https://example.com/my/transactions-history/operation', purchase, ''), /Не открылась/);
assert.throws(() => parse(url([{...ref, operationTimestamp: '2026-09-18T08:15:31'}]), purchase, ''), /часовой пояс/);
const missingStatusPurchase = parse(url([ref]), purchase.replace('Статус\nВыполнено', ''), '−1 234,56 ₽');
assert.equal(missingStatusPurchase.status, 'Не указан');
assert.equal(missingStatusPurchase.kind, 'expense');
console.log('Parser: purchase, refund, Split, stable identity, exact kopecks, and rejection cases passed.');

// The account of a row (46.11). An interest payout to Save: the card has no payment method, the row and the destination
// say which account it is.
const payoutText = 'Выплата процентов\nСегодня, 10:30\n+19,18 ₽\nПоддержка\nПодробнее\nПополнение\nНа счёт в Сейвах';
const payoutFromRow = parse(url([ref]), payoutText, 'Выплата процентов Пополнение +19,18 ₽ Счёт в Сейвах');
assert.equal(payoutFromRow.kind, 'interest_income');
assert.equal(payoutFromRow.paymentMethod, 'Счёт в Сейвах', 'the interest belongs to the Save account named in the row');
const payoutFromDestination = parse(url([ref]), payoutText, 'Выплата процентов Пополнение +19,18 ₽');
assert.equal(payoutFromDestination.paymentMethod, 'Счёт в Сейвах', 'without the row label the destination in the card decides');
const cardRow = parse(url([ref]), purchase, 'Тестовый магазин Развлечения −1 234,56 ₽ +60 Карта Пэй');
assert.equal(cardRow.paymentMethod, 'Карта Пэй', 'a purchase from the card keeps its account');
const splitRow = parse(url([ref]), purchase, 'Тестовый магазин −1 234,56 ₽ Сплит');
assert.equal(splitRow.paymentMethod, 'Сплит', 'a purchase made with Split belongs to Split');
const pointsRow = parse(url([ref]), purchase, 'Тестовый магазин −1 234,56 ₽ Баллы Плюса');
assert.equal(pointsRow.paymentMethod, 'Баллы Плюса', 'a payment with Plus points belongs to the points');
const methodWins = parse(url([ref]), purchase.replace('Статус', 'Способ оплаты\nКарта *2733\nСтатус'), 'Тестовый магазин −1 234,56 ₽ Карта Пэй');
assert.equal(methodWins.paymentMethod, 'Карта *2733', 'the payment method of the card stays the strongest source');
assert.equal(first.paymentMethod, null, 'a row without any account label stays without one');
console.log('Parser: the account of a row (card, Save, Split, points) passed.');

// v16 regression shape: status-less mobile cards must be ready and
// classified without a 20-second wait.
const demoTransferRef = {...ref, chainId: 'demo-savings-to-pay', operationTimestamp: '2026-08-14T06:34:00Z'};
const savingsToPay = [
  'Счёт в Сейвах → Карта Пэй',
  '14 августа, 12:34',
  '+321 ₽',
  'Чат с поддержкой',
  'Получить квитанцию',
  'Подробнее',
  'Перевод',
  'Со счёта в Сейвах',
  'Куда',
  'На карту Пэй'
].join('\n');
const internal = parse(url([demoTransferRef]), savingsToPay, 'Счёт в Сейвах → Карта Пэй +321 ₽', new Date(2026, 9, 4));
assert.equal(internal.amountKopecks, 32100);
assert.equal(internal.status, 'Не указан');
assert.equal(internal.kind, 'internal_transfer');
assert.equal(internal.category, 'Переводы между своими счетами');

// Card → Save transfer: one bank card with a part per account; the shared history lists both parts as rows.
const cardToSaveRef = {...ref, chainId: 'demo-card-to-save', operationTimestamp: '2026-10-07T09:04:56.635Z'};
const cardToSave = [
  'Карта Пэй → Счёт в Сейвах',
  'Сегодня, 15:04',
  '70 000 ₽',
  'Карта Пэй',
  '−70 000 ₽',
  'Счёт в Сейвах',
  '+70 000 ₽',
  'Подробнее',
  'Перевод',
  'С карты Пэй',
  'Куда',
  'На счёт в Сейвах'
].join('\n');
const cardPart = parse(url([cardToSaveRef]), cardToSave, 'Счёт в Сейвах −70 000 ₽', new Date(2026, 9, 7, 16));
assert.equal(cardPart.amountKopecks, -7000000);
assert.equal(cardPart.kind, 'internal_transfer', 'the card part is an own transfer, not a payment to others');
assert.equal(cardPart.paymentMethod, 'Карта Пэй', 'the card part names the card');
const savePart = parse(url([{...cardToSaveRef, chainId: 'demo-card-to-save-2'}]), cardToSave, 'Счёт в Сейвах +70 000 ₽', new Date(2026, 9, 7, 16));
assert.equal(savePart.amountKopecks, 7000000);
assert.equal(savePart.kind, 'internal_transfer', 'the Save part is not a refund');
assert.equal(savePart.paymentMethod, 'Счёт в Сейвах', 'the Save part names the Save account, so it never moves the card balance');
const plainPurchase = parse(url([ref]), purchase, 'Тестовый магазин −1 234,56 ₽');
assert.equal(plainPurchase.paymentMethod, null, 'ordinary cards keep their own payment method');

const demoInterestRef = {...ref, chainId: 'demo-savings-interest', operationTimestamp: '2026-08-14T02:15:00Z'};
const interestCard = [
  'Выплата процентов',
  '14 августа, 08:15',
  '+1,23 ₽',
  'Чат с поддержкой',
  'Подробнее',
  'Пополнение',
  'На счёт в Сейвах'
].join('\n');
const interest = parse(url([demoInterestRef]), interestCard, 'Выплата процентов +1,23 ₽', new Date(2026, 9, 4));
assert.equal(interest.amountKopecks, 123);
assert.equal(interest.status, 'Не указан');
assert.equal(interest.kind, 'interest_income');
assert.equal(interest.category, 'Проценты');
console.log('v16 parser: status-less internal transfer and interest payout classified correctly.');


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
  assert.equal(mobile.operations[0].amountKopecks, -123456);
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



async function checkStatuslessCardReadyImmediately() {
  const vm = require('node:vm');
  const run = async (cardText, cardRef, expectedKind) => {
    let clock = 0;
    const body = {innerText: cardText};
    const location = new URL(url([cardRef]));
    class FakeDate extends Date { static now() { return clock; } }
    const context = vm.createContext({
      URL, Date: FakeDate,
      setTimeout: fn => { clock += 250; fn(); },
      window: {}, location,
      document: {body, querySelectorAll: () => []}
    });
    const batch = JSON.parse(await vm.runInContext('(async function(mode) {' + source + '})("card")', context));
    assert.equal(batch.error, undefined);
    assert.equal(batch.operations.length, 1);
    assert.equal(batch.operations[0].kind, expectedKind);
    assert.equal(batch.operations[0].status, 'Не указан');
    assert.equal(clock, 0, 'Status-less card must be accepted on the first readiness check, without polling timeout');
  };
  await run(savingsToPay, demoTransferRef, 'internal_transfer');
  await run(interestCard, demoInterestRef, 'interest_income');
  console.log('v16 readiness: both status-less card templates are accepted immediately, without waiting for a nonexistent status.');
}
checkStatuslessCardReadyImmediately().catch(error => { console.error(error); process.exitCode = 1; });

// WebKit mobile text layout: amount fragments, neighbouring list and detail sums.
for (const rendered of ['−\n1 234,56\n₽', '−1 234\n,56 ₽', '−\t1\u00a0234,56\t₽']) {
  const result = parse(url([ref]), purchase.replace('−1 234,56 ₽', rendered), '');
  assert.equal(result.amountKopecks, -123456);
}
const surrounding = parse(url([ref]), 'История\nДругая покупка −500 ₽\n' + purchase + '\nКомиссия\n−10 ₽', '');
assert.equal(surrounding.amountKopecks, -123456);
assert.equal(surrounding.description, 'Тестовый магазин');
assert.throws(() => parse(url([ref]), purchase.replace('−1 234,56 ₽', '−1 234,56 ₽\n−500 ₽'), ''), /найдено сумм: 2/);
assert.throws(() => parse(url([ref]), purchase.replace('−1 234,56 ₽', '1 234,56 ₽'), ''), /найдено сумм: 0/);
console.log('Mobile amount fragments, surrounding amounts, and ambiguous amount rejection passed.');

async function checkHistory() {
  const vm = require('node:vm');
  let screen = 'list', opened = 0, returned = 0, filtersClosed = 0;
  const location = new URL('https://bank.yandex.ru/my/transactions-history');
  const body = {get innerText() { return screen.startsWith('card') ? purchase.replace('−1 234,56 ₽', '−\n1 234,56\n₽') : 'История'; }};
  const control = (label, click, aria = '') => ({innerText: label, click,
    getAttribute: key => key === 'aria-label' ? aria : null, contains: () => false});
  const go = (index) => { screen = 'card' + index; opened++;
    location.href = url([{...ref, chainId: 'history-' + index,
      operationTimestamp: index === 0 ? new Date().toISOString() : new Date(Date.now() - 8 * 86400000).toISOString()}]); };
  const list = [control('Тестовый магазин −1 234,56 ₽', () => go(0)), control('Старый магазин −1 234,56 ₽', () => go(1))];
  const filter = control('', () => {screen = 'filters';}, 'Какие операции скрывать');
  const close = control('Выбрать', () => {screen = 'list'; filtersClosed++;});
  const hiddenClose = {...control('', () => {throw Error('Clicked hidden desktop close');}, 'Закрыть'), getClientRects: () => []};
  const account = control('Все карты и счета', () => {});
  const month = {...control('Октябрь', () => {}), getClientRects: () => [{}], closest: () => null};
  const switches = [{checked: false, getAttribute: () => 'false'}];
  const doc = {body,
    querySelector: selector => selector.includes('switch') && screen === 'filters' ? switches[0] : null,
    querySelectorAll: selector => {
      if (selector === '[role="dialog"],main') return [{innerText: 'Постоянный диалог оболочки'}, body];
      if (selector.includes('switch')) return screen === 'filters' ? switches : [];
      if (selector === 'button,[role="button"]') return screen === 'list' ? [filter, month, account, ...list] : screen === 'filters' ? [hiddenClose, close] : [];
      return [];
    }};
  const window = {history: {back() {returned++; screen = 'filters'; location.href = 'https://bank.yandex.ru/my/transactions-history';}}};
  const context = vm.createContext({URL, Date, setTimeout: fn => {fn();}, window, location, document: doc});
  const batch = JSON.parse(await vm.runInContext('(async function(mode, lookbackDays) {' + source + '})("history", 7)', context));
  assert.equal(batch.error, undefined);
  assert.equal(batch.operations.length, 1);
  assert.equal(batch.operations[0].amountKopecks, -123456);
  assert.equal(batch.stopReason, 'lookback_reached');
  assert.equal(batch.lookbackDays, 7);
  assert.equal(opened, 2);
  assert.equal(returned, 2);
  assert.equal(filtersClosed, 3);
  assert.equal(screen, 'list');
  console.log('History integration: persistent dialog, icon filter, mobile cards, back navigation, and date cutoff passed.');
}
checkHistory().catch(error => {console.error(error); process.exitCode = 1;});


async function checkFullHistoryNoCutoff() {
  const vm = require('node:vm');
  let screen = 'list', opened = 0, returned = 0, filtersClosed = 0, clock = 0, picker = false, selectedMonth = 'Октябрь';
  const location = new URL('https://bank.yandex.ru/my/transactions-history');
  const body = {get innerText() { return screen.startsWith('card') ? purchase : (selectedMonth === 'Сентябрь' ? 'История\nНет более ранних операций' : 'История'); }};
  const root = {scrollTop: 0, scrollHeight: 500, clientHeight: 500, isConnected: true, dispatchEvent() {}};
  const control = (label, click, aria = '') => ({innerText: label, click, parentElement: root,
    getClientRects: () => [{}], getAttribute: key => key === 'aria-label' ? aria : null, contains: () => false,
    closest: () => null, querySelector: () => null, getBoundingClientRect: () => ({left: 0, right: 0, top: 0, width: 1, height: 1})});
  const go = (which) => { screen = 'card-' + which; opened++;
    const stamp = which === 'oct' ? '2026-10-04T00:11:31Z' : '2026-09-15T00:11:31Z';
    location.href = url([{...ref, chainId: 'full-history-' + which, operationTimestamp: stamp}]); };
  const octList = [control('Октябрьская операция −1 234,56 ₽', () => go('oct'))];
  const sepList = [control('Сентябрьская операция −1 234,56 ₽', () => go('sep'))];
  const filter = control('', () => {screen = 'filters';}, 'Какие операции скрывать');
  const close = control('Выбрать', () => {screen = 'list'; filtersClosed++;});
  const account = control('Все карты и счета', () => {});
  const monthButton = () => control(selectedMonth, () => {picker = true;});
  const sepChoice = control('Сентябрь', () => {selectedMonth = 'Сентябрь'; picker = false; root.scrollTop = 0;});
  const octChoice = control('Октябрь', () => {selectedMonth = 'Октябрь'; picker = false; root.scrollTop = 0;});
  const switches = [{checked: false, getAttribute: () => 'false', getClientRects: () => [{}], closest: () => null}];
  const actionables = () => {
    if (screen === 'filters') return [close];
    if (screen !== 'list') return [];
    const base = [filter, monthButton(), account, ...(selectedMonth === 'Октябрь' ? octList : sepList)];
    if (!picker) return base;
    return selectedMonth === 'Октябрь' ? [...base, sepChoice, octChoice] : [...base, sepChoice, octChoice];
  };
  const doc = {body, scrollingElement: root, documentElement: root,
    querySelectorAll(selector) {
      if (selector === '[role="dialog"],main') return [{innerText: 'Оболочка'}, body];
      if (selector.includes('switch')) return screen === 'filters' ? switches : [];
      if (selector === 'button,[role="button"]' || selector.includes('[role="option"]')) return actionables();
      return [];
    }};
  const window = {history: {back() {returned++; screen = 'filters'; location.href = 'https://bank.yandex.ru/my/transactions-history';}}};
  class FakeDate extends Date { static now() { return clock; } }
  const context = vm.createContext({URL, Date: FakeDate, setTimeout: fn => {clock += 250; fn();}, window, location, document: doc,
    getComputedStyle: () => ({overflowY: 'auto'}), Event: class {}});
  const batch = JSON.parse(await vm.runInContext('(async function(mode, lookbackDays) {' + source + '})("history", null)', context));
  assert.equal(batch.error, undefined);
  assert.equal(batch.operations.length, 2);
  assert.equal(batch.lookbackDays, null);
  assert.equal(batch.stopReason, 'full_history_exhausted');
  assert.equal(opened, 2);
  assert.equal(returned, 2);
  assert.ok(filtersClosed >= 3);
  assert.equal(selectedMonth, 'Октябрь');
  console.log('Full first sync: October -> September, explicit history beginning, and period restore passed.');
}
checkFullHistoryNoCutoff().catch(error => {console.error(error); process.exitCode = 1;});

async function checkSevenDayCrossMonth() {
  const vm = require('node:vm');
  let screen = 'list', clock = Date.parse('2026-10-04T12:00:00Z'), picker = false, selectedMonth = 'Октябрь';
  const location = new URL('https://bank.yandex.ru/my/transactions-history');
  const body = {get innerText() { return screen.startsWith('card') ? purchase : 'История'; }};
  const root = {scrollTop: 0, scrollHeight: 500, clientHeight: 500, isConnected: true, dispatchEvent() {}};
  const control = (label, click, aria = '') => ({innerText: label, click, parentElement: root,
    getClientRects: () => [{}], getAttribute: key => key === 'aria-label' ? aria : null, contains: () => false,
    closest: () => null, querySelector: () => null, getBoundingClientRect: () => ({left: 0, right: 0, top: 0, width: 1, height: 1})});
  const go = (key, stamp) => { screen = 'card-' + key; location.href = url([{...ref, chainId: key, operationTimestamp: stamp}]); };
  const octList = [control('Октябрь −1 234,56 ₽', () => go('oct', '2026-10-04T08:00:00Z'))];
  const sepList = [
    control('Сентябрь свежий −1 234,56 ₽', () => go('sep-new', '2026-09-29T08:00:00Z')),
    control('Сентябрь старый −1 234,56 ₽', () => go('sep-old', '2026-09-20T08:00:00Z'))
  ];
  const filter = control('', () => {screen = 'filters';}, 'Какие операции скрывать');
  const close = control('Выбрать', () => {screen = 'list';});
  const account = control('Все карты и счета', () => {});
  const monthButton = () => control(selectedMonth, () => {picker = true;});
  const sepChoice = control('Сентябрь', () => {selectedMonth = 'Сентябрь'; picker = false; root.scrollTop = 0;});
  const octChoice = control('Октябрь', () => {selectedMonth = 'Октябрь'; picker = false; root.scrollTop = 0;});
  const switches = [{checked: false, getAttribute: () => 'false', getClientRects: () => [{}], closest: () => null}];
  const actionables = () => {
    if (screen === 'filters') return [close];
    if (screen !== 'list') return [];
    const base = [filter, monthButton(), account, ...(selectedMonth === 'Октябрь' ? octList : sepList)];
    return picker ? [...base, sepChoice, octChoice] : base;
  };
  const doc = {body, scrollingElement: root, documentElement: root,
    querySelectorAll(selector) {
      if (selector === '[role="dialog"],main') return [{innerText: 'Оболочка'}, body];
      if (selector.includes('switch')) return screen === 'filters' ? switches : [];
      if (selector === 'button,[role="button"]' || selector.includes('[role="option"]')) return actionables();
      return [];
    }};
  const window = {history: {back() {screen = 'filters'; location.href = 'https://bank.yandex.ru/my/transactions-history';}}};
  class FakeDate extends Date { static now() { return clock; } }
  const context = vm.createContext({URL, Date: FakeDate, setTimeout: fn => {clock += 250; fn();}, window, location, document: doc,
    getComputedStyle: () => ({overflowY: 'auto'}), Event: class {}});
  const batch = JSON.parse(await vm.runInContext('(async function(mode, lookbackDays) {' + source + '})("history", 7)', context));
  assert.equal(batch.error, undefined);
  assert.equal(batch.stopReason, 'lookback_reached');
  assert.equal(batch.operations.length, 2);
  assert.equal(selectedMonth, 'Октябрь');
  assert.ok(batch.operations.some(x => x.identity.includes('sep-new')));
  assert.ok(!batch.operations.some(x => x.identity.includes('sep-old')));
  console.log('7-day refresh crosses October -> September and stops at the 7-day cutoff.');
}
checkSevenDayCrossMonth().catch(error => {console.error(error); process.exitCode = 1;});

// A fixed-size virtual list must be detected by contents, not only row count.
const signature = new Function(source.split('\nconst found = new Map();')[0] + '\nreturn rowSignature;')();
assert.notEqual(signature([{innerText: 'A −10 ₽'}, {innerText: 'B −20 ₽'}]), signature([{innerText: 'B −20 ₽'}, {innerText: 'C −30 ₽'}]));
const scrollSource = source.split('\nconst found = new Map();')[0] + '\nreturn scrollHistory;';
let scrollEvents = 0;
const scrollParent = {scrollHeight: 2000, clientHeight: 500, scrollTop: 0, dispatchEvent: () => scrollEvents++};
const scroller = new Function('document', 'window', 'getComputedStyle', 'Event', scrollSource)(
  {body: {}}, {scrollBy: () => {throw Error('Wrong scroll container');}}, () => ({overflowY: 'auto'}), class {});
scroller([{parentElement: scrollParent}]);
assert.equal(scrollParent.scrollTop, 400);
assert.equal(scrollEvents, 1);
console.log('Mobile apply-button cleanup, virtual-list changes and nested scrolling checks passed.');

async function checkDelayedPagination() {
  const helpers = source.split('\nconst found = new Map();')[0];
  async function simulate({count = 34, neverLoads = false, cancelAt = Infinity} = {}) {
    let clock = 0, loading = false;
    const row = (name) => ({innerText: name + ' −10 ₽', contains: () => false});
    const first = Array.from({length: 33}, (_, i) => row('Old ' + i));
    const loaded = Array.from({length: count}, (_, i) => row((count === 33 ? 'New ' : 'Old ') + i));
    const window = {};
    const root = {scrollTop: 0, scrollHeight: 500, clientHeight: 500,
      dispatchEvent() { loading = true; }, isConnected: true};
    first.forEach(el => {el.parentElement = root;});
    const document = {body: {innerText: 'История'}, scrollingElement: root,
      querySelectorAll(selector) {
        const pending = loading && (neverLoads || clock < 12000);
        if (selector === 'button,[role="button"]') return pending ? [] : loading ? loaded : first;
        if (selector.includes('aria-busy')) return pending ? [{}] : [];
        return [];
      }};
    const advance = (fn, ms) => {clock += ms; if (clock >= cancelAt) window.__financeCancelled = true; fn();};
    const next = new Function('document', 'window', 'Date', 'setTimeout', 'location', 'getComputedStyle', 'Event', helpers + '\nreturn nextHistoryWindow;')(
      document, window, {now: () => clock}, advance,
      new URL('https://bank.yandex.ru/my/transactions-history'), () => ({overflowY: 'auto'}), class {});
    const result = await next(first);
    assert.ok(clock >= 12000, 'Must wait through 12 seconds of empty loading placeholders');
    assert.equal(result.changed, true);
    assert.equal(result.list.length, count);
  }
  await simulate();
  await simulate({count: 33});
  await assert.rejects(simulate({neverLoads: true}), /45 секунд/);
  await assert.rejects(simulate({cancelAt: 2000}), /отменено/);
  console.log('Delayed pagination: 33→empty→34, fixed-size replacement, timeout and cancellation passed.');
}
checkDelayedPagination().catch(error => {console.error(error); process.exitCode = 1;});

async function checkPermanentFooterLoader() {
  const operation = {innerText: 'Тестовый магазин −20 ₽', contains: () => false};
  let loaderQueries = 0;
  const document = {body: {innerText: 'История'}, querySelectorAll(selector) {
    if (selector === 'button,[role="button"]') return [operation];
    loaderQueries++;
    return [{getClientRects: () => [{}]}];
  }};
  const wait = new Function('document', 'window', 'location', source.split('\nconst found = new Map();')[0] + '\nreturn waitForHistoryRows;')(
    document, {}, new URL('https://bank.yandex.ru/my/transactions-history'));
  const list = await wait();
  assert.equal(list.length, 1);
  assert.equal(loaderQueries, 0, 'Footer loading widgets must not decide whether existing operations are readable');
  console.log('Regression: loaded operations remain readable with a persistent footer loader.');
}
checkPermanentFooterLoader().catch(error => {console.error(error); process.exitCode = 1;});

async function checkMobilePeriodSheetRequiresApply() {
  const vm = require('node:vm');
  const helpers = source.split('\nconst found = new Map();')[0];
  let clock = 0, picker = false, periodSheet = false, selectedMonth = 'Октябрь', pendingMonth = null, applied = 0;
  const root = {scrollTop: 0, scrollHeight: 500, clientHeight: 500, isConnected: true, dispatchEvent() {}};
  const control = (label, click) => ({innerText: label, click, parentElement: root,
    getClientRects: () => [{}], getAttribute: () => null, contains: () => false,
    closest: () => null, querySelector: () => null, getBoundingClientRect: () => ({left: 0, right: 0, top: 0, width: 1, height: 1})});
  const octRow = control('Октябрьская операция −100 ₽', () => {});
  const sepRow = control('Сентябрьская операция −200 ₽', () => {});
  const monthButton = () => control(selectedMonth, () => {picker = true; periodSheet = true;});
  const sepChoice = control('Сентябрь', () => {pendingMonth = 'Сентябрь'; picker = false;});
  const octChoice = control('Октябрь', () => {pendingMonth = 'Октябрь'; picker = false;});
  const choose = control('Выбрать', () => {
    if (pendingMonth) selectedMonth = pendingMonth;
    pendingMonth = null; periodSheet = false; picker = false; applied++;
  });
  const actionables = () => {
    const base = [monthButton(), selectedMonth === 'Октябрь' ? octRow : sepRow];
    if (picker) return [...base, sepChoice, octChoice];
    if (periodSheet) return [...base, choose];
    return base;
  };
  const document = {body: {innerText: 'История'}, scrollingElement: root, documentElement: root,
    querySelectorAll(selector) {
      if (selector === 'button,[role="button"]' || selector.includes('[role="option"]')) return actionables();
      if (selector.includes('switch')) return [];
      return [];
    }};
  const window = {};
  const fn = new Function('document','window','Date','setTimeout','location','getComputedStyle','Event',
    helpers + '\nreturn selectPreviousHistoryMonth;')(
      document, window, {now: () => clock}, (cb, ms) => {clock += ms; cb();},
      new URL('https://bank.yandex.ru/my/transactions-history'), () => ({overflowY: 'auto'}), class {});
  const before = JSON.stringify([octRow.innerText]);
  const result = await fn({month: 9, year: 2026}, before);
  assert.equal(result.status, 'moved');
  assert.equal(result.cursor.month, 8);
  assert.equal(selectedMonth, 'Сентябрь');
  assert.equal(applied, 1, 'Mobile date-range sheet must be confirmed with «Выбрать»');
  console.log('Mobile period sheet: previous month is applied with the bottom «Выбрать» button.');
}
checkMobilePeriodSheetRequiresApply().catch(error => {console.error(error); process.exitCode = 1;});

// v34.4: collector classification must not poison the separate Swift engine.
const incoming343 = (title, details) => [title,'2 октября, 12:00','+100 ₽','Подробнее',...details,'Статус','Выполнено'].join('\n');
const incomingURL343 = url([{...ref,chainId:'audit-incoming',operationTimestamp:'2026-10-02T06:00:00Z'}]);
const debt343 = parse(incomingURL343,incoming343('Перевод от друга',['Перевод','Назначение','Отдал проценты по долгу']),'');
assert.equal(debt343.kind,'transfer');
assert.notEqual(debt343.category,'Проценты');
const own343 = parse(incomingURL343,incoming343('Сейв → Карта Пэй',['Перевод','Со счёта','Сейв','Куда','Карта Пэй','Назначение','Выплата процентов']),'');
assert.equal(own343.kind,'internal_transfer');
const cash343 = parse(incomingURL343,incoming343('Кэшбэк 5 процентов',[]),'');
assert.equal(cash343.kind,'unclassified_income');
assert.notEqual(cash343.category,'Проценты');
const interest343 = parse(incomingURL343,incoming343('Начисление процентов',[]),'');
assert.equal(interest343.kind,'interest_income');
const month343 = new Function(source.split('\nconst found = new Map();')[0]+'\nreturn parseMonthLabel;')();
for(const merchant of ['Мартини бар','Мартовский магазин','Январьский','Кафе Март','Март магазин']) assert.equal(month343(merchant),null,merchant);
for(const label of ['Март','Март 2026','Период: Март, 2026','Выбран Март · 2026']) assert.equal(month343(label).month,2,label);
assert.equal(parse(incomingURL343,incoming343('Нулевая операция',[]).replace('+100 ₽','−0 ₽'),'').amountKopecks,0);
console.log('v34.4: transfer/own transfer/cashback interest collisions, month-name boundaries and zero amount passed.');
