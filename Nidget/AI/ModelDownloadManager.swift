// Ported from HomeBoy (nphil/HomeBoy) — keep in sync deliberately, not automatically.
import Foundation
import Observation

/// Downloads GGUF model files to `Application Support/Models/{id}/model.gguf` with live
/// progress. Singleton so the manager, services, and the Intelligence screen all share one
/// source of truth. (HomeBoy stores under `Documents/models` and publishes via Combine;
/// Nidget uses Application Support — excluded from iCloud backup — and Observation.)
@MainActor @Observable
final class ModelDownloadManager {
    static let shared = ModelDownloadManager()

    enum DownloadState: Equatable {
        case notDownloaded
        case downloading(Double)   // 0...1; negative = size unknown
        case ready
        case failed(String)
    }

    private(set) var states: [String: DownloadState] = [:] {
        didSet {
            // Replaces HomeBoy's debounced Combine sink: notify only when a model's
            // lifecycle phase changes (not on every progress tick), so AIModelManager
            // can re-point the engines when a download finishes.
            if oldValue.mapValues(Self.phase) != states.mapValues(Self.phase) {
                onStatesChanged?()
            }
        }
    }

    /// Set by `AIModelManager` to reconfigure the engines when a model becomes ready
    /// (or is deleted). Called on the main actor.
    var onStatesChanged: (() -> Void)?

    private var downloaders: [String: Downloader] = [:]

    private init() {}

    func state(for id: String) -> DownloadState {
        if let s = states[id] { return s }
        return isReady(id) ? .ready : .notDownloaded
    }

    func isReady(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: Self.modelPath(id).path)
    }

    static func modelsDir() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base.appendingPathComponent("Models", isDirectory: true)
    }

    static func modelPath(_ id: String) -> URL {
        modelsDir().appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("model.gguf")
    }

    /// Creates the models directory and excludes it (and everything below) from iCloud
    /// backup — multi-hundred-MB GGUF files are always re-downloadable.
    private static func prepareModelsDir() {
        let fm = FileManager.default
        var dir = modelsDir()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    func download(_ spec: ModelSpec, hfToken: String?) {
        if case .downloading = state(for: spec.id) { return }
        if isReady(spec.id) { states[spec.id] = .ready; return }
        guard let url = spec.downloadURL else { states[spec.id] = .failed("Invalid URL"); return }

        Self.prepareModelsDir()
        states[spec.id] = .downloading(-1)
        let id = spec.id
        let dl = Downloader(
            url: url,
            destination: Self.modelPath(id),
            bearer: (hfToken?.isEmpty == false) ? hfToken : nil,
            onProgress: { [weak self] p in
                Task { @MainActor in
                    guard let self, let s = self.states[id], case .downloading = s else { return }
                    self.states[id] = .downloading(p)
                }
            },
            onComplete: { [weak self] result in
                Task { @MainActor in
                    self?.downloaders[id] = nil
                    switch result {
                    case .success:          self?.states[id] = .ready
                    case .cancelled:        self?.states[id] = .notDownloaded
                    case .failure(let msg): self?.states[id] = .failed(msg)
                    }
                }
            }
        )
        downloaders[id] = dl
        dl.start()
    }

    func cancel(_ id: String) {
        downloaders[id]?.cancel()
        downloaders[id] = nil
        states[id] = .notDownloaded
    }

    func delete(_ id: String) {
        cancel(id)
        try? FileManager.default.removeItem(
            at: Self.modelsDir().appendingPathComponent(id, isDirectory: true))
        states[id] = .notDownloaded
    }

    /// Lifecycle phase without associated values, for change detection above.
    private static func phase(_ state: DownloadState) -> Int {
        switch state {
        case .notDownloaded: return 0
        case .downloading:   return 1
        case .ready:         return 2
        case .failed:        return 3
        }
    }
}

/// One-shot URLSession download with progress + atomic move into place.
private final class Downloader: NSObject, URLSessionDownloadDelegate {
    enum Result { case success, cancelled, failure(String) }

    private let url: URL
    private let destination: URL
    private let bearer: String?
    private let onProgress: (Double) -> Void
    private let onComplete: (Result) -> Void
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var finished = false   // guard against double completion

    init(url: URL, destination: URL, bearer: String?,
         onProgress: @escaping (Double) -> Void,
         onComplete: @escaping (Result) -> Void) {
        self.url = url
        self.destination = destination
        self.bearer = bearer
        self.onProgress = onProgress
        self.onComplete = onComplete
        super.init()
    }

    func start() {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 60 * 60   // big files
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session = s
        var req = URLRequest(url: url)
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let t = s.downloadTask(with: req)
        task = t
        t.resume()
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
    }

    private func complete(_ r: Result) {
        guard !finished else { return }
        finished = true
        onComplete(r)
        session?.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { onProgress(-1); return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // `location` is removed once this returns — move synchronously.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            complete(.failure("HTTP \(http.statusCode)"))
            return
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: location, to: destination)
            complete(.success)
        } catch {
            complete(.failure(error.localizedDescription))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as NSError? else { return }  // success handled above
        complete(error.code == NSURLErrorCancelled ? .cancelled : .failure(error.localizedDescription))
    }
}
