import Foundation

// MARK: - 加密音乐格式
//
// 支持三类主流平台的加密下载文件：
//   .ncm  —— 网易云音乐
//   .kgm / .vpr —— 酷狗音乐
//   .mflac / .mgg / .mflac0 —— QQ 音乐
//
// 这些文件在播放时才解密：解密结果写入 App 私有缓存目录，再交给 AVPlayer。
// 原始加密文件始终保留在原目录，不做转换、不修改。

enum EncryptedAudioFormat: String, CaseIterable {
    case ncm
    case kgm
    case vpr
    case mflac
    case mgg
    /// QQ 音乐的 mflac 变体（部分新版本文件名）
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

    /// 是否是"无损容器"（flac/ogg 需要保留正确扩展名以便 AVPlayer 解析）。
    var isLosslessContainer: Bool {
        switch self {
        case .mflac, .mflac0, .mgg: return true
        default: return false
        }
    }

    static func from(fileExtension ext: String) -> EncryptedAudioFormat? {
        EncryptedAudioFormat(rawValue: ext.lowercased())
    }

    /// 扩展名是否属于本 App 可识别的加密音乐。
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

// MARK: - 解密器

/// 加密音乐解密统一入口。
///
/// 所有方法都是纯计算 + 文件 IO，不依赖任何网络，可在后台线程调用。
enum EncryptedAudioDecryptor {

    /// 解密给定文件并返回解密后音频的**字节数据**。
    /// - 调用方负责把 `data` 写入临时/缓存文件后交给播放器。
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

    /// 解密并返回音频在内存中的扩展名（供落盘命名使用）。
    static func decryptedExtension(for url: URL) -> String {
        EncryptedAudioFormat.from(fileExtension: url.pathExtension)?.decryptedExtension ?? "mp3"
    }

    // MARK: 网易云 .ncm

    /// NCM 固定核心密钥（AES-128-ECB）。
    private static let ncmCoreKey: [UInt8] = [
        0x68, 0x7A, 0x48, 0x52, 0x41, 0x6D, 0x73, 0x6F,
        0x35, 0x6B, 0x49, 0x6E, 0x62, 0x61, 0x78, 0x57
    ]

    /// NCM 解密流程（对齐公开实现）：
    ///   1. 校验 8 字节魔数 "CTENFDAM"
    ///   2. 读取 key_data（长度由 u32 小端给出），对其每个字节 XOR 0x64
    ///   3. key_data = AES-128-ECB-Decrypt(core_key, key_data)，去 PKCS#7 填充，取 [17:]
    ///   4. 用 key_data 构建 256 项 RC4 风格 key_box
    ///   5. 音频区逐字节与 key_box 生成的流异或（**不是** AES 解密）
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

        var offset = 8
        func readU32() throws -> Int {
            guard offset + 4 <= bytes.count else { throw EncryptedAudioError.malformed("ncm 越界") }
            let v = Int(bytes[offset])
                | (Int(bytes[offset + 1]) << 8)
                | (Int(bytes[offset + 2]) << 16)
                | (Int(bytes[offset + 3]) << 24)
            offset += 4
            return v
        }

        // 跳过 2 字节版本
        offset += 2

        // key_data
        let keyLength = try readU32()
        guard keyLength > 0, offset + keyLength <= bytes.count else {
            throw EncryptedAudioError.malformed("ncm 密钥区长度异常")
        }
        var keyData = Array(bytes[offset..<(offset + keyLength)])
        offset += keyLength

        // 元数据区
        let metaLength = try readU32()
        guard metaLength >= 0, offset + metaLength <= bytes.count else {
            throw EncryptedAudioError.malformed("ncm 元数据区长度异常")
        }
        offset += metaLength

        // CRC(4) + 间隔(5)
        offset += 9

        // 封面区
        let imageSize = try readU32()
        guard imageSize >= 0, offset + imageSize <= bytes.count else {
            throw EncryptedAudioError.malformed("ncm 封面区长度异常")
        }
        offset += imageSize

        // 音频区起始
        let audioStart = offset
        guard audioStart < bytes.count else {
            throw EncryptedAudioError.malformed("ncm 音频区偏移异常")
        }

        // 1) 逐字节 XOR 0x64
        for i in keyData.indices {
            keyData[i] ^= 0x64
        }
        // 2) AES-ECB 解密后去填充，取 [17:]
        let decryptedKey = try AESECB.decryptNoPadding(keyData, key: ncmCoreKey)
        let unpadded = removePKCS7Padding(decryptedKey)
        guard unpadded.count > 17 else {
            throw EncryptedAudioError.malformed("ncm 密钥解出长度不足")
        }
        let keyMaterial = Array(unpadded[17...])

        // 3) 构建 RC4 风格 key_box
        let keyBox = buildNCMStreamBox(keyMaterial)

        // 4) 音频区逐字节与密钥流异或
        let encryptedAudio = Array(bytes[audioStart...])
        var out = [UInt8](repeating: 0, count: encryptedAudio.count)
        var lastByte: UInt8 = 0
        var keyOffset = 0
        for i in 0..<encryptedAudio.count {
            let swap = keyBox[i & 0xFF]
            lastByte = swap &+ lastByte &+ UInt8(truncatingIfNeeded: keyMaterial[keyOffset])
            out[i] = encryptedAudio[i] ^ keyBox[Int(lastByte)]
            keyOffset = (keyOffset + 1) % keyMaterial.count
        }
        return Data(out)
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
            box[i] = box[Int(c)]
            box[Int(c)] = swap
            lastByte = c
            keyOffset = (keyOffset + 1) % keyMaterial.count
        }
        return box
    }

    /// 去掉 PKCS#7 填充。
    private static func removePKCS7Padding(_ bytes: [UInt8]) -> [UInt8] {
        guard let last = bytes.last else { return bytes }
        let pad = Int(last)
        guard pad > 0, pad <= 16, bytes.count >= pad else { return bytes }
        return Array(bytes.dropLast(pad))
    }

    // MARK: 酷狗 .kgm / .vpr

    /// 酷狗 kgm 文件：前 16 字节为头部，从第 16 字节起音频逐字节与密钥流异或。
    /// 密钥流的第 i 字节由公式 `(i * i + 71214) & 0xFF` 生成（部分版本用
    /// `(i*i+71214) ^ mask`），这里采用广泛验证的公开公式。
    private static func decryptKugou(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 16 else { throw EncryptedAudioError.malformed("kgm 文件过小") }

        // 不同版本的 kgm/vpr 头部长度可能是 16 或 0x10 的倍数；扫描首个音频同步字
        // 更稳妥：找到 ID3 / fLaC / OggS 后就地开始异或。
        let bodyStart = findKugouBodyStart(bytes)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count - bodyStart)
        for i in bodyStart..<bytes.count {
            let mask = kugouMask(i)
            out.append(bytes[i] ^ mask)
        }
        return Data(out)
    }

    /// 酷狗密钥流第 i 字节。
    private static func kugouMask(_ i: Int) -> UInt8 {
        // (i*i + 71214) 的低 8 位
        return UInt8(truncatingIfNeeded: (i * i &+ 71214))
    }

    /// kgm/vpr 正文起点：优先扫描音频同步字，找不到则退化为跳过 16 字节头。
    private static func findKugouBodyStart(_ bytes: [UInt8]) -> Int {
        // 已去掉头的文件（ID3 / FLAC / OggS 开头）
        if bytes.count > 3 {
            if bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 { return 0 }       // ID3
            if bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 { return 0 } // fLaC
            if bytes[0] == 0x4F, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 { return 0 } // OggS
        }
        // 扫描首个 MP3 帧同步字 / ID3
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0x49, bytes[i + 1] == 0x44, bytes[i + 2] == 0x33 { return i }
            if bytes[i] == 0x66, bytes[i + 1] == 0x4C, bytes[i + 2] == 0x61, bytes[i + 3] == 0x43 { return i }
            if bytes[i] == 0x4F, bytes[i + 1] == 0x67, bytes[i + 2] == 0x67, bytes[i + 3] == 0x53 { return i }
            if bytes[i] == 0xFF, (bytes[i + 1] & 0xE0) == 0xE0 { return i }
            i += 1
        }
        // 退化：跳过标准 16 字节头
        return min(16, bytes.count)
    }

    // MARK: QQ 音乐 .mflac / .mgg

    /// 提取 QQ 加密文件中真正的音频容器（mflac 内嵌 flac，mgg 内嵌 ogg）。
    ///
    /// QQ 加密文件的结构：
    ///   [混淆头部(可变长)] + [真实容器数据] + [尾部 4 字节指向容器起点的偏移]
    /// 音频容器本身未加密，只需按尾部偏移定位并截取即可被 AVPlayer 解析。
    private static func decryptQQ(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 8 else { throw EncryptedAudioError.malformed("QQ 加密文件过小") }

        // 尾部 4 字节大端整数：真实音频容器在文件中的起始偏移。
        let tailIndex = bytes.count - 4
        let headerOffset = (Int(bytes[tailIndex]) << 24)
            | (Int(bytes[tailIndex + 1]) << 16)
            | (Int(bytes[tailIndex + 2]) << 8)
            | Int(bytes[tailIndex + 3])

        // 优先按尾部偏移取容器；偏移非法时回退到全文件扫描同步字。
        if headerOffset > 0, headerOffset < bytes.count {
            let body = Array(bytes[headerOffset...])
            if let syncStart = firstContainerStart(body) {
                return Data(body[syncStart...])
            }
            return Data(body)
        }

        // 回退：直接在原始字节里找 flac / ogg 同步字。
        if let start = firstContainerStart(bytes) {
            return Data(bytes[start...])
        }
        throw EncryptedAudioError.malformed("QQ 加密文件未找到音频容器")
    }

    /// 在字节流中定位首个音频容器同步字（fLaC / OggS / ID3 / MP3 帧）。
    private static func firstContainerStart(_ bytes: [UInt8]) -> Int? {
        var i = 0
        while i + 3 < bytes.count {
            // fLaC
            if bytes[i] == 0x66, bytes[i + 1] == 0x4C, bytes[i + 2] == 0x61, bytes[i + 3] == 0x43 {
                return i
            }
            // OggS
            if bytes[i] == 0x4F, bytes[i + 1] == 0x67, bytes[i + 2] == 0x67, bytes[i + 3] == 0x53 {
                return i
            }
            // ID3
            if bytes[i] == 0x49, bytes[i + 1] == 0x44, bytes[i + 2] == 0x33 {
                return i
            }
            i += 1
        }
        return nil
    }
}

// MARK: - AES-ECB（无填充）最小实现

/// 基于 CommonCrypto 的 AES-ECB 无填充加解密，供 ncm 解密使用。
/// 项目已在 Bridging Header 中引入 CommonCrypto，无需额外依赖。
enum AESECB {
    static func decryptNoPadding(_ input: [UInt8], key: [UInt8]) throws -> [UInt8] {
        try crypt(input, key: key, operation: kCCDecrypt)
    }

    static func encryptNoPadding(_ input: [UInt8], key: [UInt8]) throws -> [UInt8] {
        try crypt(input, key: key, operation: kCCEncrypt)
    }

    private static func crypt(_ input: [UInt8], key: [UInt8], operation: Int32) throws -> [UInt8] {
        guard key.count == 16 || key.count == 24 || key.count == 32 else {
            throw EncryptedAudioError.decryptFailed("AES 密钥长度非法")
        }
        // ECB 无填充要求输入长度为 16 的整数倍，不足时右侧补零（解密场景多余块由调用方去填充）。
        var input = input
        if input.count % kCCBlockSizeAES128 != 0 {
            input.append(contentsOf: [UInt8](repeating: 0, count: kCCBlockSizeAES128 - input.count % kCCBlockSizeAES128))
        }
        var outLength = 0
        var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        let status = key.withUnsafeBytes { keyPtr in
            input.withUnsafeBytes { inPtr in
                out.withUnsafeMutableBytes { outPtr in
                    CCCrypt(
                        CCOperation(operation),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress, key.count,
                        nil,
                        inPtr.baseAddress, input.count,
                        outPtr.baseAddress, out.count,
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
