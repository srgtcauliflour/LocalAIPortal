import SwiftUI
import UIKit

/// Lets the user paint over the part of a photo that should change.
/// Points are stored in 0...1 coordinates so they scale to any size.
struct MaskEditor: View {
    let image: UIImage
    let outputSize: CGSize
    let onDone: (UIImage?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []
    @State private var brush: Double = 0.08

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Paint over the area you want to change. Everything else stays as it is.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                GeometryReader { geometry in
                    let side = min(geometry.size.width, geometry.size.height)
                    let size = CGSize(
                        width: side, height: side * outputSize.height / max(1, outputSize.width))
                    ZStack {
                        Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                        Canvas { context, canvasSize in
                            for stroke in strokes + [current] where !stroke.isEmpty {
                                var path = Path()
                                let points = stroke.map {
                                    CGPoint(x: $0.x * canvasSize.width, y: $0.y * canvasSize.height)
                                }
                                path.addLines(points)
                                if points.count == 1 { path.addLine(to: points[0]) }
                                context.stroke(
                                    path, with: .color(.red.opacity(0.5)),
                                    style: StrokeStyle(
                                        lineWidth: brush * canvasSize.width, lineCap: .round,
                                        lineJoin: .round))
                            }
                        }
                        .frame(width: size.width, height: size.height)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let point = CGPoint(
                                        x: min(1, max(0, value.location.x / size.width)),
                                        y: min(1, max(0, value.location.y / size.height)))
                                    current.append(point)
                                }
                                .onEnded { _ in
                                    if !current.isEmpty { strokes.append(current) }
                                    current = []
                                }
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                HStack {
                    Image(systemName: "paintbrush.pointed")
                    Slider(value: $brush, in: 0.02 ... 0.25)
                    Button("Clear") { strokes = [] }
                        .disabled(strokes.isEmpty)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
            .navigationTitle("Edit area")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onDone(strokes.isEmpty ? nil : renderMask())
                        dismiss()
                    }
                }
            }
        }
    }

    /// White strokes on black, at the model's output size.
    private func renderMask() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: outputSize))
            UIColor.white.setStroke()
            for stroke in strokes {
                let path = UIBezierPath()
                path.lineWidth = brush * outputSize.width
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                for (index, point) in stroke.enumerated() {
                    let scaled = CGPoint(
                        x: point.x * outputSize.width, y: point.y * outputSize.height)
                    if index == 0 {
                        path.move(to: scaled)
                        path.addLine(to: scaled)
                    } else {
                        path.addLine(to: scaled)
                    }
                }
                path.stroke()
            }
        }
    }
}
