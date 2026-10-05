import Foundation
import AVFoundation

/// 本机加密音乐库：扫描「本地音乐」目录、按需解密到缓存、生成可播放的 Song。
///
/// 目录结构（位于 App 沙盒 Documents/BeansMusic/，开启文件共享后可手动放入文件）：
///   Documents/BeansMusic/            用户放置加密音乐文件（.ncm/.kgm/.vpr/.mflac/.mgg）
///   Caches/BeansDecrypted/           解密后的临时音频（播放时生成，可随时清理）
@MainActor
final class LocalAudioLibrary: ObservableObject {
    static let shared = LocalAudioLibrary()

    /// 目录内扫描出的本机歌曲（只反映加密文件本身，不包含解密产物）。
    @Published private(set) var songs: [Song] = []
    /// 是否正在扫描/解密。
    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?

    private let fileManager = FileManager.default
    private var didInitialScan = false

    private init() {}

    // MARK: 目录

    /// 用户放置加密音乐的目录。
    var musicDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("BeansMusic", isDirectory: true)
    }

    /// 解密产物缓存目录。
    var decryptedCacheDirectory: URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("BeansDecrypted", isDirectory: true)
    }

    /// 确保目录存在，返回音乐目录。
    @discardableResult
    func ensureDirectories() -> URL {
        try? fileManager.createDirectory(at: musicDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: decryptedCacheDirectory, withIntermediateDirectories: true)
        return musicDirectory
    }

    // MARK: 扫描

    /// 扫描「本地音乐」目录，构建 Song 列表。启动时自动调用一次。
    func scan() {
        lastError = nil
        let dir = ensureDirectories()
        let contents = (try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var result: [Song] = []
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard EncryptedAudioFormat.isEncryptedFile(url) else { continue }
            result.append(makeSong(for: url))
        }
        songs = result
        didInitialScan = true
        BeansLogger.shared.log("本地音乐扫描完成：\(result.count) 首（目录 \(dir.path)）", level: .info)
    }

    /// 首次访问时懒加载扫描（供 UI 调用，避免重复扫描）。
    func scanIfNeeded() {
        guard !didInitialScan else { return }
        scan()
    }

    /// 目录变化（导入/删除文件）后调用，刷新列表并清理失效缓存。
    func refresh() {
        cleanupOrphanedCache()
        scan()
    }

    /// 播放时探测到真实时长后回写到列表（不持久化，仅内存展示）。
    func updateDuration(song: Song, duration: TimeInterval) {
        guard duration > 0, duration.isFinite else { return }
        guard let idx = songs.firstIndex(where: { $0.identityKey == song.identityKey }) else { return }
        guard abs(songs[idx].duration - duration) > 1 else { return }
        let old = songs[idx]
        songs[idx] = Song(
            id: old.id,
            name: old.name,
            artists: old.artists,
            album: old.album,
            coverURL: old.coverURL,
            duration: duration,
            source: .local,
            fee: 0,
            localFileName: old.localFileName
        )
    }

    /// 由加密文件构造一个 `.local` 来源的 Song。
    private func makeSong(for url: URL) -> Song {
        let fileName = url.lastPathComponent
        let baseName = url.deletingPathExtension().lastPathComponent
        // 尝试从文件名解析「歌名 - 歌手」。
        let (name, artist) = Self.parseNameAndArtist(baseName)
        let id = abs(fileName.hashValue)
        return Song(
            id: id,
            name: name,
            artists: artist,
            album: "本地音乐",
            coverURL: nil,
            duration: 0,
            source: .local,
            fee: 0,
            localFileName: fileName
        )
    }

    /// 解析「歌名 - 歌手」「歌名_歌手」「歌名」等常见命名。
    static func parseNameAndArtist(_ raw: String) -> (String, String) {
        for separator in [" - ", " — ", "-", "_", "–"] {
            if let range = raw.range(of: separator) {
                let name = String(raw[raw.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let artist = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !artist.isEmpty {
                    return (name, artist)
                }
            }
        }
        return (raw, beansLocalized("未知歌手", "Unknown Artist"))
    }

    // MARK: 解密

    /// 取得某首本地歌曲可直接交给 AVPlayer 的文件 URL。
    ///
    /// 播放时才会调用：若缓存已存在则直接复用，否则解密后写入缓存。
    /// - 调用方应放在后台线程执行（本方法内部同步解密，可能较慢）。
    func playableURL(for song: Song) throws -> URL {
        try Self.playableURL(for: song, musicDir: musicDirectory, cacheDir: decryptedCacheDirectory)
    }

    /// 与实例无关的解密入口：可安全地从任意线程（含 detached task）调用。
    ///
    /// 不依赖 `shared`（`shared` 是 `@MainActor` 隔离的），因此不会产生跨 actor 访问报错。
    nonisolated static func playableURL(for song: Song, musicDir: URL, cacheDir: URL) throws -> URL {
        guard song.source == .local, let fileName = song.localFileName else {
            throw EncryptedAudioError.malformed("非本地歌曲")
        }
        let sourceURL = musicDir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw EncryptedAudioError.malformed("文件不存在：\(fileName)")
        }

        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let ext = EncryptedAudioDecryptor.decryptedExtension(for: sourceURL)
        let outURL = cacheDir.appendingPathComponent("\(abs(fileName.hashValue)).\(ext)")

        // 缓存命中：源文件较新则直接用。
        if let outAttrs = try? FileManager.default.attributesOfItem(atPath: outURL.path),
           let srcAttrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
           let outDate = outAttrs[.modificationDate] as? Date,
           let srcDate = srcAttrs[.modificationDate] as? Date,
           outDate >= srcDate {
            return outURL
        }

        // 解密并落盘。
        let data = try EncryptedAudioDecryptor.decrypt(fileAt: sourceURL)
        try? FileManager.default.removeItem(at: outURL)
        try data.write(to: outURL, options: .atomic)
        BeansLogger.shared.log("本地音乐解密完成：\(fileName) → \(outURL.lastPathComponent)（\(data.count) 字节）", level: .info)
        return outURL
    }

    /// 供后台线程调用的便捷解密入口（读取默认目录，不触碰实例状态）。
    nonisolated static func decryptToCache(song: Song) throws -> URL {
        try playableURL(
            for: song,
            musicDir: musicDirectoryStatic(),
            cacheDir: decryptedCacheDirectoryStatic()
        )
    }

    // MARK: 删除 / 清理

    /// 删除本机加密文件及其缓存。
    func remove(song: Song) {
        guard song.source == .local, let fileName = song.localFileName else { return }
        let sourceURL = musicDirectory.appendingPathComponent(fileName)
        try? fileManager.removeItem(at: sourceURL)
        let cacheURL = decryptedCacheDirectory.appendingPathComponent("\(abs(fileName.hashValue))")
        // 缓存文件名带扩展名，按前缀删除。
        if let entries = try? fileManager.contentsOfDirectory(at: decryptedCacheDirectory, includingPropertiesForKeys: nil) {
            for entry in entries where entry.deletingPathExtension().lastPathComponent == String(abs(fileName.hashValue)) {
                try? fileManager.removeItem(at: entry)
            }
        }
        _ = cacheURL
        refresh()
    }

    /// 清空所有解密缓存（不删原始加密文件）。
    func clearDecryptedCache() {
        try? fileManager.removeItem(at: decryptedCacheDirectory)
        try? fileManager.createDirectory(at: decryptedCacheDirectory, withIntermediateDirectories: true)
        BeansLogger.shared.log("已清空本地音乐解密缓存", level: .info)
    }

    /// 删除缓存目录中已无对应源文件的孤儿缓存。
    private func cleanupOrphanedCache() {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: decryptedCacheDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        let validHashes = Set(songs.compactMap { song -> String? in
            guard let name = song.localFileName else { return nil }
            return String(abs(name.hashValue))
        })
        for entry in entries where !validHashes.contains(entry.deletingPathExtension().lastPathComponent) {
            try? fileManager.removeItem(at: entry)
        }
    }

    // MARK: 静态路径（供 nonisolated 方法使用）

    nonisolated static func musicDirectoryStatic() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeansMusic", isDirectory: true)
    }

    nonisolated static func decryptedCacheDirectoryStatic() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeansDecrypted", isDirectory: true)
    }
}
