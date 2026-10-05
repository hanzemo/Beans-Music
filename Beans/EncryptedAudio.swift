import Foundation

// MARK: - 加密音乐格式
//
// 支持三类主流平台的加密下载文件：
//   .ncm  —— 网易云音乐（网易云会员下载专用）
//   .kgm / .vpr —— 酷狗音乐
//   .mflac / .mgg / .mflac0 —— QQ 音乐
//
// 这些文件在播放时才解密：解密结果写入 App 私有缓存目录，再交给 AVPlayer。
// 原始加密文件始终保留在原目录，不做转换、不修改。
//
// 参考实现：taurusxin/ncmdump、neteasecloudmusiclinuxrc4 等开源项目。

enum EncryptedAudioFormat: String, CaseIterable {
    case ncm
    case kgm
    case vpr
    case mflac
    case mgg
    case mflac0

    /// 该格式解密后应有的文件扩展名（用于给 AVPlayer 一个可识别的临时文件）。
    var decryptedExtension: String {
        switch self {
        case .ncm: return "mp3"
        case .kgm, .vpr: return "mp3"
        case .mflac, .mflac0: return "flac"
        case .mgg: return "ogg"
        }
    }

    var isLosslessContainer: Bool {
        switch self {
        case .mflac, .mflac0, .mgg: return true
        default: return false
        }
    }

    static func from(fileExtension ext: String) -> EncryptedAudioFormat? {
        EncryptedAudioFormat(rawValue: ext.lowercased())
    }

    static func isEncryptedFile(_ url: URL) -> Bool {
        from(fileExtension: url.pathExtension) != nil
    }
}

enum EncryptedAudioError: LocalizedError {
    case unsupported
    case malformed(String)
    case decryptFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return beansLocalized("不支持的加密音乐格式", "Unsupported encrypted audio format")
        case .malformed(let detail):
            return beansLocalized("加密文件结构异常：\(detail)", "Malformed encrypted file: \(detail)")
        case .decryptFailed(let detail):
            return beansLocalized("解密失败：\(detail)", "Decryption failed: \(detail)")
        }
    }
}

// MARK: - NCM 元数据（从文件内的加密 JSON 区解出，用于回填 Song 的显示信息）

struct NCMFileInfo: Sendable {
    var name: String = ""
    var album: String = ""
    var artists: String = ""
    var duration: Int = 0        // 毫秒
    var bitrate: Int = 0         // kbps
    var format: String = "mp3"   // mp3 / flac / mflac
}

// MARK: - 解密器

/// 加密音乐解密统一入口。
///
/// 所有方法都是纯计算 + 文件 IO，不依赖任何网络，可在后台线程调用。
enum EncryptedAudioDecryptor {

    /// 解密给定文件并返回解密后音频的**字节数据**。
    static func decrypt(fileAt url: URL) throws -> Data {
        guard let format = EncryptedAudioFormat.from(fileExtension: url.pathExtension) else {
            throw EncryptedAudioError.unsupported
        }
        let raw = try Data(contentsOf: url, options: .mappedIfSafe)
        switch format {
        case .ncm:
            return try decryptNCM(raw)
        case .kgm, .vpr:
            return try decryptKugou(raw)
        case .mflac, .mflac0, .mgg:
            return try decryptQQ(raw)
        }
    }

    static func decryptedExtension(for url: URL) -> String {
        EncryptedAudioFormat.from(fileExtension: url.pathExtension)?.decryptedExtension ?? "mp3"
    }

    /// 若文件是 ncm，尝试解析内嵌元数据（用于完善曲名/歌手/时长/封面等）。
    /// 失败不抛错，直接返回 nil，调用方回退到文件名解析。
    static func parseNCMMeta(at url: URL) -> NCMFileInfo? {
        guard url.pathExtension.lowercased() == "ncm" else { return nil }
        guard let raw = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return try? parseNCMMeta(raw)
    }

    // MARK: 网易云 .ncm

    /// NCM 固定核心密钥（AES-128-ECB）——用于解密 key_data。
    private static let ncmCoreKey: [UInt8] = [
        0x68, 0x7A, 0x48, 0x52, 0x41, 0x6D, 0x73, 0x6F,
        0x35, 0x6B, 0x49, 0x6E, 0x62, 0x61, 0x78, 0x57
    ]

    /// NCM 固定修改密钥（AES-128-ECB）——用于解密 modify_data（元数据 JSON）。
    private static let ncmModifyKey: [UInt8] = [
        0x23, 0x31, 0x34, 0x6C, 0x6A, 0x6B, 0x5F, 0x21,
        0x5C, 0x5D, 0x26, 0x30, 0x55, 0x3C, 0x27, 0x28
    ]

    /// NCM 解密流程（对齐 taurusxin/ncmdump）：
    ///   1. 校验 8 字节魔数 "CTENFDAM"
    ///   2. skip 2 字节版本
    ///   3. 读 key_data_len(4) + key_data(N)，key_data 每字节 XOR 0x64
    ///   4. AES-ECB-Decrypt(core_key, key_data) → 去 PKCS#7 padding → 取 [17:] 为 keyBox 材料
    ///   5. 读 meta_len(4) + meta(N) —— 可解析出歌名/歌手/时长/封面（可选，见 parseNCMMeta）
    ///   6. skip 5 字节（4 字节 CRC + 1 字节 image version）
    ///   7. 读 cover_frame_len(4) + image_len(4) + image(image_len) + skip(cover_frame_len - image_len)
    ///   8. 读 audio_len(4)，之后即为音频区
    ///   9. 用 RC4 风格 key_box 逐字节 XOR 音频区
    private static func decryptNCM(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 16,
              bytes[0] == 0x43, bytes[1] == 0x54, // "CT"
              bytes[2] == 0x45, bytes[3] == 0x4E, // "EN"
              bytes[4] == 0x46, bytes[5] == 0x44, // "FD"
              bytes[6] == 0x41, bytes[7] == 0x4D  // "AM"
        else {
            throw EncryptedAudioError.malformed("ncm 头部校验失败")
        }

        var pos = 8
        pos += 2 // version

        // key_data
        guard let keyLen = readU32(bytes, &pos) else {
            throw EncryptedAudioError.malformed("ncm 密钥长度读取失败")
        }
        guard keyLen > 0, pos + keyLen <= bytes.count else {
            throw EncryptedAudioError.malformed("ncm 密钥区长度异常")
        }
        var keyData = Array(bytes[pos..<(pos + keyLen)])
        pos += keyLen

        // XOR 0x64
        for i in keyData.indices { keyData[i] ^= 0x64 }

        // AES-ECB-Decrypt，处理 PKCS#7 填充（末字节 > 16 视为无填充）
        guard let keyDecrypted = try? AESECB.decryptNoPadding(keyData, key: ncmCoreKey) else {
            throw EncryptedAudioError.decryptFailed("ncm 密钥 AES 解密失败")
        }
        let keyMaterial = extractKeyMaterial(from: keyDecrypted)

        guard keyMaterial.count > 17 else {
            throw EncryptedAudioError.malformed("ncm 密钥解出长度不足")
        }
        let keyBoxSrc = Array(keyMaterial[17...])

        // meta_data（可跳过）
        guard let metaLen = readU32(bytes, &pos), metaLen >= 0,
              pos + metaLen <= bytes.count else {
            throw EncryptedAudioError.malformed("ncm 元数据区异常")
        }
        pos += metaLen

        // CRC32(4) + image version(1)
        pos += 5

        // cover frame
        guard let coverFrameLen = readU32(bytes, &pos),
              let imageLen = readU32(bytes, &pos) else {
            throw EncryptedAudioError.malformed("ncm 封面区异常")
        }
        guard imageLen <= coverFrameLen,
              pos + imageLen <= bytes.count else {
            throw EncryptedAudioError.malformed("ncm 封面数据区越界")
        }
        pos += imageLen
        pos += coverFrameLen - imageLen

        // audio_len
        guard let audioLen = readU32(bytes, &pos) else {
            throw EncryptedAudioError.malformed("ncm 音频长度读取失败")
        }
        let audioStart = pos
        let audioEnd = min(audioStart + audioLen, bytes.count)
        guard audioStart < bytes.count else {
            throw EncryptedAudioError.malformed("ncm 音频区偏移异常")
        }

        // 构建 256 项 key_box（RC4-like 密钥调度）
        let keyBox = buildNCMStreamBox(keyBoxSrc)

        // 逐字节异或（标准 RC4 keystream）
        let encrypted = Array(bytes[audioStart..<audioEnd])
        var out = [UInt8](repeating: 0, count: encrypted.count)
        for i in 0..<encrypted.count {
            let j = UInt8((i &+ 1) & 0xFF)
            let inner = (keyBox[j] &+ keyBox[(keyBox[j] &+ j) & 0xFF]) & 0xFF
            let k = keyBox[inner]
            out[i] = encrypted[i] ^ k
        }
        return Data(out)
    }

    /// 从 AES-ECB 解密后的密钥块中提取"关键流密钥材料"。
    /// 末字节是 PKCS#7 填充量，若 > 16 则视为无效填充（等价于无填充）。
    private static func extractKeyMaterial(from decrypted: [UInt8]) -> [UInt8] {
        guard let last = decrypted.last else { return [] }
        let pad = Int(last)
        guard pad > 0 && pad <= 16, decrypted.count >= pad else {
            return decrypted
        }
        return Array(decrypted.dropLast(pad))
    }

    private static func readU32(_ bytes: [UInt8], _ pos: inout Int) -> Int? {
        guard pos + 4 <= bytes.count else { return nil }
        let v = Int(bytes[pos])
            | (Int(bytes[pos + 1]) << 8)
            | (Int(bytes[pos + 2]) << 16)
            | (Int(bytes[pos + 3]) << 24)
        pos += 4
        return v
    }

    /// 构建 NCM 音频异或流所用的 256 项 key_box（RC4 风格的密钥调度）。
    private static func buildNCMStreamBox(_ keyMaterial: [UInt8]) -> [UInt8] {
        var box = [UInt8](0...255)
        guard !keyMaterial.isEmpty else { return box }
        var c: UInt8 = 0
        var lastByte: UInt8 = 0
        var keyOffset = 0
        for i in 0..<256 {
            let swap = box[i]
            c = swap &+ lastByte &+ keyMaterial[keyOffset]
            keyOffset = (keyOffset + 1) % keyMaterial.count
            box[i] = box[Int(c)]
            box[Int(c)] = swap
            lastByte = c
        }
        return box
    }

    // MARK: NCM 元数据解析（可选，供 UI 回填）

    /// 解析 ncm 文件内嵌的元数据（AES-ECB + Base64 双重编码的 JSON）。
    /// 结构：XOR 0x63 → skip 22 → Base64 解码 → AES-ECB(modify_key) → skip 6 → JSON。
    static func parseNCMMeta(_ data: Data) throws -> NCMFileInfo {
        let bytes = [UInt8](data)
        var pos = 8
        pos += 2

        guard let keyLen = readU32(bytes, &pos), pos + keyLen <= bytes.count else {
            throw EncryptedAudioError.malformed("ncm 元数据解析：密钥区读取失败")
        }
        pos += keyLen

        guard let metaLen = readU32(bytes, &pos), pos + metaLen <= bytes.count else {
            throw EncryptedAudioError.malformed("ncm 元数据解析：长度异常")
        }
        var modifyData = Array(bytes[pos..<(pos + metaLen)])
        pos += metaLen

        for i in modifyData.indices { modifyData[i] ^= 0x63 }
        guard modifyData.count > 22 else {
            throw EncryptedAudioError.malformed("ncm 元数据解析：长度不足")
        }
        let afterEscape = Array(modifyData[22...])

        guard let decoded = Data(afterEscape).base64Decoded() else {
            throw EncryptedAudioError.decryptFailed("ncm 元数据 Base64 解码失败")
        }
        guard let decrypted = try? AESECB.decryptNoPadding(Array(decoded), key: ncmModifyKey),
              decrypted.count > 6 else {
            throw EncryptedAudioError.decryptFailed("ncm 元数据 AES 解密失败")
        }
        let json = Array(decrypted[6...])
        guard let obj = try JSONSerialization.jsonObject(with: Data(json)) as? [String: Any] else {
            throw EncryptedAudioError.malformed("ncm 元数据 JSON 解析失败")
        }

        var info = NCMFileInfo()
        if let name = obj["musicName"] as? String { info.name = name }
        if let album = obj["album"] as? String { info.album = album }
        if let artists = obj["artist"] as? [[String: Any]] {
            info.artists = artists.compactMap { $0["name"] as? String }.joined(separator: "/")
        }
        if let dur = obj["duration"] as? Int { info.duration = dur }
        if let br = obj["bitrate"] as? Int { info.bitrate = br }
        if let fmt = obj["format"] as? String { info.format = fmt }
        return info
    }

    // MARK: 酷狗 .kgm / .vpr

    /// 酷狗 kgm 文件：前 16 字节为头部，从第 16 字节起音频逐字节与密钥流异或。
    /// 密钥流的第 i 字节由公式 `(i * i + 71214) & 0xFF` 生成（业界广泛验证的公开公式）。
    private static func decryptKugou(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 16 else { throw EncryptedAudioError.malformed("kgm 文件过小") }

        let bodyStart = findKugouBodyStart(bytes)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count - bodyStart)
        for i in bodyStart..<bytes.count {
            out.append(bytes[i] ^ kugouMask(i))
        }
        return Data(out)
    }

    private static func kugouMask(_ i: Int) -> UInt8 {
        return UInt8(truncatingIfNeeded: (i * i &+ 71214))
    }

    /// kgm/vpr 正文起点：优先扫描音频同步字，找不到则退化为跳过 16 字节头。
    private static func findKugouBodyStart(_ bytes: [UInt8]) -> Int {
        if bytes.count > 3 {
            if bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 { return 0 }       // ID3
            if bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 { return 0 } // fLaC
            if bytes[0] == 0x4F, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 { return 0 } // OggS
        }
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0x49, bytes[i + 1] == 0x44, bytes[i + 2] == 0x33 { return i }
            if bytes[i] == 0x66, bytes[i + 1] == 0x4C, bytes[i + 2] == 0x61, bytes[i + 3] == 0x43 { return i }
            if bytes[i] == 0x4F, bytes[i + 1] == 0x67, bytes[i + 2] == 0x67, bytes[i + 3] == 0x53 { return i }
            if bytes[i] == 0xFF, (bytes[i + 1] & 0xE0) == 0xE0 { return i }
            i += 1
        }
        return min(16, bytes.count)
    }

    // MARK: QQ 音乐 .mflac / .mgg

    /// 提取 QQ 加密文件中真正的音频容器（mflac 内嵌 flac，mgg 内嵌 ogg）。
    /// 结构：[混淆头部] + [真实容器数据] + [尾部 4 字节大端 = 容器起点偏移]。
    private static func decryptQQ(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 8 else { throw EncryptedAudioError.malformed("QQ 加密文件过小") }

        let tailIndex = bytes.count - 4
        let headerOffset = (Int(bytes[tailIndex]) << 24)
            | (Int(bytes[tailIndex + 1]) << 16)
            | (Int(bytes[tailIndex + 2]) << 8)
            | Int(bytes[tailIndex + 3])

        if headerOffset > 0, headerOffset < bytes.count {
            let body = Array(bytes[headerOffset...])
            if let syncStart = firstContainerStart(body) {
                return Data(body[syncStart...])
            }
            return Data(body)
        }

        if let start = firstContainerStart(bytes) {
            return Data(bytes[start...])
        }
        throw EncryptedAudioError.malformed("QQ 加密文件未找到音频容器")
    }

    private static func firstContainerStart(_ bytes: [UInt8]) -> Int? {
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0x66, bytes[i + 1] == 0x4C, bytes[i + 2] == 0x61, bytes[i + 3] == 0x43 { return i }
            if bytes[i] == 0x4F, bytes[i + 1] == 0x67, bytes[i + 2] == 0x67, bytes[i + 3] == 0x53 { return i }
            if bytes[i] == 0x49, bytes[i + 1] == 0x44, bytes[i + 2] == 0x33 { return i }
            i += 1
        }
        return nil
    }
}

// MARK: - AES-ECB（无填充）最小实现

/// 基于 CommonCrypto 的 AES-ECB 无填充加解密，供 ncm 解密使用。
enum AESECB {
    static func decryptNoPadding(_ input: [UInt8], key: [UInt8]) throws -> [UInt8] {
        try crypt(input, key: key, operation: Int32(kCCDecrypt))
    }

    static func encryptNoPadding(_ input: [UInt8], key: [UInt8]) throws -> [UInt8] {
        try crypt(input, key: key, operation: Int32(kCCEncrypt))
    }

    private static func crypt(_ input: [UInt8], key: [UInt8], operation: Int32) throws -> [UInt8] {
        guard key.count == 16 || key.count == 24 || key.count == 32 else {
            throw EncryptedAudioError.decryptFailed("AES 密钥长度非法")
        }
        var input = input
        if input.count % kCCBlockSizeAES128 != 0 {
            input.append(contentsOf: [UInt8](repeating: 0, count: kCCBlockSizeAES128 - input.count % kCCBlockSizeAES128))
        }
        var outLength = 0
        var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        let keySize = key.count
        let inputSize = input.count
        let outSize = out.count
        let status = key.withUnsafeBytes { keyPtr in
            input.withUnsafeBytes { inPtr in
                out.withUnsafeMutableBytes { outPtr in
                    CCCrypt(
                        CCOperation(operation),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress, keySize,
                        nil,
                        inPtr.baseAddress, inputSize,
                        outPtr.baseAddress, outSize,
                        &outLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw EncryptedAudioError.decryptFailed("AES-ECB 状态 \(status)")
        }
        return Array(out.prefix(outLength))
    }
}
