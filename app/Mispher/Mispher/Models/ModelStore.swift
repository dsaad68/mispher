import CoreML
import FluidAudio
import Foundation

/// Single source of truth for on-disk model state: which FluidAudio bundles are
/// downloaded, how to download them (with progress), and how to delete them.
/// Centralizing the per-family cache paths and download APIs keeps the Settings
/// model manager and the engines in agreement.
///
/// Qwen is server-based (no download), so it is reported as `.downloaded` and is
/// skipped by `download`/`delete`.
enum ModelStore {
    /// `~/Library/Application Support/FluidAudio/Models` — FluidAudio's cache root.
    static var cacheRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    // MARK: - Presence

    static func isDownloaded(_ model: AsrModel) -> Bool {
        switch model {
        case .qwenChinese:
            return true // server-based; not a downloadable bundle
        case .parakeetEouEnglish:
            // EOU nests under parakeet-eou-streaming/<repo>/<chunk>ms; just look
            // for any compiled bundle in the tree rather than guess the subpath.
            return containsModelBundle(under: cacheRoot.appendingPathComponent("parakeet-eou-streaming"))
        case .nemotronMultilingual:
            // "auto" routes to the full-vocab `multilingual` build.
            let metadata = cacheRoot
                .appendingPathComponent("nemotron-multilingual/multilingual")
                .appendingPathComponent("\(NemotronMultilingualEngine.chunkMs)ms")
                .appendingPathComponent("metadata.json")
            return FileManager.default.fileExists(atPath: metadata.path)
        case .parakeetTdtV3:
            return AsrModels.modelsExist(
                at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3
            )
        case .parakeetCtcInt8, .parakeetCtcFp32:
            // Both precisions live in one bundle (downloaded together).
            return CtcZhCnModels.modelsExist(at: CtcZhCnModels.defaultCacheDirectory())
        }
    }

    // MARK: - Download

    static func download(
        _ model: AsrModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let handler: DownloadUtils.ProgressHandler = { p in progress(p.fractionCompleted) }

        switch model {
        case .qwenChinese:
            return // nothing to download
        case .parakeetEouEnglish:
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let manager = StreamingEouAsrManager(
                configuration: config, chunkSize: .ms160, eouDebounceMs: 1280
            )
            try await manager.loadModels(to: nil, configuration: nil) { p in
                progress(p.fractionCompleted)
            }
        case .nemotronMultilingual:
            _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                languageCode: NemotronMultilingualEngine.downloadLanguage,
                chunkMs: NemotronMultilingualEngine.chunkMs,
                progressHandler: handler
            )
        case .parakeetTdtV3:
            _ = try await AsrModels.download(
                version: .v3, encoderPrecision: .int8, progressHandler: handler
            )
        case .parakeetCtcInt8, .parakeetCtcFp32:
            // One bundle carries both encoders, so either row fetches both precisions.
            _ = try await CtcZhCnModels.download(
                useInt8Encoder: true, downloadBothEncoders: true, progressHandler: handler
            )
        }
    }

    // MARK: - Delete

    static func delete(_ model: AsrModel) throws {
        let directory: URL?
        switch model {
        case .qwenChinese:
            directory = nil
        case .parakeetEouEnglish:
            directory = cacheRoot.appendingPathComponent("parakeet-eou-streaming")
        case .nemotronMultilingual:
            directory = cacheRoot.appendingPathComponent("nemotron-multilingual")
        case .parakeetTdtV3:
            directory = AsrModels.defaultCacheDirectory(for: .v3)
        case .parakeetCtcInt8, .parakeetCtcFp32:
            directory = CtcZhCnModels.defaultCacheDirectory()
        }

        guard let directory else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) {
            try fm.removeItem(at: directory)
        }
    }

    // MARK: - Private

    /// Recursively checks whether any compiled `.mlmodelc` bundle exists under a
    /// directory — robust to FluidAudio's nested cache layouts.
    private static func containsModelBundle(under url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let enumerator = fm.enumerator(
                  at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              )
        else { return false }
        for case let item as URL in enumerator where item.pathExtension == "mlmodelc" {
            return true
        }
        return false
    }
}
