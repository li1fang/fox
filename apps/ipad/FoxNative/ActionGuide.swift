import SwiftUI

/// Thin presentation descriptions. Counting thresholds and readiness remain in Core.
struct ActionGuide: Equatable {
    let title: String
    let camera: String
    let movement: String
    let diagram: Diagram
    enum Diagram { case squatSide, curlSide }
    static func forExercise(_ id: String) -> ActionGuide? {
        switch id {
        case "bodyweight_squat":
            return .init(title:"侧面深蹲示例",camera:"侧对镜头，近侧髋、膝、踝完整入镜；先站直，选择朝向镜头的近侧。",movement:"下蹲后再站起，保持腿部行程在画面内。可持器械，观察次数可能有误，结束后核对。",diagram:.squatSide)
        case "dumbbell_curl":
            return .init(title:"侧面弯举示例",camera:"侧对镜头，让观察侧肩、肘、腕保持在画面内。",movement:"由自然伸展弯起，再有控制地放回。结束后核对次数。",diagram:.curlSide)
        default: return nil
        }
    }
}

struct ActionGuideView: View {
    let guide: ActionGuide
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text(guide.title).font(.headline)
            Canvas { context, size in
                func point(_ x:CGFloat,_ y:CGFloat)->CGPoint {CGPoint(x:size.width*x,y:size.height*y)}
                let head=point(0.35,0.14),shoulder=point(0.37,0.28),hip=point(0.47,0.52)
                let knee=guide.diagram == .squatSide ? point(0.67,0.66):point(0.47,0.72)
                let ankle=guide.diagram == .squatSide ? point(0.54,0.90):point(0.47,0.91)
                var body=Path();body.move(to:shoulder);body.addLine(to:hip);body.addLine(to:knee);body.addLine(to:ankle)
                body.move(to:shoulder);body.addLine(to:point(0.29,0.48));body.addLine(to:point(0.41,0.53))
                context.stroke(body,with:.color(.secondary),style:StrokeStyle(lineWidth:5,lineCap:.round,lineJoin:.round))
                context.stroke(Path(ellipseIn:CGRect(x:head.x-9,y:head.y-9,width:18,height:18)),with:.color(.secondary),lineWidth:3)
                for p in (guide.diagram == .squatSide ? [hip,knee,ankle] : [shoulder,point(0.29,0.48),point(0.41,0.53)]) {
                    context.fill(Path(ellipseIn:CGRect(x:p.x-5,y:p.y-5,width:10,height:10)),with:.color(.green))
                }
            }.frame(height:145).accessibilityHidden(true)
            Text(guide.camera).font(.callout)
            Text(guide.movement).font(.callout).foregroundStyle(.secondary)
        }.accessibilityElement(children:.combine).accessibilityIdentifier("action-guide-\(guide.diagram == .squatSide ? "squat":"curl")")
    }
}
