import SwiftUI
import UniformTypeIdentifiers

// MARK: - 本地加密音乐（ncm / kgm / vpr / mflac / mgg）
//
// 入口位于「音乐库 → 本地音乐」。用户可以：
//   1. 通过「导入」按钮从系统文件选择器导入加密音乐；
//   2. 直接把文件放进 App 沙盒 Documents/BeansMusic/（文件 App / iTunes 文件共享）；
// 播放时才解密，原始加密文件保持不动。

struct LocalEncryptedMusicSection: View {
    @ObservedObject private var library = LocalAudioLibrary.shared
    @EnvironmentObject private var player: PlayerManager
    @AppStorage("beans.language") private var languageRaw = AppLanguage.chinese.rawValue

    @State private var showImporter = false
    @State private var showFolderHelp = false
    @State private var showClearCacheConfirm = false
    @State private var importMessage: String?

    private var isEnglish: Bool { languageRaw == AppLanguage.english.rawValue }

    private var titleText: String {
        isEnglish ? "Local Music" : "本地音乐"
    }

    private var emptyText: String {
        isEnglish
            ? "No local audio yet\nTap Import to add encrypted (.ncm / .kgm / .mflac / .mgg)\nor plain (.mp3 / .m4a / .wav / .flac / .ogg) files,\nor drop files into Documents/BeansMusic"
            : "还没有本地音乐\n点「导入」添加加密文件（.ncm / .kgm / .mflac / .mgg）\n或明文音频（.mp3 / .m4a / .wav / .flac / .ogg），\n也可以直接把文件放进 Documents/BeansMusic"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(titleText)
                    .font(BeansFont.appFont(21, .bold))
                    .foregroundStyle(Color.beansLabel)
                Spacer(minLength: 8)
                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.beansAmber)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isEnglish ? "Import" : "导入")
                Button {
                    showFolderHelp = true
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.beansAmber)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isEnglish ? "Folder help" : "文件夹说明")
            }

            if let importMessage {
                Text(importMessage)
                    .font(BeansFont.appFont(12, .medium))
                    .foregroundStyle(Color.beansSage)
            }

            if library.songs.isEmpty {
                EmptyStateView(icon: "waveform", text: emptyText)
            } else {
                HStack(spacing: 8) {
                    GlassButton(
                        title: isEnglish ? "Play All" : "播放全部",
                        systemName: "play.fill",
                        prominent: true
                    ) {
                        playAll()
                    }
                    GlassButton(
                        title: isEnglish ? "Clear Cache" : "清理解密缓存",
                        systemName: "trash"
                    ) {
                        showClearCacheConfirm = true
                    }
                }
                LazyVStack(spacing: 0) {
                    ForEach(library.songs) { song in
                        localSongRow(song)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: importTypes,
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .sheet(isPresented: $showFolderHelp) {
            folderHelpSheet
        }
        .confirmationDialog(
            isEnglish ? "Clear decrypted cache?" : "清理解密缓存？",
            isPresented: $showClearCacheConfirm,
            titleVisibility: .visible
        ) {
            Button(isEnglish ? "Clear" : "清理", role: .destructive) {
                library.clearDecryptedCache()
                importMessage = isEnglish ? "Cache cleared" : "已清理解密缓存"
            }
            Button(isEnglish ? "Cancel" : "取消", role: .cancel) {}
        } message: {
            Text(isEnglish
                 ? "This removes decrypted temporary files only. Your original encrypted files are kept."
                 : "只会删除解密产生的临时文件，原始加密文件保留。")
        }
    }

    // MARK: 行

    @ViewBuilder
    private func localSongRow(_ song: Song) -> some View {
        Button {
            play(song)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.beansAmber.opacity(0.75), Color.beansAmber.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 56, height: 56)
                    Image(systemName: "waveform")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.name)
                        .font(BeansFont.appFont(15, .medium))
                        .foregroundStyle(Color.beansLabel)
                        .lineLimit(1)
                    Text(song.duration > 0 ? "\(song.artists) · \(song.formattedDuration)" : song.artists)
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansComment)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: isCurrent(song) ? "waveform.circle.fill" : "play.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isCurrent(song) ? Color.beansAmber : Color.beansComment.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                library.remove(song: song)
                importMessage = isEnglish ? "Deleted \(song.name)" : "已删除 \(song.name)"
            } label: {
                Label(isEnglish ? "Delete File" : "删除文件", systemImage: "trash")
            }
        }
    }

    /// 列表行（轻量版，不构建封面渐变 + 图标，减少大列表渲染开销）。
    @ViewBuilder
    private func localSongRowLite(_ song: Song) -> some View {
        Button {
            play(song)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.beansAmber.opacity(0.85))
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.name)
                        .font(BeansFont.appFont(15, .medium))
                        .foregroundStyle(Color.beansLabel)
                        .lineLimit(1)
                    Text(song.artists)
                        .font(BeansFont.appFont(12))
                        .foregroundStyle(Color.beansComment)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: isCurrent(song) ? "waveform.circle.fill" : "play.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isCurrent(song) ? Color.beansAmber : Color.beansComment.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                library.remove(song: song)
                importMessage = isEnglish ? "Deleted \(song.name)" : "已删除 \(song.name)"
            } label: {
                Label(isEnglish ? "Delete File" : "删除文件", systemImage: "trash")
            }
        }
    }

    private func isCurrent(_ song: Song) -> Bool {
        player.currentSong?.identityKey == song.identityKey
    }

    // MARK: 动作

    private func play(_ song: Song) {
        BeansHaptics.select()
        player.playSong(song, in: library.songs)
    }

    private func playAll() {
        guard !library.songs.isEmpty else { return }
        BeansHaptics.select()
        player.play(songs: library.songs, startAt: 0)
    }

    private var importTypes: [UTType] {
        var types: [UTType] = []
        for ext in ["ncm", "kgm", "vpr", "mflac", "mflac0", "mgg",
                    "mp3", "m4a", "wav", "flac", "aac", "ogg", "opus"] {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        if types.isEmpty { types = [.audio, .data, .item] }
        return types
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var imported = 0
            let dir = library.ensureDirectories()
            for url in urls {
                guard LocalAudioLibrary.isAcceptedAudioFile(url) else { continue }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let dest = dir.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                    imported += 1
                }
            }
            library.refresh()
            importMessage = isEnglish
                ? "Imported \(imported) file(s)"
                : "已导入 \(imported) 个文件"
        case .failure(let error):
            importMessage = isEnglish
                ? "Import failed: \(error.localizedDescription)"
                : "导入失败：\(error.localizedDescription)"
        }
    }

    // MARK: 文件夹说明

    private var folderHelpSheet: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(isEnglish ? "How to add files" : "如何添加文件")
                        .font(BeansFont.appFont(18, .bold))
                    Text(isEnglish
                         ? "1. Tap Import and pick encrypted audio files.\n\n2. Or open the Files app → On My iPhone → Beans Music → BeansMusic, and drop the files there. iTunes / Finder file sharing works too.\n\n3. Restart or reopen this page to rescan."
                         : "1. 点「导入」，从系统文件中选择加密音乐。\n\n2. 或者打开「文件」App → 我的 iPhone → Beans Music → BeansMusic 文件夹，把文件放进去；也可用 iTunes / Finder 文件共享。\n\n3. 重开本页或重启 App 会重新扫描。")
                        .font(BeansFont.appFont(14))
                        .foregroundStyle(Color.beansComment)
                    Text(isEnglish ? "Folder path:" : "目录路径：")
                        .font(BeansFont.appFont(13, .semibold))
                    Text(library.musicDirectory.path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.beansAmber)
                        .textSelection(.enabled)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(isEnglish ? "Local Music Folder" : "本地音乐文件夹")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
