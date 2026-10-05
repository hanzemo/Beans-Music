import Foundation
import AVFoundation

/// 本机音乐库：扫描「本地音乐」目录、按需解密到缓存、生成可播放的 Song。
///
/// 目录结构（位于 App 沙盒 Documents/BeansMusic/，开启文件共享后可手动放入文件）：
///   Documents/BeansMusic/            用户放置音频文件
///   Caches/BeansDecrypted/           解密后的临时音频（播放时生成，可随时清理）
///
/// 支持的文件类型：
///   加密：.ncm / .kgm / .vpr / .mflac / .mgg / .mflac0
///   明文：.mp3 / .m4a / .wav / .flac / .aac / .ogg / .opus
///
/// 文件名可含平台 ID（例如 "320000-1456890009"、"1456890009 - 320000"、"320000"），
/// 用于日后与网易云等平台 API 同步封面/歌词。
@MainActor
final class LocalAudioLibrary: ObservableObject {
    static let shared = LocalAudioLibrary()

    /// 目录内扫描出的本机歌曲。
    @Published private(set) var songs: [Song] = []
    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?

    private let fileManager = FileManager.default
    private var didInitialScan = false

    private init() {}

    // MARK: 目录

    var musicDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("BeansMusic", isDirectory: true)
    }

    var decryptedCacheDirectory: URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("BeansDecrypted", isDirectory: true)
    }

    @discardableResult
    func ensureDirectories() -> URL {
        try? fileManager.createDirectory(at: musicDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: decryptedCacheDirectory, withIntermediateDirectories: true)
        return musicDirectory
    }

    // MARK: 扩展名分类

    /// 明文音频扩展名（App 直接播放，不解密）。
    static let plainAudioExtensions: Set<String> = [
        "mp3", "m4a", "wav", "flac", "aac", "ogg", "opus", "aiff", "caf"
    ]

    static func isAcceptedAudioFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return EncryptedAudioFormat.isEncryptedFile(url)
            || plainAudioExtensions.contains(ext)
    }

    // MARK: 文件名解析

    /// 从文件名解析平台 ID（例如 "1456890009"）。
    /// 规则：取所有 6 位以上连续数字中最像平台 ID 的那一个（优先最长、其次首次出现）。
    static func parsePlatformID(fromName name: String) -> String? {
        var best: (id: String, len: Int, idx: Int)?
        var idx = 0
        var cur = ""
        for ch in name {
            if ch.isNumber {
                cur.append(ch)
            } else {
                if cur.count >= 6 {
                    let len = cur.count
                    if best == nil || len > best!.len || (len == best!.len && idx < best!.idx) {
                        best = (cur, len, idx)
                    }
                }
                cur = ""
            }
            idx += 1
        }
        if cur.count >= 6 {
            let len = cur.count
            if best == nil || len > best!.len || (len == best!.len && idx < best!.idx) {
                best = (cur, len, idx)
            }
        }
        return best?.id
    }

    /// 从文件名解析曲名 / 歌手。
    static func parseNameAndArtist(_ raw: String) -> (name: String, artist: String, cleanedBase: String) {
        var s = stripNumericIDs(raw)
        let qualityTags = ["320000", "128000", "320k", "128k", "999999", "flac", "mp3", "ogg", "wav", "m4a", "aac", "lossless", "无损", "超清"]
        for tag in qualityTags {
            s = s.replacingOccurrences(of: tag, with: " ", options: [.caseInsensitive])
        }
        for sep in [" - ", " — ", "–", "-", "_", "|", "/"] {
            s = s.replacingOccurrences(of: sep, with: " ")
        }
        s = s
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        s = s.trimmingCharacters(in: .whitespaces)

        if s.isEmpty {
            return (raw, beansLocalized("未知歌手", "Unknown Artist"), s)
        }
        return (s, beansLocalized("未知歌手", "Unknown Artist"), s)
    }

    /// 剔除 3-6 位连续数字块（视为平台 ID 或质量码）。
    private static func stripNumericIDs(_ s: String) -> String {
        var result = ""
        var cur = ""
        var curLen = 0
        for ch in s {
            if ch.isNumber {
                cur.append(ch)
                curLen += 1
            } else {
                if !(curLen >= 3 && curLen <= 6), !cur.isEmpty {
                    result += cur
                }
                result.append(ch)
                cur = ""
                curLen = 0
            }
        }
        if !(curLen >= 3 && curLen <= 6), !cur.isEmpty {
            result += cur
        }
        return result
    }

    // MARK: 扫描

    /// 扫描本地音乐目录。会分派到后台线程做 ncm 元数据解析，避免主线程卡顿。
    /// 扫描本地音乐目录。ncm 元数据在后台线程解析，避免主线程卡顿。
    func scan() {
        lastError = nil
        isWorking = true
        let dir = ensureDirectories()
        let contents = (try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let urls = contents
            .filter { Self.isAcceptedAudioFile($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        Task.detached(priority: .utility) { [weak self, urls] in
            var metaCache: [URL: NCMFileInfo] = [:]
            for url in urls where url.pathExtension.lowercased() == "ncm" {
                if let info = EncryptedAudioDecryptor.parseNCMMeta(at: url) {
                    metaCache[url] = info
                }
            }
            let localMeta = metaCache
            await MainActor.run {
                guard let self else { return }
                var result: [Song] = []
                for url in urls {
                    result.append(self.makeSong(for: url, ncmMeta: localMeta[url]))
                }
                self.songs = result
                self.isWorking = false
                self.didInitialScan = true
                BeansLogger.shared.log("本地音乐扫描完成：\(result.count) 首（目录 \(dir.path)）", level: .info)

                Task.detached(priority: .utility) { [weak self] in
                    guard let self else { return }
                    for song in result {
                        guard let nid = song.linkedNeteaseID else { continue }
                        do {
                            guard let detail = try await NetEaseAPI.shared.songDetail(id: nid) else { continue }
                            await MainActor.run {
                                guard let idx = self.songs.firstIndex(where: {
                                    $0.localFileName == song.localFileName
                                }) else { return }
                                self.songs[idx] = self.songs[idx].merging(netease: detail)
                            }
                        } catch {
                            BeansLogger.shared.log("本地歌元数据补全失败：\(song.localFileName ?? "?") - \(error)", level: .warn)
                        }
                    }
                }
            }
        }
    }

    func scanIfNeeded() {
        guard !didInitialScan else { return }
        scan()
    }

    func refresh() {
        cleanupOrphanedCache()
        scan()
    }

    /// 播放时探测到真实时长后回写到列表（仅内存）。
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
            localFileName: old.localFileName,
            linkedNeteaseID: old.linkedNeteaseID
        )
    }

    // MARK: 构造 Song

    private func makeSong(for url: URL, ncmMeta: NCMFileInfo?) -> Song {
        let fileName = url.lastPathComponent
        let baseName = url.deletingPathExtension().lastPathComponent
        let isEncrypted = EncryptedAudioFormat.isEncryptedFile(url)
        let ext = url.pathExtension.lowercased()

        let platformID = Self.parsePlatformID(fromName: fileName)
        let linkedID = platformID.flatMap { Int($0) }

        // ncm 优先从内嵌元数据回填真实歌名/歌手/时长/专辑
        if isEncrypted, ext == "ncm", let info = ncmMeta, !info.name.isEmpty {
            return Song(
                id: platformID.map { Int($0) ?? abs(fileName.hashValue) } ?? abs(fileName.hashValue),
                name: info.name,
                artists: info.artists.isEmpty ? beansLocalized("未知歌手", "Unknown Artist") : info.artists,
                album: info.album.isEmpty ? "本地音乐" : info.album,
                coverURL: nil,
                duration: Double(info.duration) / 1000.0,
                source: .local,
                fee: 0,
                localFileName: fileName,
                linkedNeteaseID: linkedID
            )
        }

        let parsed = Self.parseNameAndArtist(baseName)
        return Song(
            id: platformID.map { Int($0) ?? abs(fileName.hashValue) } ?? abs(fileName.hashValue),
            name: parsed.name.isEmpty ? baseName : parsed.name,
            artists: parsed.artist,
            album: "本地音乐",
            coverURL: nil,
            duration: 0,
            source: .local,
            fee: 0,
            localFileName: fileName,
            linkedNeteaseID: linkedID
        )
    }

    // MARK: 播放

    /// 取得某首本地歌曲可直接交给 AVPlayer 的文件 URL。
    /// 加密文件解密到缓存后返回；明文文件直接返回原路径。
    func playableURL(for song: Song) throws -> URL {
        try Self.playableURL(
            for: song,
            musicDir: musicDirectory,
            cacheDir: decryptedCacheDirectory
        )
    }

    /// 解密算法版本前缀：任何影响输出字节的解密逻辑改动都要 +1，
    /// 强制新包绕过旧缓存，避免"改了代码但缓存文件还是坏的"这种情况。
    static let decryptCacheVersion = "v2"

    /// 与实例无关的解密入口：可安全地从任意线程（含 detached task）调用。
    nonisolated static func playableURL(for song: Song, musicDir: URL, cacheDir: URL) throws -> URL {
        guard song.source == .local, let fileName = song.localFileName else {
            throw EncryptedAudioError.malformed("非本地歌曲")
        }
        let sourceURL = musicDir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw EncryptedAudioError.malformed("文件不存在：\(fileName)")
        }

        // 明文音频文件：直接返回原路径。
        let ext = sourceURL.pathExtension.lowercased()
        guard EncryptedAudioFormat.from(fileExtension: ext) != nil else {
            return sourceURL
        }

        // 加密文件：解密到缓存。
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let outExt = EncryptedAudioDecryptor.decryptedExtension(for: sourceURL)
        let hash = stableHash(fileName)
        let outURL = cacheDir.appendingPathComponent("\(beansDecryptCacheVersion)_\(hash).\(outExt)")

        if let outAttrs = try? FileManager.default.attributesOfItem(atPath: outURL.path),
           let srcAttrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
           let outDate = outAttrs[.modificationDate] as? Date,
           let srcDate = srcAttrs[.modificationDate] as? Date,
           outDate >= srcDate {
            return outURL
        }

        let data = try EncryptedAudioDecryptor.decrypt(fileAt: sourceURL)
        // 校验解密结果是否包含合理的音频签名（ID3 / fLaC / OggS / MP3 帧头），
        // 便于诊断解密是否正确。签名无效但文件仍会写出，方便用户回包排查。
        let sig = [UInt8](data.prefix(4))
        let hasValidSig = (sig.count >= 3 && sig[0] == 0x49 && sig[1] == 0x44 && sig[2] == 0x33)  // ID3
            || (sig.count >= 4 && sig[0] == 0x66 && sig[1] == 0x4C && sig[2] == 0x61 && sig[3] == 0x43)  // fLaC
            || (sig.count >= 4 && sig[0] == 0x4F && sig[1] == 0x67 && sig[2] == 0x67 && sig[3] == 0x53)  // OggS
            || (sig.count >= 2 && sig[0] == 0xFF && (sig[1] & 0xE0) == 0xE0)  // MP3 帧
        let sigHex = sig.prefix(8).map { String(format: "%02x", $0) }.joined()
        BeansLogger.shared.log(
            "本地音乐解密完成：\(fileName) → \(outURL.lastPathComponent)（\(data.count) 字节｜签名有效=\(hasValidSig)｜前8B=\(sigHex)）",
            level: .info
        )
        if !hasValidSig {
            BeansLogger.shared.log("⚠️ 解密产物缺少音频签名，可能是解密失败（文件仍写出，供排查）", level: .error)
        }
        try? FileManager.default.removeItem(at: outURL)
        try data.write(to: outURL, options: .atomic)
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

    /// 稳定 hash（跨运行一致，避免 Swift hashValue 每次运行都变化）。
    nonisolated static func stableHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    // MARK: 删除 / 清理

    func remove(song: Song) {
        guard song.source == .local, let fileName = song.localFileName else { return }
        let sourceURL = musicDirectory.appendingPathComponent(fileName)
        try? fileManager.removeItem(at: sourceURL)
        deleteCache(forFileName: fileName)
        refresh()
    }

    func clearDecryptedCache() {
        try? fileManager.removeItem(at: decryptedCacheDirectory)
        try? fileManager.createDirectory(at: decryptedCacheDirectory, withIntermediateDirectories: true)
        BeansLogger.shared.log("已清空本地音乐解密缓存", level: .info)
    }

    private func deleteCache(forFileName fileName: String) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: decryptedCacheDirectory, includingPropertiesForKeys: nil
        ) else { return }
        let hash = Self.stableHash(fileName)
        for entry in entries {
            let stem = entry.deletingPathExtension().lastPathComponent
            // 匹配 v2_hash 或旧版 hash（不带版本前缀）
            if stem == hash || stem == "\(beansDecryptCacheVersion)_\(hash)" {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    private func cleanupOrphanedCache() {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: decryptedCacheDirectory, includingPropertiesForKeys: nil
        ) else { return }
        let validHashes = Set(songs.compactMap { song -> String? in
            guard let name = song.localFileName else { return nil }
            return Self.stableHash(name)
        })
        for entry in entries {
            let stem = entry.deletingPathExtension().lastPathComponent
            // 去掉 vN_ 前缀后再比对 hash
            let baseHash = stem.hasPrefix(beansDecryptCacheVersion + "_")
                ? String(stem.dropFirst(beansDecryptCacheVersion.count + 1))
                : stem
            if !validHashes.contains(baseHash) {
                try? fileManager.removeItem(at: entry)
            }
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
