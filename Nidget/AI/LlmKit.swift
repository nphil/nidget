// Ported from HomeBoy (nphil/HomeBoy) — keep in sync deliberately, not automatically.
import Foundation

/// Execution backend for llama.cpp on iOS. There is **no NPU** path — llama.cpp runs
/// on the Metal GPU or the CPU (the Neural Engine is reachable only via Apple frameworks).
enum LlamaBackend: String, CaseIterable, Identifiable, Sendable {
    case auto   // prefer Metal GPU
    case gpu
    case cpu

    var id: String { rawValue }
    var gpuLayers: Int32 { self == .cpu ? 0 : 99 }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .gpu:  return "GPU (Metal)"
        case .cpu:  return "CPU"
        }
    }
}

/// Live status of an on-device engine, surfaced to the Intelligence screen.
struct EngineStatus: Sendable, Equatable {
    var modelId: String?            // which model is (or was) loaded
    var loaded = false              // resident in memory right now
    var backend: LlamaBackend?      // backend engaged while loaded
    var lastBackend: LlamaBackend?  // last backend used (shown after unload: "was on GPU")
    var unloadAt: Date?             // when it will auto-unload (for the countdown)
}

/// Swift facade over the Objective-C++ `LlamaBridge`. Handles are opaque `UInt64`
/// values; the caller owns the lifecycle (load → use → free). Every call blocks, so
/// invoke from an actor/background task, never the main thread.
enum LlmKit {
    static func probeBackends() -> [String] {
        LlamaBridge.initBackend()
        return LlamaBridge.probeBackends()
    }

    /// Load a GGUF model. Returns a non-zero handle, or nil on failure.
    static func loadModel(path: String, embeddings: Bool, backend: LlamaBackend) -> UInt64? {
        LlamaBridge.initBackend()
        let h = LlamaBridge.loadModel(atPath: path, embeddings: embeddings, gpuLayers: backend.gpuLayers)
        return h == 0 ? nil : h
    }

    static func generate(_ handle: UInt64, prompt: String,
                         maxTokens: Int32 = 128, temperature: Float = 0.7, topK: Int32 = 40) -> String {
        LlamaBridge.generate(withHandle: handle, prompt: prompt,
                             maxTokens: maxTokens, temperature: temperature, topK: topK)
    }

    static func chat(_ handle: UInt64, system: String, user: String,
                     maxTokens: Int32 = 128, temperature: Float = 0.4, topK: Int32 = 20) -> String {
        LlamaBridge.chat(withHandle: handle, system: system, user: user,
                         maxTokens: maxTokens, temperature: temperature, topK: topK)
    }

    static func embed(_ handle: UInt64, text: String) -> [Float] {
        LlamaBridge.embed(withHandle: handle, text: text).map { $0.floatValue }
    }

    struct ChatBenchmark: Sendable {
        let text: String
        let promptTokens: Int
        let genTokens: Int
        let prefillMs: Double
        let genMs: Double
        var tokensPerSec: Double { genMs > 0 ? Double(genTokens) / (genMs / 1000.0) : 0 }
    }

    static func chatBenchmark(_ handle: UInt64, system: String, user: String,
                              maxTokens: Int32 = 96, temperature: Float = 0.4, topK: Int32 = 20) -> ChatBenchmark {
        let d = LlamaBridge.benchmarkChat(withHandle: handle, system: system, user: user,
                                          maxTokens: maxTokens, temperature: temperature, topK: topK)
        return ChatBenchmark(
            text: d["text"] as? String ?? "",
            promptTokens: (d["promptTokens"] as? NSNumber)?.intValue ?? 0,
            genTokens: (d["genTokens"] as? NSNumber)?.intValue ?? 0,
            prefillMs: (d["prefillMs"] as? NSNumber)?.doubleValue ?? 0,
            genMs: (d["genMs"] as? NSNumber)?.doubleValue ?? 0
        )
    }

    static func free(_ handle: UInt64) {
        LlamaBridge.freeHandle(handle)
    }

    static func clearLog() { LlamaBridge.clearLog() }
    static func recentLog() -> String { LlamaBridge.recentLog() }
}
