//
//  OSC.swift
//  NpcLab
//
//  解析 Linux 侧发上来的 OSC 1337 序列。
//
//  这是 Minis 那套「用终端驱动原生 UI」的机制，协议取自 iTerm2：
//
//      ESC ] 1337 ; NpcLabOpenURL = <url> BEL
//       0x1B 0x5D                       ...  0x07
//
//  Linux 里任何程序往 stdout 打这段字节，宿主把它从显示内容里剥掉，
//  再按 URL 类型弹原生界面。终端里因此不会出现乱码。
//
//  需要跨 chunk：序列可能被内核的 pty 缓冲区切成两半，所以状态要留在
//  结构体里，不能每次 feed 重新开始。
//

import Foundation

// MARK: - 扫描结果

struct OSCScanResult {
    /// 剥掉标记后的字节，可以直接上屏
    var clean: Data
    /// 本次解析出来的打开请求，按出现顺序
    var opens: [String]
}

// MARK: - 扫描器

struct OSCScanner {

    private static let bel: UInt8 = 0x07          // BEL
    private static let esc: UInt8 = 0x1B          // ESC
    private static let rbra: UInt8 = 0x5D         // ']'
    private static let bslash: UInt8 = 0x5C       // '\'

    private static let openPrefix = "1337;NpcLabOpenURL="

    /// 上一个 chunk 末尾孤立的一个 ESC，等下一个 chunk 才知道是不是 "]"
    private var tail = Data()
    /// 当前是否在 OSC 序列内部
    private var inSeq = false
    /// 已累积的 payload（不含 ESC ] 前缀）
    private var seq = Data()

    /// 喂一段原始字节，返回可上屏的部分 + 打开请求
    mutating func feed(_ data: Data) -> OSCScanResult {
        var out = Data()
        var opens: [String] = []

        var buf = Data()
        buf.append(tail)
        buf.append(data)
        tail.removeAll(keepingCapacity: true)

        var i = buf.startIndex
        while i < buf.endIndex {
            let b = buf[i]

            if !inSeq {
                if b == Self.esc {
                    // 需要看下一个字节才能判断是 OSC 还是普通转义
                    if i + 1 >= buf.endIndex {
                        tail.append(b)          // 留到下次
                        break
                    }
                    if buf[i + 1] == Self.rbra {
                        inSeq = true
                        seq.removeAll(keepingCapacity: true)
                        i += 2
                        continue
                    }
                    // 普通转义（颜色等），原样透传
                    out.append(b)
                    i += 1
                    continue
                }
                out.append(b)
                i += 1
                continue
            }

            // ---- 序列内部 ----
            if b == Self.bel {
                close(&out, &opens)
                i += 1
                continue
            }
            if b == Self.esc {
                // ST = ESC \ 也可以收尾
                if i + 1 >= buf.endIndex {
                    tail.append(b)              // 半个 ST，等下次
                    break
                }
                if buf[i + 1] == Self.bslash {
                    close(&out, &opens)
                    i += 2
                    continue
                }
                // 序列里出现别的 ESC：当作异常，放弃这个序列的解析
                // 但字节不能丢，原样吐出去
                emitRaw(&out)
                inSeq = false
                continue
            }
            seq.append(b)
            i += 1
        }

        return OSCScanResult(clean: out, opens: opens)
    }

    /// 清空状态（重新 boot 时调）
    mutating func reset() {
        tail.removeAll()
        seq.removeAll()
        inSeq = false
    }

    // MARK: 内部

    private mutating func close(_ out: inout Data, _ opens: inout [String]) {
        defer {
            inSeq = false
            seq.removeAll(keepingCapacity: true)
        }

        guard let s = String(data: seq, encoding: .utf8) else {
            emitRaw(&out)
            return
        }

        if s.hasPrefix(Self.openPrefix) {
            let url = String(s.dropFirst(Self.openPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty { opens.append(url) }
            return                           // 剥掉，不上屏
        }

        // 其它 OSC（窗口标题、超链接）保留原样
        out.append(Self.esc)
        out.append(Self.rbra)
        out.append(seq)
        out.append(Self.bel)
    }

    private func emitRaw(_ out: inout Data) {
        out.append(Self.esc)
        out.append(Self.rbra)
        out.append(seq)
    }
}

// MARK: - 打开请求

/// 宿主拿到一条 URL 后决定用什么界面。判定顺序按扩展名，最后退回分享面板。
enum OpenKind {
    case web                    // http / https → WKWebView
    case image                  // png / jpg / gif / webp / heic
    case pdf                    // pdf → QuickLook
    case markdown               // md → 文本预览
    case text                   // 其它文本
    case office                 // doc / xlsx / pptx → QuickLook
    case media                  // mp4 / mp3 → AVPlayer
    case archive                // zip / tar / gz
    case file                   // 其它本地文件 → 分享面板
}

struct OpenRequest: Identifiable, Equatable {
    let id = UUID()
    let url: String
    let kind: OpenKind

    /// 本地路径（file:// 或绝对路径）返回 URL，网页返回 nil
    var fileURL: URL? {
        if url.hasPrefix("file://") {
            return URL(string: url)
        }
        if url.hasPrefix("/") {
            return URL(fileURLWithPath: url)
        }
        return nil
    }

    var title: String {
        if let f = fileURL { return f.lastPathComponent }
        return url
    }

    static func classify(_ raw: String) -> OpenRequest {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("about:") {
            return OpenRequest(url: s, kind: .web)
        }
        if s.hasPrefix("mailto:") || s.hasPrefix("tel:") || s.hasPrefix("sms:") {
            return OpenRequest(url: s, kind: .web)
        }

        let path = s.hasPrefix("file://")
            ? (URL(string: s)?.path ?? s)
            : s
        let ext = (path as NSString).pathExtension.lowercased()

        let kind: OpenKind
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff":
            kind = .image
        case "pdf":
            kind = .pdf
        case "md", "markdown":
            kind = .markdown
        case "txt", "log", "json", "xml", "yml", "yaml", "sh", "c", "h",
             "py", "js", "ts", "swift", "go", "rs", "rb", "java", "kt":
            kind = .text
        case "doc", "docx", "xls", "xlsx", "ppt", "pptx", "rtf", "pages", "numbers", "key":
            kind = .office
        case "mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac", "flac":
            kind = .media
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "ipa":
            kind = .archive
        default:
            kind = .file
        }
        return OpenRequest(url: s, kind: kind)
    }
}
