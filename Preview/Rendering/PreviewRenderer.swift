import AppKit
import SpyglassKit

/// Turns one kind of file into a preview view.
///
/// Contract: parse off the main thread (`Task.detached`), build the view on
/// the main actor, and throw for anything that can't be rendered. Throwing
/// is safe: the caller falls back to plain text, then a file card.
@MainActor
protocol PreviewRenderer {
    func makeView(for url: URL, kind: PreviewKind, settings: PreviewSettings) async throws -> NSView
}

enum RenderError: Error, CustomStringConvertible {
    case timedOut
    case unsupported(String)

    var description: String {
        switch self {
        case .timedOut: return "renderer exceeded its time budget"
        case .unsupported(let why): return why
        }
    }
}

/// Runs `operation` but gives up after `seconds`. Everything here runs on the
/// main actor, so the `done` flag needs no lock. A renderer that parses on
/// the main thread would starve the timer; the contract above forbids that.
@MainActor
func withRenderBudget(
    seconds: Double,
    _ operation: @escaping @MainActor () async throws -> NSView
) async throws -> NSView {
    final class State { var done = false }
    let state = State()
    return try await withCheckedThrowingContinuation { continuation in
        let work = Task { @MainActor in
            do {
                let view = try await operation()
                guard !state.done else { return }
                state.done = true
                continuation.resume(returning: view)
            } catch {
                guard !state.done else { return }
                state.done = true
                continuation.resume(throwing: error)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard !state.done else { return }
            state.done = true
            work.cancel()
            continuation.resume(throwing: RenderError.timedOut)
        }
    }
}
