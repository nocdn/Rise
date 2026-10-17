import ActivityKit
import SwiftUI
import WidgetKit

@main struct RiseDownloadWidgets: WidgetBundle {
    var body: some Widget { DownloadLiveActivity() }
}

struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadActivityRow(name: context.attributes.name, state: context.state,
                                downloadID: context.attributes.downloadID)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .activityBackgroundTint(.black.opacity(0.2))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(DownloadActivityAttributes.downloadsURL)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    DownloadActivityRow(name: context.attributes.name, state: context.state,
                                        downloadID: context.attributes.downloadID, isIsland: true)
                        // Centres the icon and ring in the expanded island; the text moves back down.
                        .offset(y: -15.6)
                }
            } compactLeading: {
                DownloadActivityArrow()
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .frame(width: 26, height: 26)
                    .accessibilityLabel("Downloading")
            } compactTrailing: {
                DownloadActivityRing(fraction: context.state.fraction, side: 24, stroke: 2.7)
            } minimal: {
                DownloadActivityRing(fraction: context.state.fraction, side: 18, stroke: 2.2)
            }
            .contentMargins(.horizontal, 20, for: .expanded)
            .contentMargins(.bottom, 6, for: .expanded)
            // Attached to the island, the ring sits as far from the island's edge as from its top and
            // bottom: (36.67 - 18) / 2, where the system's own margin is about 7.
            .contentMargins(.leading, 9.33, for: .minimal)
            .widgetURL(DownloadActivityAttributes.downloadsURL)
            .keylineTint(.white)
        }
    }
}
