import SwiftUI

/// Format-Tafel „Aa“ – ersetzt wie bei Apple die Tastatur.
struct FormatPanel: View {
    let controller: EditorController

    var body: some View {
        let s = controller.state
        VStack(spacing: 14) {
            HStack {
                Text("Format").font(.headline)
                Spacer()
                Button { controller.toggleFormatPanel() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(Text("Schließen"))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    style(String(localized: "Titel"), .title, font: .system(size: 20, weight: .bold))
                    style(String(localized: "Überschrift"), .heading, font: .system(size: 17, weight: .bold))
                    style(String(localized: "Unterüberschrift"), .subheading, font: .system(size: 15, weight: .semibold))
                    style(String(localized: "Text"), .body, font: .system(size: 15))
                    style(String(localized: "Dicktengleich"), .mono, font: .system(size: 14, design: .monospaced))
                }
                .padding(.horizontal, 2)
            }
            HStack(spacing: 10) {
                group {
                    toggle("bold", s.bold, String(localized: "Fett")) { controller.toggleInline(.hnBold) }
                    toggle("italic", s.italic, String(localized: "Kursiv")) { controller.toggleInline(.hnItalic) }
                    toggle("underline", s.underline, String(localized: "Unterstrichen")) { controller.toggleInline(.hnUnderline) }
                    toggle("strikethrough", s.strike, String(localized: "Durchgestrichen")) { controller.toggleInline(.hnStrike) }
                }
                group {
                    toggle("link", false, String(localized: "Link hinzufügen")) { controller.beginLinkEdit() }
                }
            }
            HStack(spacing: 10) {
                group {
                    toggle("list.bullet", s.kind == .bullet, String(localized: "Aufzählung")) { controller.setBlock(.bullet) }
                    toggle("list.dash", s.kind == .dash, String(localized: "Spiegelstrich")) { controller.setBlock(.dash) }
                    toggle("list.number", s.kind == .number, String(localized: "Nummeriert")) { controller.setBlock(.number) }
                    toggle("text.quote", s.kind == .quote, String(localized: "Zitatblock")) { controller.setBlock(.quote) }
                }
                group {
                    toggle("decrease.indent", false, String(localized: "Ausrücken")) { controller.indent(-1) }
                    toggle("increase.indent", false, String(localized: "Einrücken")) { controller.indent(1) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .tint(Color.accentColor)
    }

    private func style(_ title: String, _ kind: BlockKind, font: Font) -> some View {
        let on = controller.state.kind == kind
        return Button { controller.setBlock(kind) } label: {
            Text(title).font(font).lineLimit(1)
                .padding(.horizontal, 14).frame(height: 40)
                .foregroundStyle(on ? Color.black : Color.primary)
                .background(on ? Color.accentColor : Color(.secondarySystemFill), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 0) { c() }
            .background(Color(.secondarySystemFill), in: .rect(cornerRadius: 10))
            .clipShape(.rect(cornerRadius: 10))
    }

    private func toggle(_ symbol: String, _ on: Bool, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 42)
                .foregroundStyle(on ? Color.black : Color.primary)
                .background(on ? Color.accentColor : .clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Leiste über der Tastatur (Aa, Checkliste, Tabelle, Anhang, Schreibtools, Tastatur aus) im Liquid-Glass-Stil.
struct AccessoryBar: View {
    let controller: EditorController
    var onAttach: (AttachSource) -> Void = { AttachRouter.shared.request($0) }

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 4) {
                bar("textformat", String(localized: "Format")) { controller.toggleFormatPanel() }
                bar("checklist", String(localized: "Checkliste")) { controller.setBlock(.check) }
                bar("tablecells", String(localized: "Tabelle")) { controller.insertTable() }
                AttachMenu { onAttach($0) } label: {
                    Image(systemName: "paperclip").font(.system(size: 18)).frame(width: 44, height: 40)
                }
                if controller.canShowWritingTools {
                    bar("apple.writing.tools", String(localized: "Schreibtools")) { controller.showWritingTools() }
                }
                Spacer(minLength: 0)
                bar("keyboard.chevron.compact.down", String(localized: "Tastatur ausblenden")) { controller.dismissKeyboard() }
            }
            .padding(.horizontal, 8)
            .frame(height: 46)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .tint(.primary)
    }

    private func bar(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 44, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

enum AttachSource { case photos, camera, file }

/// Menü der Büroklammer.
struct AttachMenu<L: View>: View {
    let pick: (AttachSource) -> Void
    @ViewBuilder var label: () -> L
    var body: some View {
        Menu {
            Button { pick(.photos) } label: { Label("Foto oder Video auswählen", systemImage: "photo.on.rectangle") }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { pick(.camera) } label: { Label("Foto oder Video aufnehmen", systemImage: "camera") }
            }
            Button { pick(.file) } label: { Label("Datei anhängen", systemImage: "doc") }
        } label: { label() }
        .accessibilityLabel(Text("Anhang"))
    }
}

/// Die Leiste über der Tastatur lebt außerhalb der SwiftUI-Ansicht – Anhang-Wünsche gehen über diese Weiche.
@MainActor @Observable
final class AttachRouter {
    static let shared = AttachRouter()
    var pending: AttachSource?
    func request(_ s: AttachSource) { pending = s }
}
