import SwiftUI
import UIKit

/// «Настройки → Данные и копии»: the copies of the history and of the receipt photos, and the imports. The exporters
/// and importers themselves stay in Settings (they need its state); this screen only starts them and shows what came of it.
@MainActor
struct DataAndCopiesView: View {
    @ObservedObject var browser: BankBrowser
    let exportBackup: () -> Void
    let collectReceipts: () -> Void
    let restoreBackup: () -> Void
    let importStatements: () -> Void
    let importCategories: () -> Void
    @State private var notice: String?
    /// The moment of the last tap here: only a message that follows a tap is shown, not the ones of the background sync.
    @State private var tappedAt: Date?
    /// The names of the photo files, nil while they are being read or when reading failed.
    @State private var photoNames: [String]?
    @State private var photoError: String?
    @State private var confirmOrphans = false

    private var photos: Int? { photoNames?.count }
    /// Photos that no operation points to.
    private var orphans: [String] { photoNames.map { ReceiptLogic.orphanFiles(all: $0, referenced: browser.history.receipts) } ?? [] }

    var body: some View {
        List {
            Section {
                Button("Сохранить копию") { run(exportBackup) }
                    .disabled(!browser.storageAvailable || browser.busy)
                Button("Восстановить из копии") { run(restoreBackup) }
                    .disabled(browser.busy)
                LabeledContent("Фото чеков на телефоне", value: photos.map { String($0) } ?? (photoError == nil ? "Проверяем…" : "Ошибка чтения"))
                if photoError != nil { Button("Повторить чтение списка фото") { refreshPhotos() } }
                if !orphans.isEmpty {
                    LabeledContent("Привязано к операциям", value: String((photos ?? 0) - orphans.count))
                    Button("Удалить фото без операции (\(orphans.count))", role: .destructive) { confirmOrphans = true }
                }
            } header: {
                Text("Копия всех данных")
            } footer: {
                if let photoError {
                    Text(photoError).foregroundStyle(.primary)
                } else {
                    Text("Один файл: операции, счета, категории, правила и фото чеков. Сохраняйте его в iCloud Drive → Finance Test. Восстановление принимает и прежние копии — JSON и архив фото.")
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
                Text("Ещё")
            } footer: {
                Text("Выписки — один или несколько PDF. Разметка категорий — JSON, его можно просмотреть перед применением.")
            }.glassRows()
        }
        .confirmationDialog("Удалить фото без операции?", isPresented: $confirmOrphans, titleVisibility: .visible) {
            Button("Удалить \(orphans.count)", role: .destructive) {
                ReceiptStore.delete(orphans)
                refreshPhotos()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Эти фото не привязаны ни к одной операции. Операции и привязанные фото остаются.")
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
            photoNames = try ReceiptStore.photoFiles()
            photoError = nil
        } catch {
            photoNames = nil
            photoError = "Не удалось прочитать список фото чеков. Разблокируйте телефон и попробуйте ещё раз."
        }
    }
}
