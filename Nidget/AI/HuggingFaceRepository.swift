// Ported from HomeBoy (nphil/HomeBoy) — keep in sync deliberately, not automatically.
import Foundation

/// A model returned by the Hugging Face search API.
struct HFModel: Codable, Identifiable, Sendable {
    let id: String                 // "bartowski/Qwen_Qwen3-1.7B-GGUF"
    let downloads: Int?
    let likes: Int?

    var author: String { id.split(separator: "/").first.map(String.init) ?? "" }
    var name: String { id.split(separator: "/").last.map(String.init) ?? id }
}

/// A file entry in a repo's tree.
struct HFTreeEntry: Codable, Sendable, Identifiable {
    let path: String
    let size: Int64?
    var id: String { path }

    var sizeText: String? {
        size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}

/// Sort order for Hugging Face model search.
enum HFSort: String, CaseIterable, Identifiable, Sendable {
    case downloads, trending, recent, likes
    var id: String { rawValue }
    var label: String {
        switch self {
        case .downloads: return "Downloads"
        case .trending:  return "Trending"
        case .recent:    return "New"
        case .likes:     return "Likes"
        }
    }
    var apiValue: String {
        switch self {
        case .downloads: return "downloads"
        case .trending:  return "trendingScore"
        case .recent:    return "lastModified"
        case .likes:     return "likes"
        }
    }
}

/// On-device compatibility verdict for a GGUF repo (iOS / Metal wording).
struct GGUFCompatibility: Sendable {
    let runnable: Bool
    let backend: String?    // "GPU (Metal)" / "CPU"
    let warning: String?
}

/// Lightweight Hugging Face client: search, file listing, model card, and an
/// iOS-flavoured GGUF compatibility classifier. Stateless apart from an optional token.
struct HuggingFaceRepository: Sendable {
    var token: String?

    // MARK: Search

    func search(_ query: String, purpose: ModelPurpose, sort: HFSort = .downloads) async -> [HFModel] {
        guard var comps = URLComponents(string: "https://huggingface.co/api/models") else { return [] }
        let q = query.trimmingCharacters(in: .whitespaces)
        comps.queryItems = [
            URLQueryItem(name: "search", value: q.isEmpty ? defaultQuery(purpose) : q),
            URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "sort", value: sort.apiValue),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "30"),
        ]
        guard let url = comps.url, let data = try? await get(url) else { return [] }
        return (try? JSONDecoder().decode([HFModel].self, from: data)) ?? []
    }

    /// Smallest GGUF file size in a repo (files() is sorted ascending). For the size badge.
    func smallestGGUFSize(_ repoId: String) async -> Int64? {
        await files(repoId).first?.size
    }

    private func defaultQuery(_ purpose: ModelPurpose) -> String {
        purpose == .embedding ? "embedding" : "instruct"
    }

    // MARK: Files

    /// GGUF files in a repo, with sizes.
    func files(_ repoId: String) async -> [HFTreeEntry] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoId)/tree/main?recursive=true"),
              let data = try? await get(url) else { return [] }
        let all = (try? JSONDecoder().decode([HFTreeEntry].self, from: data)) ?? []
        return all.filter {
            let p = $0.path.lowercased()
            // Exclude mmproj projectors (multimodal vision/audio adapters, not the LLM itself).
            return p.hasSuffix(".gguf") && !p.contains("mmproj")
        }
        .sorted { ($0.size ?? 0) < ($1.size ?? 0) }
    }

    // MARK: Model card

    func modelCard(_ repoId: String) async -> String? {
        guard let url = URL(string: "https://huggingface.co/\(repoId)/raw/main/README.md"),
              let data = try? await get(url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return stripFrontmatter(text)
    }

    // MARK: Compatibility classifier (iOS)

    /// Any standard-architecture GGUF runs on iPhone via Metal (GPU) or CPU — there's
    /// no Q4_0-only NPU constraint like Android. We only warn about exotic architectures
    /// and models too large for comfortable on-device use.
    static func classify(repoId: String, fileNames: [String]) -> GGUFCompatibility {
        let hasGGUF = fileNames.contains { $0.lowercased().hasSuffix(".gguf") }
        guard hasGGUF else {
            return GGUFCompatibility(runnable: false, backend: nil, warning: "No GGUF file in this repo.")
        }
        let hay = (repoId + " " + fileNames.joined(separator: " ")).lowercased()
        // Gemma 3n (E2B/E4B) is a multimodal/MatFormer arch whose context fails to init on
        // the bundled engine ("requires ctx_other"). Steer users to standard text models.
        let gemma3n = ["gemma-3n", "gemma3n", "-e2b", "-e4b", " e2b", " e4b"]
        let exotic = ["mamba", "rwkv", "deltanet", "jamba", "ssm", "recurrentgemma", "griffin"]
        let large = ["70b", "72b", "65b", "34b", "32b", "30b", "27b", "20b", "14b", "13b", "9b", "8b", "7b"]

        var warning: String?
        if gemma3n.contains(where: { hay.contains($0) }) {
            warning = "Gemma 3n (E2B/E4B) won’t run on the bundled engine. Use a standard instruct model (Qwen, Llama, Gemma 2, Phi)."
        } else if exotic.contains(where: { hay.contains($0) }) {
            warning = "Unusual architecture — llama.cpp may run it slowly on CPU, or not at all."
        } else if large.contains(where: { hay.contains($0) }) {
            warning = "Large model — heavy memory use on iPhone; a 0.5–2B model is recommended."
        }
        return GGUFCompatibility(runnable: true, backend: "GPU (Metal)", warning: warning)
    }

    /// Classify a search result by repo id alone (search is already filtered to GGUF repos).
    static func classifyRepo(_ repoId: String) -> GGUFCompatibility {
        classify(repoId: repoId, fileNames: ["model.gguf"])
    }

    /// Build a custom `ModelSpec` from a chosen repo + file. The id is stable across
    /// launches (derived from the path) so the download location is consistent.
    static func customSpec(repoId: String, file: HFTreeEntry, purpose: ModelPurpose) -> ModelSpec {
        let prefix = purpose == .embedding ? "custom-" : "customgen-"
        let safe = (repoId + "-" + file.path)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        let name = repoId.split(separator: "/").last.map(String.init) ?? repoId
        return ModelSpec(
            id: prefix + safe,
            displayName: name,
            detail: file.sizeText ?? "Custom model",
            purpose: purpose,
            approxBytes: file.size ?? 0,
            repo: repoId,
            fileName: file.path,
            isCustom: true
        )
    }

    // MARK: Helpers

    private func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func stripFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        // Drop the leading YAML frontmatter block (--- ... ---).
        let lines = text.components(separatedBy: "\n")
        var idx = 1
        while idx < lines.count, lines[idx].trimmingCharacters(in: .whitespaces) != "---" { idx += 1 }
        if idx < lines.count { return lines[(idx + 1)...].joined(separator: "\n") }
        return text
    }
}
