import AppKit
import SwiftUI

/// Background color or image, layout, and transparency, with a preview of the main display.
struct AppearanceSettingsView: View {
    let model: AppModel
    let localizer: Localizer
    let chooseImage: @MainActor () async -> URL?

    @State private var transparencyText = ""
    @State private var transparencyRejected = false
    @State private var importError: ImageImportError?
    @State private var isImporting = false
    @FocusState private var transparencyFieldFocused: Bool

    private var appearance: AppearanceSettings { model.preferences.appearance }

    var body: some View {
        Form {
            Section {
                Picker(selection: binding(\.source)) {
                    Text(verbatim: localizer.string(.appearanceSourceColor)).tag(BackgroundSource.color)
                    Text(verbatim: localizer.string(.appearanceSourceImage)).tag(BackgroundSource.image)
                } label: {
                    Text(verbatim: localizer.string(.appearanceBackground))
                }
                .pickerStyle(.segmented)

                ColorPicker(selection: colorBinding, supportsOpacity: false) {
                    Text(verbatim: localizer.string(.appearanceColor))
                    Text(verbatim: localizer.string(.appearanceColorHelp))
                }

                if appearance.source == .image {
                    imageRow
                    layoutPicker
                }
            }

            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Slider(value: transparencySliderBinding, in: 0...99) {
                            Text(verbatim: localizer.string(.appearanceTransparency))
                        }
                        .labelsHidden()
                        .accessibilityValue(Text(verbatim: "\(localizer.number(appearance.transparency))%"))
                        TextField(text: $transparencyText) {
                            Text(verbatim: localizer.string(.appearanceTransparency))
                        }
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 44)
                        .focused($transparencyFieldFocused)
                        .onSubmit(commitTransparencyText)
                        Text(verbatim: "%")
                            .accessibilityHidden(true)
                    }
                } label: {
                    Text(verbatim: localizer.string(.appearanceTransparency))
                    Text(verbatim: localizer.string(.appearanceTransparencyHelp))
                }
                if transparencyRejected {
                    errorText(localizer.string(.validationTransparency))
                }
            }

            Section {
                BackgroundPreview(model: model, appearance: appearance, localizer: localizer)
                    .frame(maxWidth: .infinity)
            } header: {
                Text(verbatim: localizer.string(.appearancePreview))
            }
        }
        .formStyle(.grouped)
        .onAppear { transparencyText = String(appearance.transparency) }
        .onChange(of: appearance.transparency) { _, value in transparencyText = String(value) }
        .onChange(of: transparencyFieldFocused) { _, focused in
            if !focused { commitTransparencyText() }
        }
    }

    // MARK: Image

    @ViewBuilder private var imageRow: some View {
        LabeledContent {
            Button {
                Task { await importImage() }
            } label: {
                Text(verbatim: localizer.string(isImporting ? .appearanceImporting : .appearanceChooseImage))
            }
            .disabled(isImporting)
        } label: {
            Text(verbatim: localizer.string(.appearanceSourceImage))
            if let image = appearance.image {
                Text(verbatim: localizer.format(
                    .appearanceImageSize,
                    localizer.number(image.pixelWidth),
                    localizer.number(image.pixelHeight)
                ))
            } else {
                Text(verbatim: localizer.string(.appearanceNoImage))
            }
        }
        if let image = appearance.image, !model.imageStore.fileExists(for: image) {
            errorText(localizer.string(.appearanceImageUnavailable))
        }
        if let importError {
            errorText(localizer.message(for: importError))
        }
    }

    @ViewBuilder private var layoutPicker: some View {
        Picker(selection: binding(\.layout)) {
            Text(verbatim: localizer.string(.layoutStretch)).tag(ImageLayout.stretch)
            Text(verbatim: localizer.string(.layoutCenter)).tag(ImageLayout.center)
            Text(verbatim: localizer.string(.layoutScaleToFit)).tag(ImageLayout.scaleToFit)
        } label: {
            Text(verbatim: localizer.string(.appearanceLayout))
            Text(verbatim: localizer.string(layoutHelp))
        }
    }

    private var layoutHelp: L10n {
        switch appearance.layout {
        case .stretch: .layoutStretchHelp
        case .center: .layoutCenterHelp
        case .scaleToFit: .layoutScaleToFitHelp
        }
    }

    private func importImage() async {
        guard let url = await chooseImage() else { return }
        isImporting = true
        importError = await model.importBackgroundImage(from: url)
        isImporting = false
    }

    // MARK: Bindings

    private func update(_ change: (inout AppearanceSettings) -> Void) {
        var candidate = model.preferences
        change(&candidate.appearance)
        model.apply(candidate)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppearanceSettings, Value>) -> Binding<Value> {
        Binding {
            appearance[keyPath: keyPath]
        } set: { value in
            update { $0[keyPath: keyPath] = value }
        }
    }

    private var colorBinding: Binding<Color> {
        Binding {
            Color(rgb: appearance.color)
        } set: { color in
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            update {
                $0.color = RGBColor(
                    red: Double(srgb.redComponent).clamped(to: 0...1),
                    green: Double(srgb.greenComponent).clamped(to: 0...1),
                    blue: Double(srgb.blueComponent).clamped(to: 0...1)
                )
            }
        }
    }

    private var transparencySliderBinding: Binding<Double> {
        Binding {
            Double(appearance.transparency)
        } set: { value in
            transparencyRejected = false
            update { $0.transparency = Int(value.rounded()).clamped(to: AppearanceSettings.transparencyRange) }
        }
    }

    /// Accepts only whole numbers 0–99; anything else keeps the current value and shows an error.
    private func commitTransparencyText() {
        if let value = AppearanceSettings.parseTransparency(transparencyText) {
            transparencyRejected = false
            update { $0.transparency = value }
            transparencyText = String(value)
        } else {
            transparencyRejected = true
            transparencyText = String(appearance.transparency)
        }
    }

    private func errorText(_ message: String) -> some View {
        Label {
            Text(verbatim: message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.red)
    }
}

/// A scaled rendering of the main display's background with a stand-in break panel.
private struct BackgroundPreview: View {
    let model: AppModel
    let appearance: AppearanceSettings
    let localizer: Localizer

    @State private var rendered: RenderedBackground?

    private static let width: CGFloat = 360

    var body: some View {
        let screen = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
        let scale = Self.width / screen.width
        let previewSize = CGSize(width: Self.width, height: (screen.height * scale).rounded())

        ZStack(alignment: .topLeading) {
            // A patterned stand-in for the desktop makes transparency visible.
            LinearGradient(colors: [.orange, .pink, .purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
            BackgroundCanvas(appearance: appearance, rendered: rendered, containerSize: screen)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: previewSize.width, height: previewSize.height, alignment: .topLeading)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: previewSize.width * 0.36, height: previewSize.height * 0.32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: previewSize.width, height: previewSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: localizer.string(.appearancePreviewAccessibility)))
        .task(id: request(screen: screen, scale: scale)) {
            guard let request = request(screen: screen, scale: scale) else {
                rendered = nil
                model.previewRenderer.removeAll()
                return
            }
            model.previewRenderer.retainOnly([request])
            rendered = await model.previewRenderer.image(for: request)
        }
    }

    /// A small downsampled decode covering the whole image, sized for the preview.
    private func request(screen: CGSize, scale: CGFloat) -> BackgroundRenderRequest? {
        guard let image = appearance.activeImage, model.imageStore.fileExists(for: image) else { return nil }
        let placed = ImageLayoutCalculator.imageRect(layout: appearance.layout, imageSize: image.logicalSize, in: screen)
        let longSide = max(image.logicalSize.width, image.logicalSize.height)
        let needed = max(placed.width, placed.height) * scale * 2
        let maxPixelSize = Int(min(longSide, max(needed, 64)).rounded(.up))
        return BackgroundRenderRequest(image: image, variant: .downsampled(maxPixelSize: maxPixelSize))
    }
}
