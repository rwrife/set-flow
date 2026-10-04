import SetFlowKit
import SwiftUI

/// Private workout history with explainable weekly summaries (issue #5).
/// Every number shown here is derived on demand from the local durable
/// event stream — nothing is uploaded, and every metric carries the
/// formula that produced it via `SummaryExplainer`.
struct HistoryView: View {
    let store: SetFlowStore
    @State private var weeks: [WeekSummary] = []
    @State private var errorText: String?

    var body: some View {
        List {
            if weeks.isEmpty && errorText == nil {
                Text("No sessions yet. Finish or abandon a session and it will appear here.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("history.empty")
            }
            ForEach(weeks, id: \.weekKey) { week in
                Section(week.weekKey.isoLabel) {
                    summaryRows(for: week)
                }
            }
            Section("How these numbers are calculated") {
                Text(SummaryExplainer.weeklyVolumeFormula)
                    .accessibilityIdentifier("history.formula.volume")
                Text(SummaryExplainer.completionConsistencyFormula)
                    .accessibilityIdentifier("history.formula.consistency")
                Text(SummaryExplainer.sessionCompletionFormula)
                    .accessibilityIdentifier("history.formula.sessions")
                Text(SummaryExplainer.asymmetryNotice)
                    .accessibilityIdentifier("history.formula.asymmetry")
            }
            if let errorText {
                Text(errorText).foregroundStyle(.red).accessibilityIdentifier("history.error")
            }
        }
        .navigationTitle("History")
        .task { reload() }
    }

    @ViewBuilder
    private func summaryRows(for week: WeekSummary) -> some View {
        Text(week.weekKey.isoLabel)
            .font(.headline)
            .accessibilityIdentifier("history.week")
        Text("Sessions: \(week.completedSessionCount) completed, \(week.abandonedSessionCount) abandoned, \(week.activeSessionCount) in progress")
            .accessibilityIdentifier("history.sessions")
        if let rate = week.sessionCompletionRate {
            Text("Session completion: \(percent(rate)) of finished-or-abandoned sessions")
                .accessibilityIdentifier("history.sessionCompletion")
        } else {
            Text("Session completion: no finished or abandoned sessions yet")
                .accessibilityIdentifier("history.sessionCompletion")
        }
        if let consistency = week.completionConsistency {
            Text("Completion consistency: \(percent(consistency)) of resolved planned sets (completed \(plannedCompleted(week)) of \(week.resolvedPlannedSetCount))")
                .accessibilityIdentifier("history.consistency")
        } else {
            Text("Completion consistency: no planned sets resolved yet")
                .accessibilityIdentifier("history.consistency")
        }
        if let volume = week.totalVolume {
            Text("Volume: \(format(volume))")
                .accessibilityIdentifier("history.volume")
        } else {
            Text("Volume: nothing to add yet — sets need both a load and a rep count to count toward volume")
                .accessibilityIdentifier("history.volume.note")
        }
        ForEach(week.exercises, id: \.exerciseID) { exercise in
            exerciseRows(for: exercise)
        }
    }

    @ViewBuilder
    private func exerciseRows(for exercise: ExerciseWeekSummary) -> some View {
        Text("\(exercise.exerciseName): \(exercise.completedPlannedSetCount) planned set\(exercise.completedPlannedSetCount == 1 ? "" : "s") completed, \(exercise.skippedPlannedSetCount) skipped, \(exercise.adHocCompletedSetCount) free set\(exercise.adHocCompletedSetCount == 1 ? "" : "s")")
            .font(.subheadline.weight(.medium))
            .accessibilityIdentifier("history.exercise")
        if exercise.volumeContributingSetCount > 0 {
            Text("Volume: \(format(exercise.volume)) across \(exercise.volumeContributingSetCount) set\(exercise.volumeContributingSetCount == 1 ? "" : "s")")
                .accessibilityIdentifier("history.exercise.volume")
        }
        if exercise.excludedFromVolumeCount > 0 {
            Text("\(exercise.excludedFromVolumeCount) set\(exercise.excludedFromVolumeCount == 1 ? "" : "s") excluded from volume (load or reps not recorded)")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("history.exercise.excluded")
        }
        if !exercise.completedSetCountsBySide.isEmpty {
            Text(sideLine(exercise.completedSetCountsBySide))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("history.exercise.sides")
        }
        if let asymmetry = exercise.leftMinusRightCompletedSets {
            Text("Left minus right completed sets: \(asymmetry >= 0 ? "+" : "")\(asymmetry) — descriptive only")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("history.asymmetry")
        }
    }

    private func reload() {
        do {
            weeks = Array(try store.weekSummaries(calendar: .current).reversed())
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func plannedCompleted(_ week: WeekSummary) -> Int {
        week.exercises.reduce(0) { $0 + $1.completedPlannedSetCount }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    /// Explicit-unit mass rendering from exact thousandths — no floating point.
    private func format(_ mass: MassThousandths) -> String {
        let whole = mass.amountInThousandths / 1000
        let fraction = abs(mass.amountInThousandths % 1000)
        let unit = mass.unit == .kilograms ? "kg" : "lb"
        if fraction == 0 { return "\(whole) \(unit)" }
        var digits = String(format: "%03d", Int(fraction))
        while digits.hasSuffix("0") { digits.removeLast() }
        return "\(whole).\(digits) \(unit)"
    }

    private func sideLine(_ counts: [UnilateralSide: Int]) -> String {
        func count(_ side: UnilateralSide) -> String? {
            guard let value = counts[side], value > 0 else { return nil }
            return "\(value)"
        }
        var parts: [String] = []
        if let left = count(.left) { parts.append("left \(left)") }
        if let right = count(.right) { parts.append("right \(right)") }
        if let unknown = count(.unknown) { parts.append("side not recorded \(unknown)") }
        if let bilateral = count(.bilateral) { parts.append("both sides \(bilateral)") }
        return parts.isEmpty ? "No completed sets recorded" : "Completed sets by side: " + parts.joined(separator: ", ")
    }
}
