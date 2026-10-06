# Этап 40 — ручные доходы, расходы и переводы (ТЗ для GPT)

Ветка: `stage-40`. Прочитай сначала `AGENTS.md`. Основа (модель и расчёты) уже сделана ведущим и покрыта тестами — **её не меняй**, только используй.

## Что уже есть (не трогать)
- `Models.swift`:
  - `SavedHistory.manualOperations: [ManualOperation]?`;
  - `SavedHistory.allOperations: [BankOperation]` — банковские + ручные операции вместе;
  - `struct ManualOperation { id, kind (.expense/.income/.transfer), amountKopecks (всегда > 0), date, accountID, toAccountID, group, subcategory, note }`, у неё `bankOperation` (запись для отчётов);
  - `BankOperation.isManual`, `BankOperation.manualID`;
  - `Account.balance(bankOperations:manual:)` — правильный остаток счёта с учётом ручных операций.
- `FinanceEngine.swift`: `FinancialEngine.expenseGroupOrder`, `expenseSubcategoryOrder`, `incomeSubcategoryOrder`, `expenseCategory(for:)` (как подкатегории раскладываются по группам — см. функцию, там все пары группа/подкатегория).
- Сохранение — только `browser.updateUserData { history in … }` (`BankBrowser.swift`).

## 40.2 — подключить ручные операции везде (механическая замена)
Везде, где берутся операции для показа или расчёта, использовать `browser.history.allOperations` вместо `browser.history.operations`:
- `OperationsHomeView.swift` (доходы/расходы периода, история по дням, прогноз, запас);
- `ForecastDetailView.swift` (если считает сам);
- «Отчёты» в `YandexFinanceApp.swift` (`FinanceDashboardView`, `FinanceCategoryOperationsView`) — **кроме** мест про сканер/синхронизацию/журнал (там остаются банковские `operations`);
- `SearchOperationsView.swift`.
Остатки счетов: заменить вызовы `FinancialEngine.accountBalance(...)` в `AccountsView.swift` и `OperationsHomeView.swift` на `account.balance(bankOperations: browser.history.operations.map(\.financialInput), manual: browser.history.manualOperations ?? [])`.

## 40.3 — экран добавления операции (оранжевый «+»)
Новый файл `YandexFinance/ManualOperationFormView.swift`, открывается вместо заглушки `ComingSoonSheet(title: "Добавить", …)` на главном экране. Стиль Money Flow, как формы счетов (`AccountFormView`): sheet, `NavigationStack` + `Form`, слева `xmark`, справа оранжевая `checkmark` (неактивна, пока сумма 0 или не выбран счёт/категория).
- Сверху `Picker` в стиле `.segmented`: «Расход» / «Доход» / «Перевод».
- Сумма: крупное поле (`.title.weight(.semibold)`), `.keyboardType(.decimalPad)`, принимает «1 234,56»; хранить в копейках, > 0. Цвет: расход — основной, доход — зелёный.
- Расход: выбор категории — список групп `expenseGroupOrder` с раскрытием до подкатегорий (иконки и цвета групп как в `OperationRow.icon`: Еда fork.knife оранжевый, Транспорт car.fill синий, Покупки bag.fill фиолетовый, Обязательные house.fill бирюзовый, Другое square.grid.2x2.fill серый). Подкатегории для каждой группы — те, что даёт `expenseCategory` (Еда: Супермаркеты, Кафе и рестораны, Доставка еды; Транспорт: Такси, Общественный транспорт, Топливо, Авто; Покупки: Маркетплейсы, Одежда, Электроника, Дом и быт; Обязательные: ЖКХ, Связь и интернет, Подписки, Здоровье; Другое: Развлечения, Путешествия, Подарки, Доставка и курьеры, Переводы другим, Комиссии, Прочее).
- Доход: выбор подкатегории из `incomeSubcategoryOrder`.
- Счёт: `Picker` «Счёт» из `history.accounts` (иконка + название). Для расхода и дохода **не показывать** счёт с `tracksBankCard == true` (карту банка ведёт сканер) и под пикером подпись «Операции по карте Яндекс Банка загружаются из банка автоматически». Перевод: «Откуда» и «Куда» (разные счета; карту банка можно выбрать). Если счетов нет — вместо формы кнопка «Создать счёт» (открывает `AccountFormView`).
- Дата и время: `DatePicker`, по умолчанию сейчас, не позже сейчас.
- Комментарий: `TextField("Комментарий")` → `note`.
- Сохранение: добавить `ManualOperation` в `history.manualOperations` через `updateUserData`, закрыть экран.

## 40.4 — просмотр, правка и удаление
- В истории (главный экран) и поиске ручные операции выглядят как обычные строки `OperationRow`; в подписи вместо статуса «Вручную» (можно по `operation.isManual`).
- Нажатие на ручную операцию открывает ту же форму `ManualOperationFormView` в режиме правки (заголовок «Операция», кнопка «Удалить операцию» с подтверждением). Найти её по `operation.manualID` в `history.manualOperations`. Банковские операции по-прежнему открывают `OperationDetailView`.

## Проверка и выпуск
- `.local\check.ps1` должен быть зелёным (тесты ведущего проверяют модель — не ломай их).
- Версии: 40.2, 40.3 … (можно одной сборкой 40.2 на всё). README — раздел «Изменения».
- Сборка и IPA — по `AGENTS.md`. В `main` не сливать: после этапа позовите ведущего (Claude) на проверку.

## Что проверить на телефоне
1. «+» → расход 250 ₽ «Кафе и рестораны» со счёта «Наличные» → появился в истории, в «Отчётах» в Еда → Кафе, остаток «Наличных» уменьшился на 250.
2. Доход на «Наличные» — растёт остаток и доходы периода.
3. Перевод «Наличные → Яндекс банк» — остаток наличных уменьшился, карта не изменилась (её пополнение придёт из банка), в доходы/расходы не попал.
4. Правка суммы и удаление ручной операции.
5. Резервная копия — ручные операции в ней есть (экспорт → восстановление).
