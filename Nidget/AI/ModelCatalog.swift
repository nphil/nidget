// Ported from HomeBoy (nphil/HomeBoy) — keep in sync deliberately, not automatically.
import Foundation

/// What an on-device GGUF model is used for.
enum ModelPurpose: String, Codable, Sendable {
    case embedding   // semantic search (nomic / BGE)
    case generation  // category suggestions (Qwen3 / Llama)
}

/// A downloadable GGUF model. Built-ins live in `ModelCatalog.builtIn`; user-added
/// ones (via the Hugging Face browser) are persisted as custom specs.
struct ModelSpec: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let displayName: String
    let detail: String
    let purpose: ModelPurpose
    let approxBytes: Int64
    let repo: String        // Hugging Face repo, e.g. "nomic-ai/nomic-embed-text-v1.5-GGUF"
    let fileName: String    // GGUF file within the repo
    var isCustom: Bool = false

    /// Hugging Face direct-download URL (same scheme as the Android client).
    var downloadURL: URL? {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(fileName)")
    }

    var approxSizeText: String {
        ByteCountFormatter.string(fromByteCount: approxBytes, countStyle: .file)
    }
}

enum ModelCatalog {
    /// No bundled recommendations — models are added by the user via the Hugging Face
    /// browser (based on their own benchmarking). All on-device models are "custom".
    static let builtIn: [ModelSpec] = []

    static func builtIn(_ purpose: ModelPurpose) -> [ModelSpec] {
        builtIn.filter { $0.purpose == purpose }
    }

    static func spec(id: String, customs: [ModelSpec]) -> ModelSpec? {
        customs.first { $0.id == id }
    }
}
