import SwiftUI

enum FoxAdaptiveLayout {
    static func sideBySide(horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?) -> Bool {
        vertical == .compact || (horizontal == .regular && vertical == .regular)
    }

    static func columns(width: CGFloat, phone: Bool, horizontal: UserInterfaceSizeClass?,
                        vertical: UserInterfaceSizeClass?, accessibility: Bool) -> Int {
        if accessibility || (phone && !(horizontal == .regular && vertical == .regular)) { return 1 }
        return width >= 1100 ? 3 : (width >= 700 ? 2 : 1)
    }

    // Basic fold safety, not a hover workspace: keep related controls together in one unobscured region.
    static func usableRect(in bounds: CGRect, avoiding regions: [CGRect]) -> CGRect {
        var candidates = [bounds]
        for cut in regions where !cut.isEmpty && !cut.isNull && !cut.isInfinite {
            candidates = candidates.flatMap { rect -> [CGRect] in
                let overlap = rect.intersection(cut)
                guard !overlap.isNull, !overlap.isEmpty else { return [rect] }
                return [
                    CGRect(x: rect.minX, y: rect.minY, width: max(0, overlap.minX - rect.minX), height: rect.height),
                    CGRect(x: overlap.maxX, y: rect.minY, width: max(0, rect.maxX - overlap.maxX), height: rect.height),
                    CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, overlap.minY - rect.minY)),
                    CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: max(0, rect.maxY - overlap.maxY))
                ].filter { !$0.isEmpty }
            }
        }
        return candidates.max { $0.width * $0.height < $1.width * $1.height } ?? .zero
    }
}

private struct FoxReservedSpace: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontal
    @Environment(\.verticalSizeClass) private var vertical
    func body(content: Content) -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            GeometryReader { geometry in
                let bounds = CGRect(origin: .zero, size: geometry.size)
                let cuts = (geometry.reservedRegions(kind: .division) + geometry.reservedRegions(kind: .occlusion))
                    .filter(\.isActive).map(\.frame)
                let area = FoxAdaptiveLayout.usableRect(in: bounds, avoiding: cuts)
                content
                    .environment(\.horizontalSizeClass, area == bounds ? horizontal : (area.width < 600 ? .compact : .regular))
                    .environment(\.verticalSizeClass, area == bounds ? vertical : (area.height < 440 ? .compact : .regular))
                    .frame(width: area.width, height: area.height)
                    .position(x: area.midX, y: area.midY)
            }
        } else { content }
        #else
        content
        #endif
    }
}

extension View {
    func foxReservedSpace() -> some View { modifier(FoxReservedSpace()) }
}
