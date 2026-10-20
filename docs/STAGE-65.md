# Этап 65 — аудит сборок 47.1–47.3 и тесты нового кода (ТЗ ведущего Claude для GPT)

Ветка `stage-65` **от `origin/stage-48`** (`3082d38` или новее). Код приложения не меняй — только отчёт (вне репозитория) и тесты в `Tests/`. Сборку в GitHub — только если менял тесты; **IPA не скачивай**. Приложение остаётся личным (Яндекс Банк владельца), в магазин не идёт.

**Формат:** «Главное» — не больше десяти строк, с числами. Находки: файл:строка, P1/P2/P3, как исправить, как проверить. Данные вымышленные (`privacy.test.js`).

## Файлы Claude (не править)
`BankBrowser.swift`, `Vault.swift`, `FinanceEngine.swift`, `ReportEngine.swift`, `Budgets.swift`, `FinancePresentationCache.swift`, `ReceiptParser.swift`, `ReceiptRecognizer.swift`, `Models.swift`, `Collector.js`, `.github/`, `scripts/`.

## Задача 1 — аудит нового (только чтение, `git diff v1.0..origin/stage-48`)
1. **Период «с 1 числа»** (`PeriodSelectionLogic.swift`: `HistoryPeriod.monthToDate`, `showing`; `OperationsHomeView.swift`: лист «Период», `revealSavedOperation`): граница месяца и года, переход на новый день с открытым экраном, часовой пояс, старые сохранённые `custom:…` периоды, виджет и сводка главного экрана (`YandexFinanceApp.swift` использует `currentMonth`).
2. **«Перевод от …» — доход** (`FinanceEngine.isTransferFromPerson`, порядок веток в `classify`): названия, которые начинаются с «перевод от», но не от человека (свой банк, возврат от магазина, «Перевод от Сейва»); выбор владельца (`confirmedNature`) должен быть главнее; вопрос «Что это за поступление?» (`YandexFinanceApp.swift`, `Models.swift: confirmNature`).
3. **Подписки и кредиты** (`FinanceEngine.commitmentDues`, `monthForecast(subscriptions:loans:)`, `Models.swift: Loan.balance/keptBalance`, `CommitmentsView.swift`): 31-е число и февраль, годовая подписка, `since`, остаток кредита (платёж в день ввода остатка, последний платёж, уход в ноль), защита от двойного счёта (±3 дня, ±5 % / ±15 %), ключ ответа `commit|…`, ответы «пришло / не будет / перенести»; напоминания (`CommitmentReminders`): идентификаторы, сброс при каждом изменении, не стираются ли напоминания, пока история ещё грузится.
4. **Кредитные карты** (`CreditCards`, `Account.creditLimitKopecks`, форма счёта в `AccountsView.swift`): смена лимита при том же долге (`resave`), перевод счёта в карту и обратно, сумма «Все счета» и группы, сверка с банком (`AccountDetailView.swift`) у карты.
5. **Правка и удаление операций банка** (`OperationEdit`, `SavedHistory.applyOperationEdits/editBankOperation/deleteBankOperation`, вызовы в `BankBrowser.apply` и `StatementImporter.merging`): правка переживает новое чтение и новую выписку; смена знака (`kind`), потеря `components`; удалённая операция не возвращается при удалении архива и повторном импорте выписки; чеки, названия, категории, подтверждения, привязанные к `identity`, у удалённой; сортировка после правки даты; `FinancePresentationCache.prepare` видит правку.
6. **«Куда уходят деньги»** (`ReportEngine.spendingLeaders`, `SpendingLeadersView.swift`): сравнение с теми же днями (`monthComparisonPeriods`) на 29–31 числе, на 1-м числе, при месяце в будущем; доли (сумма долей ≤ 100); «Это не подписка» (`notSubscriptionKeys`).

## Задача 2 — свои тесты (в `Tests/`, ожидаемое из постановки, не из вывода `main()`)
- `commitmentDues`: февраль 2032 и 2033, год на стыке декабря и января, кредит с остатком (платёж ровно равен остатку; остаток нулевой), `since` в день платежа.
- `applyOperationEdits`: двойное применение даёт тот же результат; правка → новое чтение с другой суммой банка → правка поверх новой; удаление + правка одной и той же операции.
- `spendingLeaders`: неполный месяц против месяца с меньшим числом дней (31 марта → февраль), сумма долей, три группы с одинаковой суммой (порядок стабилен).
Если тест красный из-за кода приложения, напиши expected/actual, не правь код.

## Задача 3 — аудит 46.44–1.0 (из блока 8 плана)
`git diff 46.43..v1.0` (если тега 46.43 нет, от `6392eb1`): заставка (`SecurityViews.swift: SplashView`, `LockScreenView(canAskFaceID:)`), одна копия всех данных (`ReceiptArchive.swift: FullBackup`, `Models`, `DataAndCopiesView.swift`, `YandexFinanceApp.swift: exportFullBackup/restore`), прогноз в фоне (`OperationsHomeView.computeForecast`, `FinancePresentationCache`), чек и покупка «в обработке» (`ReceiptBankMatch.match`). Для копии: что, если фото чеков восстановлены раньше истории, что при повреждённом архиве, что при старом JSON.
