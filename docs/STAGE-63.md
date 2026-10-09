# Этап 63 — аудит виджета, тесты защиты ПИН-кода и проверка готовых тестов чеков (ТЗ ведущего Claude для GPT)

Блок 4 «Виджеты» закрыт (`main` = 46.38). Начат блок «Доработки»: 46.39 — защита ПИН-кода и остаток виджета, 46.40 — сверка чека с банком и предупреждение о дубле, 46.41 — ремонт чтения чеков, 46.42 — чтение даты/времени и точечная печать (по ответу Gemini).

Ветка `stage-63` **от `origin/stage-48`**. Код приложения не меняй — только отчёт (вне репозитория) и тесты. Сборку в GitHub — только если менял тесты; **IPA не скачивай**.

**Формат отчёта:** «Главное» — не больше десяти строк, с числами; что исправить первым. Находки: файл:строка, P1/P2/P3, как исправить, как проверить.

## Файлы Claude (не править)
`AppLock.swift`, `SecurityViews.swift`, `Models.swift`, `FinanceEngine.swift`, `ReportEngine.swift`, `Budgets.swift`, `ReceiptParser.swift`, `ReceiptViews.swift`, `ReceiptRecognizer.swift`, `WidgetSummary.swift`, `HorizonWidget/`, `YandexFinanceApp.swift`, `scripts/`, `.github/`.

## Задача 1 — аудит виджета (только чтение)
`git diff 8e7b8bd..origin/stage-48` (46.34–46.38 и две правки без сборки после 46.38). Что искать:
1. **Что уходит из приложения.** `WidgetSummary` / `WidgetShared.summary`: при выключенном «Суммы в виджете» в файл не должно попасть ни одной суммы, статуса, бюджета, названия группы; нет ли пути, где остаётся старый файл с суммами после выключения (запись не удалась, нет группы, приложение закрыто до записи).
2. **Выбор группы** (`groupCandidates`, `profileGroups`, `resolvedGroup`): можно ли выбрать чужую группу; что будет при двух командах в профиле; при профиле без групп; при повреждённом профиле.
3. **Когда пишется сводка** (`scheduleWidgetUpdate`, `publishWidget`, `willResignActiveNotification`, `onReceive(browser.$history)`): гонки при сбросе хранилища (`resetLocalStorage`), восстановлении копии, открытии с ещё не прочитанной историей (`loadingHistory`), заблокированном приложении (ПИН). Не запишется ли пустая/нулевая сводка вместо настоящей.
4. **Числа = главный экран.** Запас (`monthReserve` + `reserveAccounts`), «Сегодня» (`historyInterval(.lastDays(1))`), «Месяц» (`HistoryPeriod.currentMonth`), бюджет (`budgetStatuses(...).first { $0.group == nil }`), группы (`ReportEngine.slices`, `.expenses`, `.categories`) — совпадают ли с тем, что показывают главный экран и «Отчёты → Структура» за тот же период; граница суток и месяца, часовой пояс.
5. **Виджет** (`HorizonWidget.swift`): устаревшая сводка другого дня/месяца — прочерки, а не старые числа; переполнение `Int64` в `wholeRubles`, делении бюджета; пустой лимит.
6. **Проценты (46.36):** `FinancialEngine.classify` — «Выплата процентов» с меткой `refund` теперь доход. Нет ли настоящего возврата, который теперь станет доходом (слово «проценты» в описании магазина, категория «Проценты» у возврата).

## Задача 2 — тесты защиты ПИН-кода (только тесты, не из `main()`)
Сейчас (`AppLock.swift`) любая ошибка Keychain читается как «кода нет»: `PinKeychain.load()` возвращает nil, и `init` открывает приложение без кода, а `check` отвечает `.accepted`. Например, запуск iOS заранее (prewarm) до первой разблокировки телефона после перезагрузки. В 46.39 Claude вынесет решение в чистую функцию `AppLockLogic` (в `Models.swift`), контракт:

```
enum PinStoreRead: Equatable { case found, notFound, unavailable, damaged }
struct LockStart: Equatable { let hasPIN: Bool; let locked: Bool; let needsRetry: Bool; let needsReset: Bool }
AppLockLogic.start(store: PinStoreRead, pinWasSet: Bool) -> LockStart
AppLockLogic.checkWithoutRecord(store: PinStoreRead, pinWasSet: Bool) -> Bool   // true — код принят
```
Правила:
- `found` → код есть, закрыто;
- `notFound` и `pinWasSet == false` → кода нет, открыто;
- `notFound` и `pinWasSet == true` (запись пропала, а флаг в UserDefaults остался) → закрыто, `needsReset` (сброс только кодом телефона);
- `unavailable` (любая ошибка Keychain, кроме «нет записи») → закрыто при любом `pinWasSet`, `needsRetry` (повторить чтение при возвращении в приложение);
- `damaged` (запись есть, но не читается) → закрыто, `needsReset`;
- `checkWithoutRecord` — `true` только при `notFound && !pinWasSet`; во всех остальных случаях код не принят.

Напиши `testKnownLockStart63()` со всеми сочетаниями (4 × 2), печатай expected/actual. Пока функции нет — тест в отдельном файле или под `#if`, чтобы сборка не падала; Claude подключит.

## Задача 3 — готовые тесты чеков (только проверка, отчёт)
В ветках `origin/stage-55` и `origin/stage-58` лежат твои тесты: известные ошибки чтения чеков (этап 55, DeepSeek 1–7) и сверка чека с банком (`testKnownReceiptMatch58()`). Проверь, что они компилируются на текущем `origin/stage-48` (`.local\check.ps1` в своей копии), и дай таблицу: тест — что ждёт — что сейчас — какой части блока касается (46.40 сверка / 46.41 ремонт). Ничего не исправляй в коде приложения.

Данные вымышленные (`privacy.test.js`).
