import SwiftUI

/// Content of one display's break overlay. `OverlayController` fades it in and out.
struct BreakOverlayView: View {
    let model: OverlayModel
    let displayID: CGDirectDisplayID
    let localizer: Localizer
    let actions: OverlayActions

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                BackgroundCanvas(
                    appearance: model.appearance,
                    rendered: model.backgrounds[displayID],
                    containerSize: proxy.size
                )
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)

            if let session = model.session {
                BreakPanel(session: session, model: model, localizer: localizer, actions: actions)
                    .padding(40)
            }
        }
        .environment(\.locale, localizer.locale)
    }
}

/// The opaque, readable panel with the prompt, countdown, and commands.
private struct BreakPanel: View {
    let session: ActiveBreak
    let model: OverlayModel
    let localizer: Localizer
    let actions: OverlayActions

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: session.kind == .short ? "eye" : "figure.walk")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text(verbatim: localizer.string(session.kind == .short ? .overlayShortTitle : .overlayLongTitle))
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: localizer.string(session.kind == .short ? .overlayShortMessage : .overlayLongMessage))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            CountdownText(model: model, localizer: localizer)

            if !session.allowsSkip {
                Label {
                    Text(verbatim: localizer.string(.overlaySkipNotAllowed))
                } icon: {
                    Image(systemName: "lock")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { buttons }
                VStack(spacing: 10) { buttons }
            }
            .controlSize(.large)
        }
        .padding(36)
        .frame(maxWidth: 600)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var buttons: some View {
        let pauseHelp = localizer.string(.overlayPauseHelp)
        Button {
            actions.pause()
        } label: {
            Label { Text(verbatim: localizer.string(.overlayPause)) } icon: { Image(systemName: "pause.fill") }
                .frame(minWidth: 110)
        }
        .help(pauseHelp)
        .accessibilityHint(Text(verbatim: pauseHelp))

        if session.allowsSkip {
            let skipHelp = localizer.string(.overlaySkipHelp)
            Button {
                actions.skip(session.id)
            } label: {
                Label { Text(verbatim: localizer.string(.overlaySkip)) } icon: { Image(systemName: "forward.fill") }
                    .frame(minWidth: 110)
            }
            .help(skipHelp)
            .accessibilityHint(Text(verbatim: skipHelp))
        }

        let quitHelp = localizer.string(.overlayQuitHelp)
        Button {
            actions.quit()
        } label: {
            Label { Text(verbatim: localizer.string(.overlayQuit)) } icon: { Image(systemName: "xmark") }
                .frame(minWidth: 110)
        }
        .help(quitHelp)
        .accessibilityHint(Text(verbatim: quitHelp))
    }
}

/// Reads only the countdown value so that ticks redraw this text and nothing else.
private struct CountdownText: View {
    let model: OverlayModel
    let localizer: Localizer

    var body: some View {
        let seconds = model.remainingSeconds
        Text(verbatim: localizer.countdown(seconds: seconds))
            .font(.system(size: 72, weight: .medium, design: .rounded).monospacedDigit())
            .contentTransition(.identity)
            .accessibilityLabel(Text(verbatim: localizer.format(
                .overlayCountdownAccessibility,
                localizer.duration(seconds: seconds)
            )))
    }
}

/// The background color and optional image, with transparency applied once to the composition.
struct BackgroundCanvas: View {
    let appearance: AppearanceSettings
    let rendered: RenderedBackground?
    /// Layout size in points; previews pass the real display size and scale the result.
    let containerSize: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(rgb: appearance.color)
            if let image = appearance.activeImage, let rendered {
                let frame = Self.drawRect(
                    layout: appearance.layout,
                    imageSize: image.logicalSize,
                    region: rendered.region,
                    container: containerSize
                )
                Image(decorative: rendered.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: containerSize.width, height: containerSize.height, alignment: .topLeading)
        .clipped()
        .compositingGroup()
        .opacity(appearance.backgroundOpacity)
    }

    /// Where a bitmap covering `region` of the image is drawn, in container points.
    nonisolated static func drawRect(layout: ImageLayout, imageSize: CGSize, region: CGRect, container: CGSize) -> CGRect {
        let placed = ImageLayoutCalculator.imageRect(layout: layout, imageSize: imageSize, in: container)
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scaleX = placed.width / imageSize.width
        let scaleY = placed.height / imageSize.height
        return CGRect(
            x: placed.minX + region.minX * scaleX,
            y: placed.minY + region.minY * scaleY,
            width: region.width * scaleX,
            height: region.height * scaleY
        )
    }
}

extension Color {
    init(rgb: RGBColor) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }
}
