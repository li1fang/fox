import SwiftUI

// Keep the information, preview and actions in stable slots while rotating.
struct PhoneCameraLayout: Layout {
    var landscape: Bool
    var spacing: CGFloat = 8
    var cameraLeading = false

    struct Regions {
        let information: CGRect
        let camera: CGRect
        let actions: CGRect
    }

    func columnWidth(for width: CGFloat) -> CGFloat {
        landscape ? min(310, max(0, width - spacing) * 0.4) : width
    }

    func regions(in bounds: CGRect, informationHeight: CGFloat, actionsHeight: CGFloat) -> Regions {
        let width = columnWidth(for: bounds.width)
        let actionsHeight = min(bounds.height, max(0, actionsHeight))
        let informationHeight = min(max(0, bounds.height - actionsHeight - spacing * (landscape ? 1 : 2)), max(0, informationHeight))
        let columnX = landscape && cameraLeading ? bounds.maxX - width : bounds.minX
        let information = CGRect(x: columnX, y: bounds.minY, width: width, height: informationHeight)
        let actions = CGRect(x: columnX, y: bounds.maxY - actionsHeight, width: width, height: actionsHeight)
        let camera = landscape
            ? CGRect(x: cameraLeading ? bounds.minX : bounds.minX + width + spacing, y: bounds.minY,
                     width: max(0, bounds.width - width - spacing), height: bounds.height)
            : CGRect(x: bounds.minX, y: information.maxY + spacing, width: bounds.width,
                     height: max(0, actions.minY - information.maxY - 2 * spacing))
        return Regions(information: information, camera: camera, actions: actions)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = proposal.replacingUnspecifiedDimensions(by: CGSize(width: 390, height: 700))
        return CGSize(width: size.width.isFinite ? max(0, size.width) : 390,
                      height: size.height.isFinite ? max(0, size.height) : 700)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let width = columnWidth(for: bounds.width)
        let measuredActions = subviews[2].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let available = max(0, bounds.height - measuredActions - spacing)
        let measuredInformation = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: available)).height
        let regions = regions(in: bounds, informationHeight: measuredInformation, actionsHeight: measuredActions)
        for (view, region) in zip(subviews, [regions.information, regions.camera, regions.actions]) {
            view.place(at: region.origin, anchor: .topLeading, proposal: ProposedViewSize(region.size))
        }
    }
}
