import SwiftUI
import PhotosUI
import VisionKit

/// The document scanner of iOS: it cuts the receipt out of the background and straightens it.
struct DocumentScanner: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan, onFinish: onFinish) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onScan: ([UIImage]) -> Void
        let onFinish: () -> Void

        init(onScan: @escaping ([UIImage]) -> Void, onFinish: @escaping () -> Void) {
            self.onScan = onScan
            self.onFinish = onFinish
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onScan((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
            onFinish()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { onFinish() }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { onFinish() }
    }
}

private struct ReceiptPhoto: Identifiable {
    let name: String
    var id: String { name }
}

/// «Чек» in the card of an operation: photos of the receipt, a button to scan one and one to take it from the gallery.
@MainActor
struct ReceiptSection: View {
    @ObservedObject var browser: BankBrowser
    let identity: String
    @State private var showScanner = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var viewing: ReceiptPhoto?
    @State private var failed = false

    var body: some View {
        let files = browser.history.receiptFiles(forIdentity: identity)
        Section {
            VStack(alignment: .leading, spacing: 12) {
                if !files.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(files, id: \.self) { name in
                                Button { viewing = ReceiptPhoto(name: name) } label: { thumbnail(name) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                HStack(spacing: 20) {
                    if VNDocumentCameraViewController.isSupported {
                        Button { showScanner = true } label: { Label("Сканировать", systemImage: "doc.viewfinder") }
                            .buttonStyle(.borderless)
                    }
                    PhotosPicker(selection: $picked, maxSelectionCount: 5, matching: .images) {
                        Label("Из галереи", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 4)
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScanner(onScan: { images in add(images) }, onFinish: { showScanner = false })
                    .ignoresSafeArea()
            }
            .fullScreenCover(item: $viewing) { photo in
                ReceiptViewer(browser: browser, identity: identity, name: photo.name)
            }
            .onChange(of: picked) { _, items in
                guard !items.isEmpty else { return }
                Task { await load(items) }
            }
            .alert("Не удалось сохранить фото", isPresented: $failed) {
                Button("OK", role: .cancel) { }
            }
        } header: {
            Text("Чек")
        } footer: {
            Text("Фото хранятся только на этом телефоне и не входят в файл резервной копии.").font(.caption2)
        }
        .glassRows()
    }

    @ViewBuilder
    private func thumbnail(_ name: String) -> some View {
        if let image = ReceiptStore.image(named: name) {
            Image(uiImage: image.preparingThumbnail(of: CGSize(width: 180, height: 240)) ?? image)
                .resizable().scaledToFill()
                .frame(width: 72, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(.secondary)
                .frame(width: 72, height: 96)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func add(_ images: [UIImage]) {
        var added = 0
        for image in images {
            guard let name = ReceiptStore.save(image) else { continue }
            if browser.updateUserData({ $0.addReceipt(name, toIdentity: identity) }) { added += 1 } else { ReceiptStore.delete([name]) }
        }
        if added == 0 && !images.isEmpty { failed = true }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { images.append(image) }
        }
        picked = []
        if images.isEmpty { failed = true } else { add(images) }
    }
}

/// One receipt on the whole screen: pinch to zoom, drag when zoomed, double tap to reset, a button to delete it.
@MainActor
private struct ReceiptViewer: View {
    @ObservedObject var browser: BankBrowser
    let identity: String
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var lastOffset = CGSize.zero
    @State private var confirmDeletion = false

    var body: some View {
        NavigationStack {
            Group {
                if let image = ReceiptStore.image(named: name) {
                    Image(uiImage: image)
                        .resizable().scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { scale = min(5, max(1, lastScale * $0)) }
                                .onEnded { _ in lastScale = scale; if scale == 1 { offset = .zero; lastOffset = .zero } }
                        )
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { value in
                                    guard scale > 1 else { return }
                                    offset = CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height)
                                }
                                .onEnded { _ in lastOffset = offset }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }
                        }
                } else {
                    ContentUnavailableView("Файл недоступен", systemImage: "photo.badge.exclamationmark",
                                           description: Text("Фото остались на другом телефоне или были удалены. Ссылку можно убрать."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.9))
            .navigationTitle("Чек")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Удалить", systemImage: "trash", role: .destructive) { confirmDeletion = true } }
            }
            .confirmationDialog("Удалить фото чека?", isPresented: $confirmDeletion, titleVisibility: .visible) {
                Button("Удалить фото", role: .destructive) {
                    if browser.updateUserData({ $0.removeReceipt(name, fromIdentity: identity) }) {
                        ReceiptStore.delete([name])
                        dismiss()
                    }
                }
                Button("Отмена", role: .cancel) { }
            }
        }
    }
}
