import SwiftUI

struct IncidentPill: View {
    let incident: Incident

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.18))
                Text(severityNumber)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(tint)
            }
            .frame(width: 48, height: 48)

            Text(incident.id)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
            Text(durationText)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(tint)
        }
        .frame(maxWidth: .infinity)
    }

    private var severityNumber: String {
        incident.severity == .unknown ? "?" : String(incident.severity.rawValue.suffix(1))
    }

    private var tint: Color {
        switch incident.severity {
        case .sev1, .sev2:           return Theme.alert
        case .sev3:                  return Theme.warn
        case .sev4, .sev5, .unknown: return Theme.info
        }
    }

    private var durationText: String {
        let mins = Int(-incident.openedAt.timeIntervalSinceNow / 60)
        if mins < 60 { return "\(mins)m" }
        return "\(mins / 60)h"
    }
}
