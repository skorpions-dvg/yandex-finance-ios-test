import SwiftUI
import PhotosUI
import VisionKit
import PDFKit
import UniformTypeIdentifiers

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

/// The plain camera: one ordinary photo, for the cases when the scanner cannot find the edges of the receipt.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage, onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void
        let onFinish: () -> Void

        init(onImage: @escaping (UIImage) -> Void, onFinish: @escaping () -> Void) {
            self.onImage = onImage
            self.onFinish = onFinish
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onImage(image) }
            onFinish()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish() }
    }
}

/// What the «Чек» section shows full screen: the scanner, the camera or one saved photo.
private enum ReceiptScreen: Identifiable {
    case scanner
    case camera
    case photo(String)

    var id: String {
        switch self {
        case .scanner: return "scanner"
        case .camera: return "camera"
        case .photo(let name): return "photo-" + name
        }
    }
}

/// «Чек» in an operation: a row «Добавить чек» with a menu of ways (scan, camera, gallery, document) and the photos
/// under it. For an operation that does not exist yet (a new manual one) `pending` holds the photos until it is saved.
@MainActor
struct ReceiptSection: View {
    @ObservedObject var browser: BankBrowser
    let identity: String
    /// Photos of an operation that is not saved yet; nil for an operation that exists.
    var pending: Binding<[String]>? = nil
    @State private var screen: ReceiptScreen?
    @State private var showGallery = false
    @State private var showFiles = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var failed = false

    private var files: [String] { pending?.wrappedValue ?? browser.history.receiptFiles(forIdentity: identity) }

    var body: some View {
        let files = self.files
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // Only the dots are the menu: it opens from them at the right edge, and the title is not part of the
                // animation (when the whole row was the menu, its label was cut off while the menu closed).
                HStack {
                    Label("Добавить чек", systemImage: "doc.badge.plus")
                    Spacer()
                    Menu {
                        if VNDocumentCameraViewController.isSupported {
                            Button { screen = .scanner } label: { Label("Сканировать", systemImage: "doc.viewfinder") }
                        }
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button { screen = .camera } label: { Label("Камера", systemImage: "camera") }
                        }
                        Button { showGallery = true } label: { Label("Из галереи", systemImage: "photo.on.rectangle") }
                        Button { showFiles = true } label: { Label("Документ", systemImage: "doc") }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 32)
                            .contentShape(Rectangle())
                    }
                }
                if !files.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(files, id: \.self) { name in
                                Button { screen = .photo(name) } label: { thumbnail(name) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .fullScreenCover(item: $screen) { screen in
                switch screen {
                case .scanner:
                    DocumentScanner(onScan: { add($0) }, onFinish: { self.screen = nil }).ignoresSafeArea()
                case .camera:
                    CameraPicker(onImage: { add([$0]) }, onFinish: { self.screen = nil }).ignoresSafeArea()
                case .photo(let name):
                    ReceiptViewer(name: name, onDelete: { remove(name) })
                }
            }
            .photosPicker(isPresented: $showGallery, selection: $picked, maxSelectionCount: 5, matching: .images)
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image, .pdf], allowsMultipleSelection: true) { result in
                importDocuments(result)
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
            if let pending {
                pending.wrappedValue.append(name)
                added += 1
            } else if browser.updateUserData({ $0.addReceipt(name, toIdentity: identity) }) {
                added += 1
            } else {
                ReceiptStore.delete([name])
            }
        }
        if added == 0 && !images.isEmpty { failed = true }
    }

    private func remove(_ name: String) {
        if let pending {
            pending.wrappedValue.removeAll { $0 == name }
            ReceiptStore.delete([name])
        } else if browser.updateUserData({ $0.removeReceipt(name, fromIdentity: identity) }) {
            ReceiptStore.delete([name])
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { images.append(image) }
        }
        picked = []
        if images.isEmpty { failed = true } else { add(images) }
    }

    /// Pictures from «Файлы» as they are; a PDF becomes pictures of its first pages.
    private func importDocuments(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { failed = true; return }
        var images: [UIImage] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if url.pathExtension.lowercased() == "pdf" {
                images += Self.pages(ofPDFAt: url)
            } else if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                images.append(image)
            }
        }
        if images.isEmpty { failed = true } else { add(images) }
    }

    private static func pages(ofPDFAt url: URL) -> [UIImage] {
        guard let document = PDFDocument(url: url) else { return [] }
        var images: [UIImage] = []
        for index in 0..<min(document.pageCount, ReceiptLogic.maxPagesPerDocument) {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let factor = ReceiptLogic.maxSide / Double(max(bounds.width, bounds.height))
            let size = CGSize(width: bounds.width * factor, height: bounds.height * factor)
            images.append(page.thumbnail(of: size, for: .mediaBox))
        }
        return images
    }
}

/// One receipt on the whole screen: pinch to zoom, drag when zoomed, double tap to reset, a button to delete it.
@MainActor
private struct ReceiptViewer: View {
    let name: String
    let onDelete: () -> Void
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
                    onDelete()
                    dismiss()
                }
                Button("Отмена", role: .cancel) { }
            }
        }
    }
}
