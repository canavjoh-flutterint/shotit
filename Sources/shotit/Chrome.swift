import ShotitCore
import SwiftUI

/// Excalidraw violet, used for the active tool and selected options.
private let accent = Color(red: 0.41, green: 0.40, blue: 0.86)

private struct Pill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }
}

struct ToolbarView: View {
    @ObservedObject var model: EditorModel
    /// Sends a command to the canvas.
    let perform: (Selector) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Tool.allCases) { t in
                let on = model.tool == t
                Button { model.tool = t } label: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(on ? accent : .primary)
                        .frame(width: 34, height: 32)
                        .overlay(alignment: .bottomTrailing) {
                            Text(String(t.number ?? t.key).uppercased())
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.trailing, 3).padding(.bottom, 2)
                        }
                        .background(RoundedRectangle(cornerRadius: 8).fill(on ? accent.opacity(0.18) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(t.title)  \(String(t.key).uppercased())")
            }
            Divider().frame(height: 22).padding(.horizontal, 4)
            command("arrow.uturn.backward", "Undo  ⌘Z", #selector(CanvasView.undo(_:)))
            command("doc.on.doc", "Copy  ⌘C (Return copies and closes)", #selector(CanvasView.copy(_:)))
            command("square.and.arrow.down", "Save  ⌘S", #selector(CanvasView.saveDocument(_:)))
        }
        .padding(4)
        .modifier(Pill())
    }

    private func command(_ symbol: String, _ help: String, _ action: Selector) -> some View {
        Button { perform(action) } label: {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .frame(width: 34, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct PropertyPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let tool = model.styleTool
        let s = model.style
        let sections = tool.sections
        if sections.isEmpty && tool != .crop {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if tool == .crop { frameSection }
                if sections.contains(.color) {
                    group("Color") {
                        HStack(spacing: 3) {
                            ForEach(Palette.strokes, id: \.self) { c in
                                swatch(c, on: s.color == c) { model.setStyle { $0.color = c } }
                            }
                        }
                    }
                }
                if sections.contains(.width) {
                    group("Stroke width") {
                        options(StrokeWidth.allCases, s.width, { v in model.setStyle { $0.width = v } }) { w in
                            Capsule().frame(width: 18, height: w.rawValue * 0.9)
                        }
                    }
                }
                if sections.contains(.dash) {
                    group("Stroke style") {
                        options([false, true], s.dashed, { v in model.setStyle { $0.dashed = v } }) { dashed in
                            LineSample(dashed: dashed)
                        }
                    }
                }
                if sections.contains(.fill) {
                    group("Fill") {
                        options(ShotitCore.FillStyle.allCases, s.fill, { v in model.setStyle { $0.fill = v } }) { f in
                            FillSample(fill: f)
                        }
                    }
                }
                if sections.contains(.roughness) {
                    group("Sloppiness") {
                        options(Roughness.allCases, s.roughness, { v in model.setStyle { $0.roughness = v } }) { r in
                            Text(r == .clean ? "Clean" : r == .sketchy ? "Sketchy" : "Wild").font(.system(size: 11))
                        }
                    }
                }
                if sections.contains(.fontSize) {
                    group("Size") {
                        options(FontSize.allCases, s.fontSize, { v in model.setStyle { $0.fontSize = v } }) { f in
                            Text(String(describing: f).uppercased()).font(.system(size: 11, weight: .medium))
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 204, alignment: .leading)
            .modifier(Pill())
        }
    }

    private var frameSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            group("Background") {
                HStack(spacing: 6) {
                    ForEach(Palette.backgrounds.indices, id: \.self) { i in
                        let c = Palette.backgrounds[i]
                        swatch(c, on: model.doc.background == c) { model.setBackground(c) }
                    }
                }
            }
            HStack {
                Button("Add padding  E") { model.pad() }
                Button("Reset") { model.resetFrame() }
            }
            .controlSize(.small)
            Text("Drag to crop. Drag the handles outward to extend.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content()
        }
    }

    private func swatch(_ c: RGBA?, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if let c {
                    Circle().fill(Color(cgColor: c.cgColor))
                    Circle().strokeBorder(Color.primary.opacity(0.15))
                } else {
                    Circle().strokeBorder(Color.primary.opacity(0.3))
                    Image(systemName: "slash.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)
            .padding(2)
            .overlay(Circle().strokeBorder(on ? accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func options<V: Hashable, L: View>(_ values: [V], _ current: V, _ set: @escaping (V) -> Void,
                                               @ViewBuilder label: @escaping (V) -> L) -> some View {
        HStack(spacing: 4) {
            ForEach(values, id: \.self) { v in
                Button { set(v) } label: {
                    label(v)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .foregroundStyle(v == current ? accent : .primary)
                        .background(RoundedRectangle(cornerRadius: 6).fill(v == current ? accent.opacity(0.18) : Color.primary.opacity(0.05)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct LineSample: View {
    let dashed: Bool
    var body: some View {
        Path { p in p.move(to: CGPoint(x: 0, y: 1.5)); p.addLine(to: CGPoint(x: 22, y: 1.5)) }
            .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [3, 4] : []))
            .frame(width: 22, height: 3)
    }
}

private struct FillSample: View {
    let fill: ShotitCore.FillStyle
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3)
        ZStack {
            switch fill {
            case .none: EmptyView()
            case .solid: shape.fill()
            case .translucent: shape.fill().opacity(0.3)
            case .hachure:
                Path { p in
                    for x in stride(from: -16.0, to: 16.0, by: 4) {
                        p.move(to: CGPoint(x: x, y: 16)); p.addLine(to: CGPoint(x: x + 16, y: 0))
                    }
                }
                .stroke(lineWidth: 1)
                .clipShape(shape)
            }
            shape.stroke(lineWidth: 1.5)
        }
        .frame(width: 16, height: 16)
    }
}

struct ToastView: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        Group {
            if let t = model.toast {
                Text(t).font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.thickMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.toast)
    }
}
