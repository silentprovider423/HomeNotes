import SwiftUI

/// Tabelle bearbeiten: Zellen, Zeilen/Spalten einfügen und löschen, in Text umwandeln, löschen.
/// Return/Tab springt in die nächste Zelle (wie in Apples Tabellen).
struct TableEditorSheet: View {
    let table: TableBox
    let done: (TableBox?, Bool) -> Void          // nil = Tabelle löschen; true = in Text umwandeln
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [[String]] = []
    @State private var alignments: [String] = []
    @FocusState private var focus: Cell?
    @State private var confirmDelete = false

    struct Cell: Hashable { var r: Int; var c: Int }

    private var columns: Int { rows.first?.count ?? 0 }

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        Color.clear.frame(width: 34, height: 34)
                        ForEach(0..<columns, id: \.self) { c in columnMenu(c) }
                    }
                    ForEach(rows.indices, id: \.self) { r in
                        GridRow {
                            rowMenu(r)
                            ForEach(0..<columns, id: \.self) { c in
                                TextField("", text: binding(r, c))
                                    .font(r == 0 ? .body.weight(.semibold) : .body)
                                    .focused($focus, equals: Cell(r: r, c: c))
                                    .submitLabel(.next)
                                    .onSubmit { next(r, c) }
                                    .padding(10)
                                    .frame(width: 150, alignment: .leading)
                                    .frame(minHeight: 44)
                                    .overlay(Rectangle().stroke(Color(.separator), lineWidth: 0.5))
                                    .accessibilityIdentifier("cell-\(r)-\(c)")
                            }
                        }
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.topLeading)
            .navigationTitle("Tabelle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { finish() }.accessibilityIdentifier("tableDone")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { rows.append(Array(repeating: "", count: columns)) } label: { Label("Zeile hinzufügen", systemImage: "plus") }
                        Button { addColumn(at: columns) } label: { Label("Spalte hinzufügen", systemImage: "plus") }
                        Divider()
                        Button { done(snapshot(), true); dismiss() } label: { Label("In Text konvertieren", systemImage: "text.alignleft") }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Tabelle löschen", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel(Text("Mehr"))
                }
            }
            .alert("Tabelle löschen?", isPresented: $confirmDelete) {
                Button("Löschen", role: .destructive) { done(nil, false); dismiss() }
                Button("Abbrechen", role: .cancel) {}
            }
        }
        .onAppear {
            table.normalize()
            rows = table.rows
            alignments = table.alignments
            if focus == nil { focus = Cell(r: 0, c: 0) }
        }
        .interactiveDismissDisabled()
    }

    private func binding(_ r: Int, _ c: Int) -> Binding<String> {
        Binding(get: { r < rows.count && c < rows[r].count ? rows[r][c] : "" },
                set: { v in if r < rows.count, c < rows[r].count { rows[r][c] = v } })
    }

    private func next(_ r: Int, _ c: Int) {
        if c + 1 < columns { focus = Cell(r: r, c: c + 1) }
        else if r + 1 < rows.count { focus = Cell(r: r + 1, c: 0) }
        else { rows.append(Array(repeating: "", count: columns)); focus = Cell(r: r + 1, c: 0) }
    }

    private func rowMenu(_ r: Int) -> some View {
        Menu {
            Button { rows.insert(Array(repeating: "", count: columns), at: r) } label: { Label("Zeile oberhalb hinzufügen", systemImage: "arrow.up") }
            Button { rows.insert(Array(repeating: "", count: columns), at: r + 1) } label: { Label("Zeile unterhalb hinzufügen", systemImage: "arrow.down") }
            if r + 1 < rows.count {
                Button { rows.swapAt(r, r + 1) } label: { Label("Mit nächster Zeile tauschen", systemImage: "arrow.up.arrow.down") }
            }
            Button { rows[r] = Array(repeating: "", count: columns) } label: { Label("Zellinhalt löschen", systemImage: "eraser") }
            if rows.count > 1 {
                Button(role: .destructive) { rows.remove(at: r) } label: { Label("Zeile löschen", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis").rotationEffect(.degrees(90)).font(.footnote)
                .frame(width: 34, height: 44).foregroundStyle(.secondary)
        }
        .accessibilityLabel(Text("Zeile \(r + 1)"))
    }

    private func columnMenu(_ c: Int) -> some View {
        Menu {
            Button { addColumn(at: c) } label: { Label("Spalte links hinzufügen", systemImage: "arrow.left") }
            Button { addColumn(at: c + 1) } label: { Label("Spalte rechts hinzufügen", systemImage: "arrow.right") }
            if columns > 1 {
                Button(role: .destructive) {
                    for r in rows.indices { rows[r].remove(at: c) }
                    if c < alignments.count { alignments.remove(at: c) }
                } label: { Label("Spalte löschen", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis").font(.footnote).frame(width: 150, height: 34).foregroundStyle(.secondary)
        }
        .accessibilityLabel(Text("Spalte \(c + 1)"))
    }

    private func addColumn(at c: Int) {
        for r in rows.indices { rows[r].insert("", at: min(c, rows[r].count)) }
        alignments.insert("", at: min(c, alignments.count))
    }

    private func snapshot() -> TableBox { TableBox(rows: rows, alignments: alignments) }

    private func finish() {
        done(snapshot(), false)
        dismiss()
    }
}
