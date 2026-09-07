import Foundation

/// Draws "· thinking… Ns" over itself while a turn is in flight.
///
/// The problem streaming solves for OpenAI-compatible providers, solved a second way
/// for the one that cannot stream. Anthropic's event stream would have to reconstruct
/// thinking blocks *with their signatures* to keep transcript replay valid, and that
/// is not something to write against shapes that cannot be exercised here — a wrong
/// signature is a 400 on every subsequent turn. Counting seconds needs no protocol at
/// all and works for every provider.
///
/// In the kit rather than the CLI for the same reason `RunReport` is: this is the only
/// thing a user sees during the longest part of a run, and until it could be driven
/// without an API key nobody could check that it draws what it claims to.
public actor WaitingLine {

    /// Where the line goes. Injected so a test can read what was drawn, and because
    /// this writes without newlines — it is not `RunReport`'s kind of output.
    public typealias Writer = @Sendable (String) -> Void

    private let enabled: Bool
    private let interval: Duration
    private let write: Writer
    private var ticker: Task<Void, Never>?

    /// - Parameters:
    ///   - enabled: false in a pipe or a log, where `\r` does not overwrite and this
    ///     would emit one line per second forever.
    ///   - interval: injectable so a test does not wait real seconds for real ticks.
    public init(
        enabled: Bool, interval: Duration = .seconds(1), write: @escaping Writer
    ) {
        self.enabled = enabled
        self.interval = interval
        self.write = write
    }

    public func start() {
        guard enabled, ticker == nil else { return }
        let interval = interval
        let write = write
        ticker = Task {
            var seconds = 0
            // The first draw comes from `RunReport`, so this begins by waiting.
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                seconds += 1
                write("\r" + RunReport.waitingLine(seconds: seconds))
            }
        }
    }

    /// Stops and blanks the line, so whatever prints next starts from a clean column.
    ///
    /// Padded rather than a bare `\r`: the next write may be shorter than the line it
    /// replaces, and the tail of the old one would survive underneath it — which is
    /// how a progress indicator ends up reading `· thinking… 9s…`.
    public func stop() {
        guard let ticker else { return }
        ticker.cancel()
        self.ticker = nil
        write("\r" + String(repeating: " ", count: 24) + "\r")
    }

    /// Whether a ticker is running. For tests, and for nothing else.
    public var isRunning: Bool { ticker != nil }
}
