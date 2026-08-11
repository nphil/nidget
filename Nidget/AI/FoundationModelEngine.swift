import Foundation
import Observation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - FoundationModelAvailability
//
// Nidget's own mirror of the framework's availability answer. The rest of the app switches on
// this, so `import FoundationModels` lives in exactly one file and a build SDK without the
// framework only has to satisfy one `#if`.

enum FoundationModelAvailability: Sendable, Equatable {
    case available
    /// The chip or region can't run Apple's on-device model at all.
    case deviceNotEligible
    /// Supported hardware, but Apple Intelligence is switched off in system Settings.
    case notEnabled
    /// Switched on, still downloading or warming up. Usually fixes itself.
    case modelNotReady
    /// The SDK we compiled against has no FoundationModels at all.
    case frameworkUnavailable
}

// MARK: - FoundationModelEngine
//
// The second generation backend: Apple's built-in on-device model, sitting beside the llama.cpp
// `AIModelManager.Engine`. Same shape as the llama path from the caller's side (a system prompt,
// a user prompt, a String or nil back) so `AIModelManager.generate` can pick either one.
//
// This is `@MainActor @Observable`, not an actor, on purpose. The llama engine is an actor
// because it makes long *blocking* C calls that would freeze the main thread; Apple's model runs
// out of process and `respond(to:)` is a plain async suspension, so there is no blocking work to
// move off the main actor. Being main-actor-isolated instead buys two things: SwiftUI and the
// already-`@MainActor` `AIModelManager` can read `availability` and `statusMessage` synchronously
// inside `body` (no async hop, no stale mirrored copy), and framework types never have to cross an
// isolation boundary we can't verify.
//
// Every call builds a FRESH `LanguageModelSession`. Sessions are stateful multi-turn transcripts,
// so reusing one across a batch of category refinements would grow the context until the window
// overflowed. Nidget only ever wants one-shot answers.
//
// Nothing here can throw at the caller: an unavailable model, a guardrail refusal, a context
// overflow, or an unsupported locale all come back as nil, and every caller already has a
// non-AI answer to fall back on (docs/AI.md §6).

@MainActor @Observable
final class FoundationModelEngine {
    static let shared = FoundationModelEngine()

    private static let log = Logger(subsystem: "app.nidget", category: "ai")

    init() {}

    // MARK: - Availability

    #if canImport(FoundationModels)

    /// Live availability, read straight from the framework each time. `SystemLanguageModel` is
    /// itself observable, so a view reading this in `body` re-renders when Apple Intelligence is
    /// turned on or the model finishes getting ready.
    var availability: FoundationModelAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                return .notEnabled
            case .modelNotReady:
                return .modelNotReady
            @unknown default:
                return .modelNotReady
            }
        @unknown default:
            return .modelNotReady
        }
    }

    #else

    /// Compiled against an SDK with no FoundationModels: the feature simply isn't there.
    var availability: FoundationModelAvailability { .frameworkUnavailable }

    #endif

    var isAvailable: Bool { availability == .available }

    /// One short line for the Intelligence screen. Says what to do, not what went wrong.
    var statusMessage: String {
        switch availability {
        case .available:
            return "Ready"
        case .deviceNotEligible:
            return "This iPhone does not support it"
        case .notEnabled:
            return "Turn on Apple Intelligence in Settings"
        case .modelNotReady:
            return "Still getting ready"
        case .frameworkUnavailable:
            return "Not available on this version of iOS"
        }
    }

    // MARK: - Generation

    #if canImport(FoundationModels)

    /// One-shot completion on Apple's on-device model. nil when the model is unavailable, the
    /// reply is empty, or anything at all throws (guardrails, context window, locale). Callers
    /// keep their existing non-AI answer in that case.
    func generate(system: String, user: String, temperature: Double) async -> String? {
        guard isAvailable else { return nil }
        do {
            // Fresh session per call: see the file note above.
            //
            // The session is built with no `instructions:` argument and the system prompt is
            // folded into the prompt text instead. That is deliberate caution, not preference:
            // the framework's instructions parameter may take an `@InstructionsBuilder` closure
            // rather than a plain String, and passing a String *variable* to a result-builder
            // parameter does not compile. CI is this project's only compile gate, so the
            // bare initializer (the framework's documented minimal form) is the safe shape.
            // Both prompts here are short and carry their own framing, so nothing is lost.
            // Moving the system half back into `instructions:` is a one-line change once a
            // green build has confirmed which initializer this SDK exposes.
            let session = LanguageModelSession()
            let prompt = system.isEmpty ? user : "\(system)\n\n\(user)"
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(temperature: temperature))
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            // Never above .debug with anything that could echo the prompt back (docs/AI.md §5).
            Self.log.notice("Apple on-device generation did not produce a reply")
            Self.log.debug("Apple generation error: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    #else

    func generate(system: String, user: String, temperature: Double) async -> String? {
        nil
    }

    #endif
}
