import SwiftUI
import UIKit

/// «Настройки → Данные и копии»: the copies of the history and of the receipt photos, and the imports. The exporters
/// and importers themselves stay in Settings (they need its state); this screen only starts them and shows what came of it.
@MainActor
struct DataAndCopiesView: View {
    @ObservedObject var browser: BankBrowser
    let exportBackup: () -> Void
    let exportReceipts: () -> Void
    let collectReceipts: () -> Void
    let restoreBackup: () -> Void
    let restoreReceipts: () -> Void
    let importStatements: () -> Void
    let importCategories: () -> Void
    @State private var notice: String?
    /// The moment of the last tap here: only a message that follows a tap is shown, not the ones of the background sync.
    @State private var tappedAt: Date?
    @State private var photos: Int?
    @State private var photoError: String?

    var body: some View {
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
                LabeledContent("Фото на телефоне", value: photos.map { String($0) } ?? (photoError == nil ? "Проверяем…" : "Ошибка чтения"))
                if photoError != nil { Button("Повторить чтение списка фото") { refreshPhotos() } }
                Button("Сохранить архив (ZIP)") { run(exportReceipts) }
                    .disabled(photos == nil || photos == 0 || browser.busy)
                Button("Восстановить фото из архива") { run(restoreReceipts) }
                    .disabled(browser.busy)
            } header: {
                Text("Фото чеков")
            } footer: {
                if let photoError {
                    Text(photoError).foregroundStyle(.primary)
                } else {
                    Text(photos == 0 ? "Фото ещё нет: их добавляют в операции, в разделе «Чек»."
                                     : "ZIP сохраняйте рядом с JSON: iCloud Drive → Finance Test.")
                }
            }.glassRows()
            Section {
                Button("Собрать чеки для проверки") { run(collectReceipts) }
                    .disabled(photos == nil || photos == 0 || browser.busy)
            } header: {
                Text("Улучшение чтения чеков")
            } footer: {
                Text("Один файл (ZIP) с фото чеков, текстом, который прочитал телефон, и тем, что сохранено в операциях. В файле только чеки, которых ещё не было в прошлых сборах. Пришлите его и напишите «проверь диагностику чека»: по нему чтение станет точнее.")
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
        .onAppear { refreshPhotos() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refreshPhotos() }
        .onChange(of: browser.message) { _, text in
            refreshPhotos()
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

    private func refreshPhotos() {
        do {
            photos = try ReceiptStore.photoFiles().count
            photoError = nil
        } catch {
            photos = nil
            photoError = "Не удалось прочитать список фото чеков. Разблокируйте телефон и попробуйте ещё раз."
        }
    }
}
