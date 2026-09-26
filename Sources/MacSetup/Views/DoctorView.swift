import SwiftUI
import MacSetupCore

/// A small, read-only health-check list. Deliberately minimal — this is the
/// foundation for a future, larger Doctor feature, not that feature itself.
struct DoctorView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var doctor: DoctorRunner

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                header
                if let report = doctor.report { machineLine(report) }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            ScrollView {
                if let report = doctor.report {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(orderedResults(report), id: \.identifier) { result in
                            DoctorRow(result: result)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Doctor")
                    .font(.system(size: 17, weight: .semibold))
                Text("A handful of safe, read-only checks. Nothing here changes anything on this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                Task { await doctor.run(catalogApps: state.allApps) }
            } label: {
                if doctor.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Text(doctor.report == nil ? "Run Checks" : "Run Again")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(doctor.isRunning)
        }
    }

    private func machineLine(_ report: DoctorReport) -> some View {
        Text("\(report.machine.hostName) · macOS \(report.machine.macOSVersion) · \(report.machine.architecture.display)")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    private func orderedResults(_ report: DoctorReport) -> [HealthCheckResult] {
        let order: [HealthSeverity] = [.critical, .warning, .unknown, .info, .healthy]
        return report.results.sorted {
            (order.firstIndex(of: $0.severity) ?? 99) < (order.firstIndex(of: $1.severity) ?? 99)
        }
    }
}

private struct DoctorRow: View {
    let result: HealthCheckResult

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(result.title).font(.system(size: 13, weight: .medium))
                    Text(result.category).font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Text(result.details).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var symbol: String {
        switch result.severity {
        case .critical: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle.fill"
        case .info: return "info.circle"
        case .healthy: return "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch result.severity {
        case .critical: return .red
        case .warning: return .orange
        case .unknown: return .secondary
        case .info: return .secondary
        case .healthy: return .green
        }
    }
}
