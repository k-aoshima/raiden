import Foundation

/// 標準アプリ以外（自作アプリなど）の説明の材料。名前と分類くらいしか手がかりが無いアプリのために、
/// Info.plist の説明・権限の説明・ソースのフォルダの README・自分で書いたメモから短い文を集める。
///   1. ~/Library/Application Support/Raiden/app-notes.json（{"bundle id か名前": "説明"}。標準アプリにも効く）
///   2. NSHumanReadableCopyright / CFBundleGetInfoString（普通の著作権表示・版番号・名前そのものは除く）
///   3. ~/Project/<アプリ名 か bundle id の末尾>（大文字小文字は区別しない）の README.md → CLAUDE.md →
///      .claude/CLAUDE.md → docs/SPEC.md のうち最初に見つかった 1 つの、最初の見出しと最初の段落（300 字まで）
///   4. NS*UsageDescription（「This app needs access to the camera」のような決まり文句は除く）
/// 2 と 4 は ja.lproj/InfoPlist.strings に日本語があればそちらを使う。2〜4 は com.apple.* には使わない（手書きの辞書がある）。
/// 名前の重みが薄まらないよう、合計 maxChars 字で打ち切る（前の材料ほど優先）。
public enum AppExtra {
    public static let maxChars = 360
    static let paraChars = 300
    static let leadChars = 150

    public struct Context {
        public var projects: [String: String]  // 小文字のフォルダ名 → パス
        public var notes: [String: String]     // 小文字のキー → 説明

        /// RAIDEN_PROJECT_DIR（既定 ~/Project）、RAIDEN_APP_NOTES（既定 Application Support/Raiden/app-notes.json）
        public static func load() -> Context {
            let env = ProcessInfo.processInfo.environment
            let fm = FileManager.default
            let root = env["RAIDEN_PROJECT_DIR"] ?? NSHomeDirectory() + "/Project"
            var projects: [String: String] = [:]
            for d in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !d.hasPrefix(".") {
                var isDir: ObjCBool = false
                let p = root + "/" + d
                if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                    projects[d.precomposedStringWithCanonicalMapping.lowercased()] = p
                }
            }
            let np = env["RAIDEN_APP_NOTES"] ?? RaidenPaths.support.appendingPathComponent("app-notes.json").path
            var notes: [String: String] = [:]
            if let d = fm.contents(atPath: np),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                for (k, v) in o {
                    if let s = v as? String { notes[k.precomposedStringWithCanonicalMapping.lowercased()] = s }
                }
            }
            return Context(projects: projects, notes: notes)
        }
    }

    static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    static func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    static let copyrightRe = re(#"copyright|©|ⓒ|\(c\)|all rights|licen[cs]e|\bgpl\b|^\s*\d"#)
    static let usageBoilerRe = re(
        #"^this app (needs|requires) access to (the |your )?[\w ]+\.?$|^a program running within|^an application in|"#
        + #"^a feature in .* is requesting|extension wants to|^the operation being performed|アクセス(が|を)(必要|許可)"#)
    static let linkRe = try! NSRegularExpression(pattern: #"!?\[([^\]]*)\]\([^)]*\)"#)

    static func clean(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// 権限の説明が「何のために使うか」を言っているか
    static func meaningfulUsage(_ key: String, _ v: String) -> Bool {
        if v.isEmpty || v == key || v.hasPrefix("NS") || matches(usageBoilerRe, v) { return false }
        if v.allSatisfy({ $0.isASCII }) && v.count < 45 { return false }  // 英語の短いものはほぼ決まり文句
        return true
    }

    /// 著作権表示・版番号・名前そのものではない説明か
    static func meaningfulInfo(_ v: String, names: [String]) -> Bool {
        if v.count < 4 || matches(copyrightRe, v) { return false }
        let n = Describe.normalize(v)
        return !names.contains { Describe.normalize($0) == n }
    }

    public static func text(path: String, info: [String: Any], bundleID bid: String, names: [String], ctx: Context) -> String {
        var parts: [String] = []
        let tail = String(bid.split(separator: ".").last ?? "")
        if let n = (names + [bid, tail]).lazy.compactMap({ ctx.notes[$0.lowercased()] }).first {
            parts.append(clean(n))
        }
        if !bid.hasPrefix("com.apple.") {
            var merged = info
            for lp in ["ja.lproj", "Japanese.lproj"] {
                if let d = NSDictionary(contentsOfFile: path + "/Contents/Resources/\(lp)/InfoPlist.strings") as? [String: Any] {
                    for (k, v) in d { merged[k] = v }
                    break
                }
            }
            for k in ["NSHumanReadableCopyright", "CFBundleGetInfoString"] {
                if let v = (merged[k] as? String).map(clean), meaningfulInfo(v, names: names), !parts.contains(v) {
                    parts.append(v)
                }
            }
            if let dir = (names + [tail]).lazy.compactMap({ ctx.projects[$0.lowercased()] }).first,
               let r = projectSummary(dir, names: names) {
                parts.append(r)
            }
            // 広告の追跡（NSUserTracking）は何をするアプリかを言っていないので使わない
            for k in merged.keys.sorted() where k.hasPrefix("NS") && k.hasSuffix("UsageDescription")
                && k != "NSUserTrackingUsageDescription" {
                if let v = (merged[k] as? String).map(clean), meaningfulUsage(k, v), !parts.contains(v) {
                    parts.append(v)
                }
            }
        }
        var out = ""
        for p in parts {
            let room = maxChars - out.count - (out.isEmpty ? 0 : 1)
            if room < 8 { break }
            out += (out.isEmpty ? "" : " ") + String(p.prefix(room))
        }
        return out
    }

    /// ソースのフォルダの README などから、最初の見出しと最初の段落
    static func projectSummary(_ dir: String, names: [String]) -> String? {
        let top = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        var cands: [String] = []
        if let r = top.first(where: { $0.lowercased() == "readme.md" }) { cands.append(r) }
        cands += ["CLAUDE.md", ".claude/CLAUDE.md", "docs/SPEC.md"]
        for c in cands {
            guard let h = FileHandle(forReadingAtPath: dir + "/" + c) else { continue }
            let data = h.readData(ofLength: 16_384)
            try? h.close()
            if let r = markdownLead(String(decoding: data, as: UTF8.self), names: names) { return r }
        }
        return nil
    }

    static func markdownLead(_ s: String, names: [String]) -> String? {
        var heading = ""
        var para: [String] = []
        var inCode = false
        for raw in s.components(separatedBy: .newlines) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("```") {
                if !para.isEmpty { break }
                inCode.toggle(); continue
            }
            if inCode { continue }
            if l.hasPrefix("#") {
                if !para.isEmpty { break }
                if heading.isEmpty { heading = l.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
                continue
            }
            if l.isEmpty {
                if !para.isEmpty { break }
                continue
            }
            if l.hasPrefix("|") || l.hasPrefix(">") || l.hasPrefix("<") || l.hasPrefix("![")
                || l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("---") {
                if !para.isEmpty { break }
                continue
            }
            para.append(l)
        }
        var p = para.joined(separator: " ")
        p = linkRe.stringByReplacingMatches(in: p, range: NSRange(p.startIndex..., in: p), withTemplate: "$1")
        p = p.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        p = clean(String(p.prefix(paraChars)))
        // 長い段落は文の切れ目で短くする（後ろの文ほど構成や使い方の話になり、名前の重みを薄めるだけ）
        if p.count > leadChars {
            var cut = ""
            for sent in p.split(separator: "。", omittingEmptySubsequences: true) {
                cut += sent + "。"
                if cut.count >= leadChars { break }
            }
            p = cut
        }
        let h = clean(heading)
        let hn = Describe.normalize(h)
        let useH = !h.isEmpty && hn != "claude.md" && !names.contains { Describe.normalize($0) == hn }
        let out = [useH ? h : "", p].filter { !$0.isEmpty }.joined(separator: " ")
        return out.isEmpty ? nil : out
    }
}
