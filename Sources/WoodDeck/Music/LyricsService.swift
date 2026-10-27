import Foundation

// LyricLine 由 Core/Models.swift 统一提供

enum LyricsService {
    private struct Track {
        var title: String
        var artist: String
        var album: String
        var duration: Double
    }

    private static let browserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
    private static let appAgent = "WoodDeck/1.0 (macOS)"
    private static let timeout: TimeInterval = 8

    enum Source: String {
        case lrclib
        case netease
        case qq

        var title: String {
            switch self {
            case .lrclib: return "LRCLIB"
            case .netease: return "网易云"
            case .qq: return "QQ 音乐"
            }
        }
    }

    // 在哪家播放器里播，就先问哪家的歌词：平台自己的曲库对本地化版本与时长的记录最准
    static func preferredSource(for bundleIdentifier: String) -> Source? {
        switch bundleIdentifier {
        case "com.netease.163music": return .netease
        case "com.tencent.QQMusicMac": return .qq
        default: return nil
        }
    }

    // 优先源之后，LRCLIB 兜底，另一个平台放最后
    private static func order(for preferred: Source?) -> [Source] {
        switch preferred {
        case .netease: return [.netease, .lrclib, .qq]
        case .qq: return [.qq, .lrclib, .netease]
        case .lrclib, .none: return [.lrclib, .netease, .qq]
        }
    }

    static func fetch(title: String,
                      artist: String,
                      album: String,
                      duration: Double,
                      http: HTTPClient,
                      preferred: Source? = nil) async -> [LyricLine] {
        await fetchDetailed(title: title, artist: artist, album: album, duration: duration, http: http, preferred: preferred).lines
    }

    // 自检需要知道歌词最终来自哪个数据源
    static func fetchDetailed(title: String,
                              artist: String,
                              album: String,
                              duration: Double,
                              http: HTTPClient,
                              preferred: Source? = nil) async -> (lines: [LyricLine], source: String) {
        let track = Track(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                          artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
                          album: album.trimmingCharacters(in: .whitespacesAndNewlines),
                          duration: duration)
        guard !track.title.isEmpty, !track.artist.isEmpty else { return ([], "缺少标题或歌手") }
        for source in order(for: preferred) {
            let lines = await find(source, track, http: http)
            if !lines.isEmpty { return (lines, source.title) }
        }
        return ([], "全部未命中")
    }

    private static func find(_ source: Source, _ track: Track, http: HTTPClient) async -> [LyricLine] {
        switch source {
        case .lrclib: return await findLrclib(track, http: http)
        case .netease: return await findNetease(track, http: http)
        case .qq: return await findQq(track, http: http)
        }
    }

    // 自检用：只查指定的数据源，用来观察各源自己的命中情况
    static func fetchFrom(_ source: String,
                          title: String,
                          artist: String,
                          album: String,
                          duration: Double,
                          http: HTTPClient) async -> [LyricLine] {
        let track = Track(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                          artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
                          album: album.trimmingCharacters(in: .whitespacesAndNewlines),
                          duration: duration)
        guard !track.title.isEmpty, !track.artist.isEmpty else { return [] }
        switch source {
        case "lrclib": return await findLrclib(track, http: http)
        case "netease": return await findNetease(track, http: http)
        case "qq": return await findQq(track, http: http)
        default: return []
        }
    }

    // MARK: - LRCLIB

    private static func findLrclib(_ track: Track, http: HTTPClient) async -> [LyricLine] {
        let base = "track_name=\(escape(track.title))&artist_name=\(escape(track.artist))"
        let duration = track.duration > 0 ? "&duration=\(number(track.duration))" : ""
        // 精确接口先带专辑名查，查不到再去掉专辑名重查：现场版与精选集的专辑名常常对不上
        var queries = [base + duration]
        if !track.album.isEmpty {
            queries.insert(base + "&album_name=\(escape(track.album))" + duration, at: 0)
        }
        for query in queries {
            guard let row = await getJSON("https://lrclib.net/api/get?\(query)", headers: ["User-Agent": appAgent], http: http),
                  row.object != nil,
                  rankKey(track,
                          album: row["albumName"].text,
                          title: row["trackName"].text,
                          artist: row["artistName"].text,
                          seconds: row["duration"].float ?? 0) != nil else { continue }
            let lines = parse(row["syncedLyrics"].text, translation: nil)
            if !lines.isEmpty { return lines }
        }
        let search = await getJSON("https://lrclib.net/api/search?\(base)", headers: ["User-Agent": appAgent], http: http)
        guard let list = search?.array else { return [] }
        let ranked: [(item: JSONValue, key: RankKey)] = list.compactMap { item -> (item: JSONValue, key: RankKey)? in
            guard let key = rankKey(track,
                                    album: item["albumName"].text,
                                    title: item["trackName"].text,
                                    artist: item["artistName"].text,
                                    seconds: item["duration"].float ?? 0) else { return nil }
            return (item, key)
        }.sorted { better($0.key, $1.key) }
        for entry in ranked {
            let lines = parse(entry.item["syncedLyrics"].text, translation: nil)
            if !lines.isEmpty { return lines }
        }
        return []
    }

    // MARK: - 网易云

    private static func findNetease(_ track: Track, http: HTTPClient) async -> [LyricLine] {
        let headers = ["User-Agent": browserAgent, "Referer": "https://music.163.com/"]
        for keyword in searchKeywords(track) {
            let search = await getJSON("https://music.163.com/api/search/get/web?type=1&limit=8&s=\(escape(keyword))", headers: headers, http: http)
            guard let songs = search?["result"]["songs"].array else { continue }
            let ranked = songs.compactMap { song -> (id: Int, key: RankKey)? in
                let artist = song["artists"].array?.map { $0["name"].text }.joined(separator: " / ") ?? ""
                guard let id = song["id"].int, id > 0,
                      let key = rankKey(track,
                                        album: song["album"]["name"].text,
                                        title: song["name"].text,
                                        artist: artist,
                                        seconds: (song["duration"].float ?? 0) / 1000) else { return nil }
                return (id, key)
            }.sorted { better($0.key, $1.key) }
            for candidate in ranked {
                let lines = await findNeteaseID(String(candidate.id), http: http)
                if !lines.isEmpty { return lines }
            }
        }
        return []
    }

    private static func findNeteaseID(_ id: String, http: HTTPClient) async -> [LyricLine] {
        guard id.count <= 16, id.allSatisfy(\.isNumber) else { return [] }
        let headers = ["User-Agent": browserAgent, "Referer": "https://music.163.com/"]
        guard let data = await getJSON("https://music.163.com/api/song/lyric?id=\(id)&lv=-1&kv=-1&tv=-1", headers: headers, http: http),
              data.object != nil else { return [] }
        let translation = data["tlyric"]["lyric"].text
        return parse(data["lrc"]["lyric"].text, translation: translation.isEmpty ? nil : translation)
    }

    // MARK: - QQ 音乐

    private static func findQq(_ track: Track, http: HTTPClient) async -> [LyricLine] {
        // 没有时长就无法区分同名的现场版与翻唱
        guard track.duration > 0 else { return [] }
        let headers = ["User-Agent": browserAgent, "Referer": "https://y.qq.com/"]
        for keyword in searchKeywords(track) {
            let search = await getJSON("https://c.y.qq.com/soso/fcgi-bin/client_search_cp?format=json&p=1&n=20&w=\(escape(keyword))", headers: headers, http: http)
            guard let root = search, root["code"].int == 0, let list = root["data"]["song"]["list"].array else { continue }
            let ranked = list.compactMap { item -> (mid: String, key: RankKey)? in
                let mid = item["songmid"].text
                guard isValidMid(mid) else { return nil }
                let artist = (item["singer"].array ?? []).map { decodeEntities($0["name"].text) }.joined(separator: " / ")
                guard let key = rankKey(track,
                                        album: decodeEntities(item["albumname"].text),
                                        title: decodeEntities(item["songname"].text),
                                        artist: artist,
                                        seconds: item["interval"].float ?? 0) else { return nil }
                return (mid, key)
            }.sorted { better($0.key, $1.key) }
            for candidate in ranked {
                let reply = await getJSON("https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=\(escape(candidate.mid))&format=json&nobase64=1", headers: headers, http: http)
                guard let reply, reply["code"].int == 0 else { continue }
                let translation = decodeEntities(reply["trans"].text)
                let lines = parse(decodeEntities(reply["lyric"].text), translation: translation.isEmpty ? nil : translation)
                if !lines.isEmpty { return lines }
            }
        }
        return []
    }

    private static func isValidMid(_ value: String) -> Bool {
        (8...32).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    // MARK: - 匹配

    // 排序用的三个维度：歌手一致程度、专辑名是否一致、时长差
    private typealias RankKey = (score: Int, album: Int, distance: Double)

    private static func rankKey(_ track: Track, album: String, title: String, artist: String, seconds: Double) -> RankKey? {
        let score = matchScore(track, title: title, artist: artist, seconds: seconds)
        guard score > 0 else { return nil }
        let albumMatched = !track.album.isEmpty && !album.isEmpty && normalize(track.album) == normalize(album)
        return (score, albumMatched ? 1 : 0, track.duration > 0 ? abs(seconds - track.duration) : 0)
    }

    // 歌手完全一致优先，其次专辑名一致，最后时长最接近
    private static func better(_ lhs: RankKey, _ rhs: RankKey) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if lhs.album != rhs.album { return lhs.album > rhs.album }
        return lhs.distance < rhs.distance
    }

    // 标题必须一致；歌手按完全一致、被包含两档打分；时长相差不超过 2 秒
    private static func matchScore(_ track: Track, title: String, artist: String, seconds: Double) -> Int {
        guard normalize(track.title) == normalize(title) else { return 0 }
        if track.duration > 0 && abs(seconds - track.duration) > 2 { return 0 }
        let wanted = splitArtists(track.artist).map(normalize).filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return 1 }
        let listed = splitArtists(artist).map(normalize).filter { !$0.isEmpty }
        if Set(wanted) == Set(listed) { return 2 }
        let candidate = normalize(artist)
        for part in wanted where !candidate.contains(part) { return 0 }
        return 1
    }

    // 先用「标题 歌手 专辑」查一次，查不到再退回「标题 歌手」
    private static func searchKeywords(_ track: Track) -> [String] {
        let pair = "\(track.title) \(track.artist)"
        guard !track.album.isEmpty else { return [pair] }
        return ["\(pair) \(track.album)", pair]
    }

    private static func splitArtists(_ value: String) -> [String] {
        value.split(whereSeparator: { "/、,，&;；".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func normalize(_ value: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if CharacterSet.punctuationCharacters.contains(scalar) { continue }
            if CharacterSet.symbols.contains(scalar) { continue }
            kept.append(scalar)
        }
        return String(kept).uppercased()
    }

    // MARK: - 请求

    private static func getJSON(_ url: String, headers: [String: String], http: HTTPClient) async -> JSONValue? {
        var client = http
        client.timeout = timeout
        guard let response = try? await client.get(url, headers: headers) else { return nil }
        guard (200..<300).contains(response.status) else { return nil }
        return try? response.json()
    }

    private static func escape(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.3f", value)
    }

    // MARK: - LRC

    private static func parse(_ lrc: String, translation: String?) -> [LyricLine] {
        let stamped = stampedLines(lrc)
        guard !stamped.isEmpty else { return [] }
        let translated = translation.map { stampedLines($0) } ?? []
        var result: [LyricLine] = []
        var seen = Set<String>()
        for item in stamped.sorted(by: { $0.time < $1.time }) {
            guard isLyricText(item.text) else { continue }
            guard seen.insert("\(item.time)|\(item.text)").inserted else { continue }
            result.append(LyricLine(time: item.time,
                                    text: item.text,
                                    translation: translatedText(translated, at: item.time, text: item.text)))
        }
        return result
    }

    private static func stampedLines(_ lrc: String) -> [(time: Double, text: String)] {
        guard !lrc.isEmpty else { return [] }
        let offset = offsetSeconds(lrc)
        guard let regex = try? NSRegularExpression(pattern: "\\[(\\d{1,3}):(\\d{2})(?:[.:](\\d{1,3}))?\\]") else { return [] }
        var result: [(time: Double, text: String)] = []
        for row in lrc.components(separatedBy: .newlines) {
            let range = NSRange(row.startIndex..., in: row)
            let stamps = regex.matches(in: row, range: range)
            guard let last = stamps.last, let textRange = Range(last.range, in: row) else { continue }
            let line = String(row[textRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            for stamp in stamps {
                let minutes = matched(row, stamp.range(at: 1)).flatMap(Int.init) ?? 0
                let seconds = matched(row, stamp.range(at: 2)).flatMap(Int.init) ?? 0
                var fraction = 0.0
                if let digits = matched(row, stamp.range(at: 3)) { fraction = Double("0." + digits) ?? 0 }
                result.append((max(0, Double(minutes) * 60 + Double(seconds) + fraction + offset), line))
            }
        }
        return result
    }

    private static func matched(_ row: String, _ range: NSRange) -> String? {
        guard range.location != NSNotFound, let range = Range(range, in: row) else { return nil }
        return String(row[range])
    }

    private static func offsetSeconds(_ lrc: String) -> Double {
        guard let regex = try? NSRegularExpression(pattern: "\\[offset:([+-]?\\d+)\\]", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: lrc, range: NSRange(lrc.startIndex..., in: lrc)),
              let text = Range(match.range(at: 1), in: lrc),
              let milliseconds = Double(lrc[text]) else { return 0 }
        return milliseconds / 1000
    }

    // 纯音乐提示与空行都不是可显示的一行歌词
    private static func isLyricText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "♪" { return false }
        if trimmed.contains("纯音乐") { return false }
        return true
    }

    private static func translatedText(_ lines: [(time: Double, text: String)], at time: Double, text: String) -> String? {
        var best: (distance: Double, text: String)?
        for item in lines where isLyricText(item.text) {
            let distance = abs(item.time - time)
            guard distance <= 0.3 else { continue }
            if best == nil || distance < best!.distance { best = (distance, item.text) }
        }
        guard let value = best?.text, value != text else { return nil }
        return value
    }

    // MARK: - 实体

    // 搜索结果与歌词里的 &amp; 等实体需要还原，否则标题匹配会失败
    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard let amp = text[index...].firstIndex(of: "&") else {
                result += text[index...]
                break
            }
            result += text[index..<amp]
            guard let semi = text[amp...].firstIndex(of: ";"), text.distance(from: amp, to: semi) <= 10,
                  let decoded = entity(String(text[text.index(after: amp)..<semi])) else {
                result.append("&")
                index = text.index(after: amp)
                continue
            }
            result += decoded
            index = text.index(after: semi)
        }
        return result
    }

    private static func entity(_ body: String) -> String? {
        switch body.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default: break
        }
        let digits: String
        let radix: Int
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            digits = String(body.dropFirst(2))
            radix = 16
        } else if body.hasPrefix("#") {
            digits = String(body.dropFirst())
            radix = 10
        } else {
            return nil
        }
        guard let value = UInt32(digits, radix: radix), let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }
}
