import SwiftUI
import UIKit

/// «Настройки → Данные и копии»: the copies of the history and of the receipt photos, and the imports. The exporters
/// and importers themselves stay in Settings (they need its state); this screen only starts them and shows what came of it.
/// The text of the last receipt the phone read, kept in memory only: it can be copied from the settings to see how a bad
/// reading went wrong.
@MainActor
enum ReceiptDebug {
    static var lastText = ""
}

@MainActor
struct DataAndCopiesView: View {
    @ObservedObject var browser: BankBrowser
    let exportBackup: () -> Void
    let exportReceipts: () -> Void
    let restoreBackup: () -> Void
    let restoreReceipts: () -> Void
    let importStatements: () -> Void
    let importCategories: () -> Void
    @State private var notice: String?
    /// The moment of the last tap here: only a message that follows a tap is shown, not the ones of the background sync.
    @State private var tappedAt: Date?

    var body: some View {
        let photos = ReceiptStore.allFiles.count
        List {
            Section {
                Button("Сохранить копию (JSON)") { run(exportBackup) }
                    .disabled(!browser.storageAvailable || browser.busy)
                Button("Восстановить из копии (JSON)") { run(restoreBackup) }
                    .disabled(browser.busy)
            } header: {
                Text("Резервная копия")
            } footer: {
                Text("Операции, счета, категории и правила. Фото чеков в неё не входят.")
            }.glassRows()
            Section {
                LabeledContent("Фото на телефоне", value: String(photos))
                Button("Сохранить архив (ZIP)") { run(exportReceipts) }
                    .disabled(photos == 0 || browser.busy)
                Button("Восстановить фото из архива") { run(restoreReceipts) }
                    .disabled(browser.busy)
            } header: {
                Text("Фото чеков")
            } footer: {
                Text(photos == 0 ? "Фото ещё нет: их добавляют в операции, в разделе «Чек»."
                                 : "ZIP сохраняйте рядом с JSON: iCloud Drive → Finance Test.")
            }.glassRows()
            Section {
                Button("Скопировать текст последнего чека") { UIPasteboard.general.string = ReceiptDebug.lastText }
                    .disabled(ReceiptDebug.lastText.isEmpty)
            } header: {
                Text("Диагностика")
            } footer: {
                Text("Текст, который телефон прочитал с последнего сфотографированного чека (до закрытия приложения). Нужен, чтобы разобраться, если чек прочитался плохо.")
            }.glassRows()
            Section {
                Button("Импортировать PDF-выписки") { run(importStatements) }
                    .disabled(!browser.storageAvailable || browser.busy)
                Button("Импортировать разметку категорий") { run(importCategories) }
                    .disabled(!browser.storageAvailable || browser.busy)
            } header: {
                Text("Импорт")
            } footer: {
                Text("Выписки — один или несколько PDF. Разметка категорий — JSON, его можно просмотреть перед применением.")
            }.glassRows()
        }
        .appSurface()
        .navigationTitle("Данные и копии")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: browser.message) { _, text in
            guard !text.isEmpty, let tappedAt, Date().timeIntervalSince(tappedAt) < 180 else { return }
            notice = text
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) { notice = nil }
        }
    }

    private func run(_ action: () -> Void) {
        tappedAt = Date()
        browser.message = ""
        action()
    }
}
