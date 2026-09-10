import SwiftUI
import OpenClickyKit

/// What the voice session is doing, on its own object.
///
/// Separate from `OverlayModel` for the reason Phase 2 established the hard way: a
/// `@Published` write fires `objectWillChange` for the *whole* object, and the input
/// level arrives dozens of times a second. Put on the overlay's model it would have
/// invalidated the input field, the configuration line, the activity panel and the
/// approval prompt forty times a second for the lifetime of a session — reintroducing,
/// with interest, exactly the churn that phase removed.
///
/// The level is also rate-limited on the way in. The tap produces a buffer roughly every
/// 45 ms and no display needs more than about twenty updates a second; the rest is work
/// nobody can see.
@MainActor
final class VoiceMeter: ObservableObject {

    /// Nil when no session is running, which is what the overlay keys the whole
    /// indicator off.
    @Published private(set) var phase: VoiceSession.Phase?
    /// Loudness of what the microphone is actually sending, 0–1.
    @Published private(set) var level: Float = 0
    /// The utterance in progress, as the transcriber currently has it.
    ///
    /// Shown because someone talking to a program with no visible feedback cannot tell a
    /// microphone that is not listening from one that is mishearing, and those need
    /// opposite responses — repeat yourself, or stop and fix the input.
    @Published private(set) var heard = ""

    private var lastLevelUpdate = Date.distantPast
    private static let levelInterval: TimeInterval = 1.0 / 20

    func update(phase: VoiceSession.Phase?, heard: String) {
        if self.phase != phase { self.phase = phase }
        if self.heard != heard { self.heard = heard }
        // A session that has ended must not leave the last bar standing.
        if phase == nil, level != 0 { level = 0 }
    }

    func update(level: Float) {
        let now = Date()
        guard now.timeIntervalSince(lastLevelUpdate) >= Self.levelInterval else { return }
        lastLevelUpdate = now
        self.level = level
    }
}

/// The live session, in place of the text field.
///
/// Shown *instead of* the input only while a session is running. Replacing the field
/// outright would take typing away from every user who has no Deepgram key and every
/// task that is easier typed than said — the indicator is what the overlay becomes when
/// you are talking to it, not what it becomes permanently.
struct LiveAudioIndicator: View {

    @ObservedObject var meter: VoiceMeter
    let phase: VoiceSession.Phase

    var body: some View {
        HStack(spacing: 12) {
            Waveform(level: meter.level, mood: mood, tint: tint)
                .frame(width: 62, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.isEmpty ? title : "\(title). \(detail)")
    }

    /// How the bars behave, which is the part someone reads without looking at the words.
    private var mood: Waveform.Mood {
        switch phase {
        // Driven by the microphone. These are the two phases where the bars are a
        // measurement, and where a still meter correctly means "I hear nothing".
        case .listening, .hearing: return .metering
        // The agent is talking or acting, and the microphone level would be either its
        // own voice or an empty room. A steady sweep says "busy, and still listening"
        // without claiming to be measuring anything.
        case .speaking, .working, .awaitingApproval: return .sweeping
        case .idle: return .resting
        }
    }

    private var title: String {
        switch phase {
        case .listening: return "Listening"
        case .hearing: return "Listening…"
        case .working: return "Working"
        case .speaking: return "Speaking"
        case .awaitingApproval: return "Waiting for your answer"
        case .idle: return "Voice session off"
        }
    }

    private var detail: String {
        switch phase {
        case .hearing where !meter.heard.isEmpty: return meter.heard
        case .listening, .hearing: return "Say what you want, or start typing"
        case .working, .speaking: return "Talk over it to interrupt"
        case .awaitingApproval: return "Say yes or no"
        case .idle: return ""
        }
    }

    private var tint: Color {
        switch phase {
        case .listening, .hearing: return .accentColor
        case .working: return .secondary
        case .speaking: return .green
        // The same yellow the activity log uses for a denial: this is the moment the
        // gate has stopped for, and it should read as that moment everywhere.
        case .awaitingApproval: return .yellow
        case .idle: return .secondary
        }
    }
}

/// Five bars.
///
/// The animation is entirely local — a `TimelineView` and the level it was handed — so a
/// running session costs the rest of the overlay nothing. Driving it from published state
/// instead would put a model write on every frame, which is the thing Phase 2 was about.
private struct Waveform: View {

    enum Mood {
        /// Heights follow the microphone. A still meter means silence, truthfully.
        case metering
        /// A steady sweep. Says "busy" without claiming to measure anything.
        case sweeping
        case resting
    }

    let level: Float
    let mood: Mood
    var tint: Color = .accentColor

    private static let bars = 5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<Self.bars, id: \.self) { index in
                    Capsule()
                        .fill(tint.opacity(0.85))
                        .frame(width: 5, height: height(of: index, at: time))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func height(of index: Int, at time: TimeInterval) -> CGFloat {
        let minimum: CGFloat = 4
        let maximum: CGFloat = 26
        switch mood {
        case .resting:
            return minimum
        case .sweeping:
            // A travelling wave, so it reads as motion rather than as a level.
            let offset = Double(index) * 0.55
            let wave = (sin(time * 4 - offset) + 1) / 2
            return minimum + (maximum - minimum) * 0.55 * wave
        case .metering:
            // The outer bars respond less than the middle, which is what makes a row of
            // capsules read as a voice rather than as a bar chart. The small idle
            // shimmer is scaled *by* the level, so at silence it is exactly zero and the
            // meter is genuinely still.
            let weight = [0.45, 0.8, 1.0, 0.8, 0.45][index]
            let shimmer = 1 + 0.18 * sin(time * 9 + Double(index))
            let scaled = CGFloat(level) * weight * shimmer
            return minimum + (maximum - minimum) * min(1, max(0, scaled))
        }
    }
}
