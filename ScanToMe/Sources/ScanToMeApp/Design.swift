import AppKit
import SwiftUI

// Gemeinsame Gestaltung: ruhige Karten, klare Abstände, Symbole mit Text (Bedeutung nie nur über Farbe).

extension View {
    /// Weiße (im Dunkelmodus dunkle) Karte mit zartem Rand und Schatten.
    func card(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}

/// Eine Schalterzeile: Symbol, Titel, Erklärung darunter, Schalter rechts.
struct OptionRow: View {
    let systemImage: String
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!enabled)
        }
        .opacity(enabled ? 1 : 0.7)
    }
}

/// Kürzel des Dokumenttyps als Plakette.
struct TypeBadge: View {
    let code: String

    var body: some View {
        Text(code)
            .font(.caption.monospaced().bold())
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .overlay(Capsule().stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
    }
}

/// Seitenvorschau mit Papierwirkung.
struct PageThumbnail: View {
    let image: NSImage?
    let width: CGFloat
    var dimmed = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.white)
            if let image { Image(nsImage: image).resizable().scaledToFit() }
        }
        .frame(width: width, height: width * 1.414)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        .opacity(dimmed ? 0.35 : 1)
    }
}

/// Dateiname in Schreibmaschinenschrift auf hellem Grund, markierbar.
struct FileNameText: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.body.monospaced())
            .textSelection(.enabled)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
    }
}

/// Abschnitt in Einstellungen und Assistent mit Symbol in der Überschrift.
struct IconSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.top, 4)
        }
    }
}
