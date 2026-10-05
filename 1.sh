#!/bin/bash
set -e
cd "$(dirname "$0")"

echo "===== 1/4 Models.swift ====="
python3 - <<'PY'
p = "Beans/Models.swift"
s = open(p, encoding="utf-8").read()

if "linkedNeteaseID" not in s:
    anchor = '    let localFileName: String?\n'
    assert anchor in s, "找不到 localFileName"
    s = s.replace(anchor,
        anchor + '\n    /// 本地文件对应的网易云歌曲 id\n    let linkedNeteaseID: Int?\n', 1)

    anchor2 = '    var formattedDuration: String {'
    assert anchor2 in s, "找不到 formattedDuration"
    method = '''    /// 用网易云详情补全本地歌曲元数据
    func merging(netease detail: Song) -> Song {
        Song(
            id: self.id,
            name: detail.name.isEmpty ? self.name : detail.name,
            artists: detail.artists.isEmpty ? self.artists : detail.artists,
            album: detail.album.isEmpty ? self.album : detail.album,
            coverURL: detail.coverURL ?? self.coverURL,
            duration: detail.duration > 0 ? detail.duration : self.duration,
            source: .local,
            qqMid: nil,
            qqMediaMid: nil,
            kugouHash: nil,
            kugouAlbumAudioId: nil,
            kugouAlbumId: nil,
            kugouQualityHashes: nil,
            fee: detail.fee,
            localFileName: self.localFileName,
            linkedNeteaseID: self.linkedNeteaseID
        )
    }

'''
    s = s.replace(anchor2, method + anchor2, 1)
    open(p, "w", encoding="utf-8").write(s)
    print("Models.swift 已修改")
else:
    print("Models.swift 已含字段，跳过")
PY

echo "===== 2/4 NetEaseAPI.swift ====="
python3 - <<'PY'
p = "Beans/NetEaseAPI.swift"
s = open(p, encoding="utf-8").read()
if "func songDetail" not in s:
    anchor = '    func songURLs(ids: [Int], level: String = "standard") async throws -> [Int: String] {'
    assert anchor in s, "找不到 songURLs"
    new = '''    /// 按歌曲 id 拉取详情
    func songDetail(id: Int) async throws -> Song? {
        let json = try await request("/api/v3/song/detail", payload: [
            "c": "[{\\"id\\":\\(id)}]"
        ], crypto: "weapi")
        guard let songs = json["songs"] as? [[String: Any]],
              let first = songs.first else { return nil }
        return Song(json: first)
    }

'''
    s = s.replace(anchor, new + anchor, 1)
    open(p, "w", encoding="utf-8").write(s)
    print("NetEaseAPI.swift 已修改")
else:
    print("NetEaseAPI.swift 已含 songDetail，跳过")
PY

echo "===== 3/4 LocalAudioLibrary.swift ====="
python3 - <<'PY'
p = "Beans/LocalAudioLibrary.swift"
s = open(p, encoding="utf-8").read()

s = s.replace(
    '            localFileName: old.localFileName\n        )\n    }\n\n    // MARK: 构造 Song',
    '            localFileName: old.localFileName,\n            linkedNeteaseID: old.linkedNeteaseID\n        )\n    }\n\n    // MARK: 构造 Song', 1)

s = s.replace(
    '        let platformID = Self.parsePlatformID(fromName: fileName)\n',
    '        let platformID = Self.parsePlatformID(fromName: fileName)\n        let linkedID = platformID.flatMap { Int($0) }\n', 1)

s = s.replace(
    '''                source: .local,
                fee: 0,
                localFileName: fileName
            )
        }''',
    '''                source: .local,
                fee: 0,
                localFileName: fileName,
                linkedNeteaseID: linkedID
            )
        }''', 1)

s = s.replace(
    '''            source: .local,
            fee: 0,
            localFileName: fileName
        )
    }

    // MARK: 播放''',
    '''            source: .local,
            fee: 0,
            localFileName: fileName,
            linkedNeteaseID: linkedID
        )
    }

    // MARK: 播放''', 1)

anchor = 'BeansLogger.shared.log("本地音乐扫描完成：\\(result.count) 首（目录 \\(dir.path)）", level: .info)\n'
if anchor in s:
    inject = anchor + '''
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
                            BeansLogger.shared.log("本地歌元数据补全失败：\\(song.localFileName ?? "?") - \\(error)", level: .warn)
                        }
                    }
                }
'''
    s = s.replace(anchor, inject, 1)

open(p, "w", encoding="utf-8").write(s)
print("LocalAudioLibrary.swift 已修改")
PY

echo "===== 4/4 缓存版本升级 ====="
sed -i 's/let beansDecryptCacheVersion = "v2"/let beansDecryptCacheVersion = "v3"/' Beans/EncryptedAudio.swift
grep -n "beansDecryptCacheVersion =" Beans/EncryptedAudio.swift

echo
echo "✅ 完成。现在跑编译："
echo "xcodebuild -project Beans.xcodeproj -scheme Beans -configuration Debug -sdk iphonesimulator build 2>&1 | grep error: | head -40"