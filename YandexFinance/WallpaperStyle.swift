import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO

struct BuiltinWallpaper: Identifiable {
    let id: String
    let name: String
    let colors: [Color]
    var assetName: String? = nil
    var pattern: Int? = nil

    static let all: [BuiltinWallpaper] = [
        .init(id: "night", name: "Ночь", colors: [.black, Color(red: 0.08, green: 0.10, blue: 0.19)]),
        .init(id: "aurora", name: "Сияние", colors: [.indigo, .teal, Color(red: 0.05, green: 0.12, blue: 0.20)]),
        .init(id: "ocean", name: "Океан", colors: [.cyan, .blue, .indigo]),
        .init(id: "sunset", name: "Закат", colors: [.orange, .pink, .purple]),
        .init(id: "rose", name: "Розовый кварц", colors: [.pink, Color(red: 0.45, green: 0.22, blue: 0.42), .indigo]),
        .init(id: "forest", name: "Лес", colors: [.mint, .teal, Color(red: 0.03, green: 0.18, blue: 0.13)]),
        .init(id: "violet", name: "Лаванда", colors: [.purple, .indigo, .blue]),
        .init(id: "silver", name: "Графит", colors: [.gray, Color(red: 0.17, green: 0.20, blue: 0.26), .black]),
        .init(id: "photo-mist", name: "Горы в тумане", colors: [], assetName: "Wallpaper-mist"),
        .init(id: "photo-sea", name: "Тихое море", colors: [], assetName: "Wallpaper-sea"),
        .init(id: "photo-dunes", name: "Дюны", colors: [], assetName: "Wallpaper-dunes"),
        .init(id: "photo-forest", name: "Туманный лес", colors: [], assetName: "Wallpaper-forest"),
        .init(id: "silk", name: "Шёлк", colors: [.black, Color(red: 0.24, green: 0.18, blue: 0.30)], pattern: 0),
        .init(id: "orbits", name: "Орбиты", colors: [Color(red: 0.03, green: 0.12, blue: 0.18), .black], pattern: 1),
        .init(id: "paper", name: "Бумажные волны", colors: [Color(red: 0.22, green: 0.20, blue: 0.17), .black], pattern: 2),
        .init(id: "prism", name: "Призма", colors: [Color(red: 0.10, green: 0.12, blue: 0.22), .black], pattern: 3)
    ]
}

@MainActor
final class WallpaperStore: ObservableObject {
    @Published var selection: String {
        didSet { UserDefaults.standard.set(selection, forKey: "wallpaperSelection") }
    }
    @Published private(set) var customImage: UIImage?

    private static var imageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Appearance", isDirectory: true).appendingPathComponent("wallpaper.jpg")
    }

    init() {
        selection = UserDefaults.standard.string(forKey: "wallpaperSelection") ?? "night"
        customImage = UIImage(contentsOfFile: Self.imageURL.path)
        if selection == "custom" && customImage == nil { selection = "night" }
    }

    func importImage(_ data: Data) async throws {
        let jpeg = try await Task.detached(priority: .userInitiated) {
            try Self.downsample(data)
        }.value
        try Task.checkCancellation()
        let url = Self.imageURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: url, options: .atomic)
        customImage = UIImage(data: jpeg)
        selection = "custom"
    }

    // Decode at wallpaper size, never keep a full-resolution camera image in memory.
    nonisolated private static func downsample(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output as Data
    }
}

struct WallpaperBackground: View {
    @EnvironmentObject private var wallpaper: WallpaperStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            Group {
                if wallpaper.selection == "custom", let image = wallpaper.customImage {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    let preset = BuiltinWallpaper.all.first { $0.id == wallpaper.selection } ?? BuiltinWallpaper.all[0]
                    BuiltinWallpaperImage(preset: preset)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .overlay(Color.black.opacity(colorScheme == .dark ? 0.28 : 0.08))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct GlassRowBackground: View {
    var body: some View { Rectangle().fill(.thinMaterial) }
}

/// Resolution-independent artwork shared by the preview and the full-screen background.
struct BuiltinWallpaperImage: View {
    let preset: BuiltinWallpaper
    var body: some View {
        if let asset = preset.assetName { Image(asset).resizable().scaledToFill() }
        else {
            LinearGradient(colors: preset.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay {
                    if let pattern = preset.pattern {
                        Canvas { context, size in
                            let w = size.width, h = size.height
                            for i in 0..<6 {
                                let t = CGFloat(i) / 6
                                var path = Path()
                                switch pattern {
                                case 1:
                                    path.addEllipse(in: CGRect(x: w * (0.12 - t * 0.25), y: h * (0.2 - t * 0.12),
                                                              width: w * (0.8 + t), height: h * (0.55 + t)))
                                case 3:
                                    path.move(to: CGPoint(x: w * (t - 0.4), y: 0))
                                    path.addLine(to: CGPoint(x: w * (t + 0.25), y: h))
                                    path.addLine(to: CGPoint(x: w * (t + 0.55), y: h))
                                    path.addLine(to: CGPoint(x: w * (t - 0.1), y: 0))
                                    path.closeSubpath()
                                default:
                                    path.move(to: CGPoint(x: -w * 0.2, y: h * (0.2 + t)))
                                    path.addCurve(to: CGPoint(x: w * 1.2, y: h * (0.35 + t)),
                                                  control1: CGPoint(x: w * 0.4, y: -h * 0.2),
                                                  control2: CGPoint(x: w * 0.5, y: h * 1.2))
                                    path.addLine(to: CGPoint(x: w * 1.2, y: h * (0.5 + t)))
                                    path.addCurve(to: CGPoint(x: -w * 0.2, y: h * (0.35 + t)),
                                                  control1: CGPoint(x: w * 0.5, y: h * 1.3),
                                                  control2: CGPoint(x: w * 0.4, y: -h * 0.1))
                                    path.closeSubpath()
                                }
                                let color: Color = pattern == 1 ? .cyan : (pattern == 2 ? .orange : .purple)
                                if pattern == 1 {
                                    context.stroke(path, with: .color(color.opacity(0.12)), lineWidth: max(1, w * 0.004))
                                } else {
                                    context.fill(path, with: .linearGradient(
                                        Gradient(colors: [.white.opacity(0.09), color.opacity(0.16), .clear]),
                                        startPoint: .zero, endPoint: CGPoint(x: w, y: h)))
                                }
                            }
                        }.allowsHitTesting(false)
                    }
                }
        }
    }
}

struct AppSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .containerBackground(Color.clear, for: .navigation)
            // Pages stay transparent over the stationary wallpaper owned by ContentView.
            // A presented sheet owns one background beneath its navigation transitions.
            .presentationBackground { WallpaperBackground() }
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

extension View {
    func appSurface() -> some View { modifier(AppSurfaceModifier()) }
}

struct WallpaperSettingsView: View {
    @EnvironmentObject private var wallpaper: WallpaperStore
    @State private var photo: PhotosPickerItem?
    @State private var importFile = false
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Встроенные обои").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(BuiltinWallpaper.all) { preset in
                        Button { wallpaper.selection = preset.id } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                GeometryReader { geometry in
                                    Group {
                                        BuiltinWallpaperImage(preset: preset)
                                    }
                                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                                }
                                    .frame(height: 125)
                                    .overlay(alignment: .topTrailing) {
                                        if wallpaper.selection == preset.id {
                                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white)
                                                .shadow(radius: 2).padding(10)
                                        }
                                    }
                                    .clipShape(.rect(cornerRadius: 18))
                                Text(preset.name).font(.subheadline).foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(wallpaper.selection == preset.id ? [.isSelected] : [])
                    }
                }
                .disabled(loading)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Свои обои").font(.headline)
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Выбрать из Фото", systemImage: "photo")
                    }
                    .disabled(loading)
                    Button("Выбрать из Файлов", systemImage: "folder") { importFile = true }
                        .disabled(loading)
                    if let image = wallpaper.customImage {
                        Button { wallpaper.selection = "custom" } label: {
                            GeometryReader { geometry in
                                Image(uiImage: image).resizable().scaledToFill()
                                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                            }
                                .frame(height: 150)
                                .overlay(alignment: .topTrailing) {
                                    if wallpaper.selection == "custom" {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white).shadow(radius: 2).padding(10)
                                    }
                                }
                                .clipShape(.rect(cornerRadius: 18))
                        }.buttonStyle(.plain).disabled(loading).accessibilityLabel("Использовать своё изображение")
                    }
                    if loading { ProgressView("Подготовка изображения…") }
                    Text("Фон сохраняется на этом устройстве. Можно вернуться к любому встроенному варианту.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(18)
                .background(.thinMaterial, in: .rect(cornerRadius: 22))
            }
            .padding(20)
        }
        .appSurface()
        .navigationTitle("Обои")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: photo) {
            guard let photo else { return }
            loading = true
            defer { loading = false }
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                try await wallpaper.importImage(data)
            } catch is CancellationError { }
            catch { errorMessage = "Не удалось открыть изображение. Попробуйте выбрать другое." }
        }
        .fileImporter(isPresented: $importFile, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                Task {
                    loading = true
                    defer { loading = false }
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
                        try await wallpaper.importImage(data)
                    } catch { errorMessage = "Не удалось открыть изображение. Попробуйте выбрать другое." }
                }
            case .failure: errorMessage = "Не удалось открыть файл изображения."
            }
        }
        .alert("Обои", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}
