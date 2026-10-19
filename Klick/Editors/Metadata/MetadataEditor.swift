import AppKit
import SwiftUI

/// "Metadata": inspect camera, date and location info, copy it, or save a
/// cleaned copy (everything, or only the location) next to the original.
enum MetadataEditor {
    @MainActor static func present(for item: FileItem) {
        let metadata = ImageMetadata(item: item)
        EditorWindowController.present(width: 360) { close in
            MetadataEditorView(item: item, metadata: metadata, close: close)
        }
    }
}

struct MetadataEditorView: View {
    let item: FileItem
    let metadata: ImageMetadata
    let close: () -> Void

    @State private var thumbnail: CGImage?
    @State private var onlyLocation = false
    @State private var isRemoving = false
    @State private var errorMessage: String?
    @State private var fades = EdgeFades()

    /// Whether the metadata list continues above / below the visible area.
    private struct EdgeFades: Equatable {
        var top = false
        var bottom = false
    }

    var body: some View {
        EditorShell(title: "Metadata", onClose: close) {
            VStack(spacing: 14) {
                header

                ScrollView {
                    VStack(spacing: 14) {
                        MetadataSectionView(section: metadata.general)
                        ForEach(metadata.details) { section in
                            MetadataSectionView(section: section) {
                                if section.kind == .location, let url = metadata.coordinate?.mapsURL {
                                    OpenInMapsButton(url: url)
                                }
                            }
                        }
                        if metadata.details.isEmpty {
                            emptyState
                        }
                    }
                }
                .scrollIndicators(.never)
                .scrollEdgeEffectHidden()
                .scrollBounceBehavior(.basedOnSize)
                .onScrollGeometryChange(for: EdgeFades.self) { geometry in
                    // A few points of slack: the card's appear animation nudges the offset.
                    EdgeFades(
                        top: geometry.visibleRect.minY > 4,
                        bottom: geometry.visibleRect.maxY < geometry.contentSize.height - 4
                    )
                } action: { _, newValue in
                    withAnimation(.easeOut(duration: 0.15)) { fades = newValue }
                }
                .frame(maxHeight: 380)
                .fixedSize(horizontal: false, vertical: true)
                .mask { fadeMask }

                if metadata.coordinate != nil {
                    locationToggle
                }
            }
        } footer: {
            KlickSecondaryButton(title: "Copy All", action: copyAll)

            ZStack {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)

            KlickPrimaryButton(title: onlyLocation ? "Remove Location" : "Remove Metadata", isBusy: isRemoving, action: remove)
        }
        .task { await loadThumbnail() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(metadata.summary)
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// Soft edges hint that the list scrolls (scroll indicators are hidden).
    private var fadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: fades.top ? 18 : 0)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: fades.bottom ? 28 : 0)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text("No camera or location data")
                .font(.system(size: 13, weight: .semibold))
            Text("This image only carries its basic properties.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .metadataGroupBackground()
    }

    private var locationToggle: some View {
        HStack(spacing: 10) {
            Image(systemName: "location.slash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(onlyLocation ? Theme.accent : .secondary)
                .frame(width: 16)
            Text("Only remove location")
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            Toggle("Only remove location", isOn: $onlyLocation.animation(Theme.springSnappy))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.accent)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .metadataGroupBackground()
        .onChange(of: onlyLocation) { Feedback.shared.tick() }
    }

    // MARK: Actions

    private func loadThumbnail() async {
        let url = item.url
        let image = await Task.detached(priority: .userInitiated) {
            try? ImageIOKit.loadImage(url, maxPixelSize: 144)
        }.value
        withAnimation(.easeOut(duration: 0.2)) { thumbnail = image }
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(metadata.text(fileName: item.name), forType: .string)
        Feedback.shared.success()
        Toast.shared.showMessage("Copied", symbol: "doc.on.doc.fill")
    }

    private func remove() {
        guard !isRemoving else { return }
        isRemoving = true
        errorMessage = nil
        let url = item.url
        let onlyLocation = onlyLocation
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { onlyLocation ? try MetadataRemover.removeLocation(from: url) : try MetadataRemover.removeAll(from: url) }
            }.value
            isRemoving = false
            switch result {
            case .success:
                Feedback.shared.success()
                close()
                Toast.shared.showMessage(onlyLocation ? "Location removed" : "Metadata removed")
            case .failure(let error):
                Feedback.shared.failure()
                withAnimation(.easeOut(duration: 0.2)) { errorMessage = error.localizedDescription }
            }
        }
    }
}

// MARK: - Sections

/// "CAMERA" caption above a rounded group of label / value rows.
private struct MetadataSectionView<Accessory: View>: View {
    let section: ImageMetadata.Section
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: section.kind.symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(section.kind.title)
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                accessory
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.07))
                            .frame(height: 1)
                            .padding(.leading, 12)
                    }
                    MetadataRowView(row: row)
                }
            }
            .metadataGroupBackground()
        }
    }
}

extension MetadataSectionView where Accessory == EmptyView {
    init(section: ImageMetadata.Section) {
        self.init(section: section) { EmptyView() }
    }
}

private struct MetadataRowView: View {
    let row: ImageMetadata.Row

    var body: some View {
        HStack(spacing: 16) {
            Text(row.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize()
            Spacer(minLength: 0)
            Text(row.value)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(row.value)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }
}

/// Small accent link that opens the photo's coordinates in Maps.
private struct OpenInMapsButton: View {
    let url: URL
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 3) {
                Text("Open in Maps")
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .opacity(hovering ? 0.75 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private extension View {
    /// System Settings–style rounded group.
    func metadataGroupBackground() -> some View {
        background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
