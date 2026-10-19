import AppIntents
import SwiftUI

/// One compact row keeps the expanded island at the system's smallest useful height.
struct DownloadActivityRow: View {
    let name: String
    let state: DownloadActivityAttributes.ContentState
    let downloadID: String
    var isIsland = false

    var body: some View {
        HStack(spacing: isIsland ? 18 : 16) {
            Image("ActivityRise").resizable().aspectRatio(contentMode: .fit)
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(state.finished ? "Downloaded “\(name)”" : "Downloading “\(name)”")
                    .font(.system(size: 17, weight: isIsland ? .regular : .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.tail)
                Text(state.progressText)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(isIsland ? 0.34 : 0.5))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(y: isIsland ? 11.6 : 0)
            Button(intent: StopDownloadIntent(downloadID: downloadID)) {
                DownloadActivityRing(fraction: state.fraction, side: isIsland ? 48 : 38,
                                     stroke: isIsland ? 4.5 : 3.5, showsStop: !state.finished)
                    .frame(width: isIsland ? 48 : 44, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state.finished)
            .accessibilityLabel("Stop downloading \(name)")
            .accessibilityValue(state.progressText)
        }
        .frame(height: 48)
    }
}

struct DownloadActivityRing: View {
    let fraction: Double
    let side: CGFloat
    let stroke: CGFloat
    var showsStop = false
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.2), lineWidth: stroke)
            Circle().trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(.white, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsStop {
                RoundedRectangle(cornerRadius: side/10, style: .continuous)
                    .fill(.white).frame(width: side/3, height: side/3)
            }
        }
        .padding(stroke/2)
        .frame(width: side, height: side)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Download progress")
        .accessibilityValue("\(Int(min(1, max(0, fraction))*100)) percent")
    }
}

/// The exact path and stroke used by the Downloads button in More.
struct DownloadActivityArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let scale = min(rect.width, rect.height)/24
        let x = rect.midX-12*scale, y = rect.midY-12*scale
        func point(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: x+px*scale, y: y+py*scale) }
        path.move(to: point(12, 6.6)); path.addLine(to: point(12, 17.4))
        path.move(to: point(8.4, 13.8)); path.addLine(to: point(12, 17.4)); path.addLine(to: point(15.6, 13.8))
        return path
    }
}
