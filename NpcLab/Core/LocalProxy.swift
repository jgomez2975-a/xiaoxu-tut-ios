//
//  LocalProxy.swift
//  NpcLab
//
//  本机 HTTP 代理。跑在 App 进程里，不依赖 PC 节点。
//
//  能力边界（写清楚，别让人以为能解密全部流量）：
//    · HTTP：完整抓取 + 改头 + 改正文，规则命中才改写，其余原样放过
//    · HTTPS：CONNECT 盲隧道。能看到域名、字节数、耗时，看不到明文
//      （要看明文必须做 MITM，那需要往手机上装自签 CA，属于下一步）
//
//  用法：设置 → 无线局域网 → 当前网络 → 配置代理 → 手动 →
//        服务器 127.0.0.1，端口就是这里开的那个。
//
//  实现：BSD socket + poll 双向转发。没引入 NIO，因为这点流量不值得多一层。
//

import Foundation
import Combine

struct ProxyHit: Identifiable {
    let id = UUID()
    var ts = Date()
    var method = ""
    var url = ""
    var status = 0
    var bytes = 0
    var ms = 0
    var tunnel = false
    var hits: [String] = []
    var note = ""
}

final class LocalProxy: ObservableObject {

    static let shared = LocalProxy()

    @Published private(set) var running = false
    @Published private(set) var port = 8888
    @Published private(set) var hits: [ProxyHit] = []
    @Published private(set) var lastError = ""

    /// 由界面同步进来；规则只在请求/响应经过时读一次
    var rules: [ProxyRule] = []

    private var lfd: Int32 = -1
    private let acceptQ = DispatchQueue(label: "npclab.proxy.accept")
    private let ioQ = DispatchQueue(label: "npclab.proxy.io", attributes: .concurrent)
    private let maxHits = 300

    // MARK: 生命周期

    @discardableResult
    func start(_ p: Int) -> String? {
        if running { stop() }
        guard p > 0 && p < 65536 else { return "端口不合法" }

        let fd = makeListener(p)
        guard fd >= 0 else {
            let msg = "端口 \(p) 起不来（\(String(cString: strerror(errno)))）"
            DispatchQueue.main.async { self.lastError = msg }
            return msg
        }
        lfd = fd
        port = p
        running = true
        lastError = ""
        NpcLog.write("[proxy] listen :\(p)")

        acceptQ.async { [weak self] in
            self?.acceptLoop(fd)
        }
        return nil
    }

    func stop() {
        guard running || lfd >= 0 else { return }
        running = false
        if lfd >= 0 {
            _ = Darwin.shutdown(lfd, Int32(SHUT_RDWR))
            Darwin.close(lfd)
            lfd = -1
        }
        NpcLog.write("[proxy] stopped")
    }

    func clear() {
        hits.removeAll()
    }

    // MARK: 监听

    private func makeListener(_ p: Int) -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                   socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(p).bigEndian)
        addr.sin_addr.s_addr = INADDR_ANY

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { Darwin.close(fd); return -1 }
        guard Darwin.listen(fd, 32) == 0 else { Darwin.close(fd); return -1 }
        return fd
    }

    private func acceptLoop(_ fd: Int32) {
        while running {
            var caddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let c = withUnsafeMutablePointer(to: &caddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.accept(fd, sa, &len)
                }
            }
            if c < 0 {
                if errno == EINTR { continue }
                break
            }
            ioQ.async { [weak self] in
                self?.handleClient(c)
            }
        }
    }

    // MARK: 单条连接

    private func handleClient(_ c: Int32) {
        defer { Darwin.close(c) }
        setTimeout(c, 30)

        guard let (head, rest) = readHead(c) else { return }
        guard let text = String(data: head, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return }

        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        if method == "CONNECT" {
            tunnel(c, target)
        } else {
            forward(c, method: method, target: target, head: head, rest: rest)
        }
    }

    // MARK: HTTPS 盲隧道

    private func tunnel(_ c: Int32, _ target: String) {
        let seg = target.split(separator: ":")
        guard let host = seg.first.map(String.init), !host.isEmpty else { return }
        let port = seg.count > 1 ? (Int(seg[1]) ?? 443) : 443

        guard let up = connectHost(host, port: port) else {
            _ = sendAll(c, Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
            record(ProxyHit(method: "CONNECT", url: target, status: 502,
                            bytes: 0, ms: 0, tunnel: true, note: "连不上"))
            return
        }
        defer { Darwin.close(up) }

        _ = sendAll(c, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
        let t0 = Date()
        let bytes = relay(c, up)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        record(ProxyHit(method: "CONNECT", url: target, status: 200,
                        bytes: bytes, ms: ms, tunnel: true,
                        note: "HTTPS 隧道（明文不可见）"))
    }

    /// 双向转发：poll 等哪边可读就读哪边。用 poll 而不是两个线程，
    /// 免掉「一边关了另一边还在写」的收尾竞态。
    private func relay(_ a: Int32, _ b: Int32) -> Int {
        var total = 0
        var buf = [UInt8](repeating: 0, count: 32768)

        while running {
            var fds = [pollfd(fd: a, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: b, events: Int16(POLLIN), revents: 0)]
            let n = poll(&fds, 2, 500)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { continue }

            if fds[0].revents & Int16(POLLIN) != 0 {
                let r = buf.withUnsafeMutableBytes { p in
                    Darwin.recv(a, p.baseAddress, p.count, 0)
                }
                if r <= 0 { break }
                if !sendAll(b, Data(buf[0..<r])) { break }
                total += r
            }
            if fds[1].revents & Int16(POLLIN) != 0 {
                let r = buf.withUnsafeMutableBytes { p in
                    Darwin.recv(b, p.baseAddress, p.count, 0)
                }
                if r <= 0 { break }
                if !sendAll(a, Data(buf[0..<r])) { break }
                total += r
            }
            if fds[0].revents & Int16(POLLHUP | POLLERR) != 0 { break }
            if fds[1].revents & Int16(POLLHUP | POLLERR) != 0 { break }
        }
        return total
    }

    // MARK: 明文 HTTP

    private func forward(_ c: Int32, method: String, target: String,
                         head: Data, rest: Data) {
        let t0 = Date()
        guard let u = URL(string: target), let host = u.host else {
            _ = sendAll(c, Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8))
            return
        }
        let port = u.port ?? 80
        var path = u.path.isEmpty ? "/" : u.path
        if let q = u.query, !q.isEmpty { path += "?" + q }
        let fullURL = "http://\(host)\(port == 80 ? "" : ":\(port)")\(path)"

        var headers = parseHeaders(head)
        let clen = Int(headers.first { $0.0.lowercased() == "content-length" }?.1 ?? "0") ?? 0
        var body = rest
        if clen > 0 && body.count < clen {
            if let more = readExactly(c, clen - body.count) { body.append(more) }
        } else if clen == 0 {
            body = Data()
        }

        var hitNames: [String] = []
        var ctype = headers.first { $0.0.lowercased() == "content-type" }?.1 ?? ""

        // --- 请求阶段规则 ---
        for r in rules where r.on && (r.phase == "req" || r.phase == "both") {
            guard matchURL(r.url, fullURL) else { continue }
            hitNames.append(r.name.isEmpty ? "req" : r.name)

            for (k, v) in parseHeaderLines(r.setHeader) {
                if let i = headers.firstIndex(where: { $0.0.lowercased() == k.lowercased() }) {
                    headers[i].1 = v
                } else {
                    headers.append((k, v))
                }
            }
            if !r.bodyMatch.isEmpty, let text = String(data: body, encoding: .utf8),
               let replaced = replaceAll(r.bodyMatch, text, with: r.bodyReplace) {
                body = Data(replaced.utf8)
            }
        }

        // --- 组上游请求 ---
        var out = Data()
        out.append(Data("\(method) \(path) HTTP/1.1\r\n".utf8))
        let keep = headers.filter {
            let k = $0.0.lowercased()
            return k != "proxy-connection" && k != "connection"
                && k != "proxy-authorization" && k != "content-length"
        }
        for (k, v) in keep {
            out.append(Data("\(k): \(v)\r\n".utf8))
        }
        if !body.isEmpty {
            out.append(Data("Content-Length: \(body.count)\r\n".utf8))
        }
        out.append(Data("Connection: close\r\n\r\n".utf8))
        out.append(body)

        guard let up = connectHost(host, port: port) else {
            _ = sendAll(c, Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
            record(ProxyHit(method: method, url: fullURL, status: 502,
                            bytes: 0, ms: 0, note: "上游连不上"))
            return
        }
        defer { Darwin.close(up) }

        guard sendAll(up, out) else {
            _ = sendAll(c, Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8))
            return
        }
        guard let resp = readAll(up) else { return }

        // --- 拆响应 ---
        guard let sep = resp.range(of: Data("\r\n\r\n".utf8)) else {
            _ = sendAll(c, resp)
            return
        }
        let respHead = resp.subdata(in: 0..<sep.lowerBound)
        var respBody = resp.subdata(in: sep.upperBound..<resp.count)
        let respLines = String(data: respHead, encoding: .utf8)?
            .components(separatedBy: "\r\n") ?? []
        var status = 0
        if let l = respLines.first {
            let p = l.split(separator: " ")
            if p.count >= 2 { status = Int(p[1]) ?? 0 }
        }
        var respHeaders = parseHeaders(respHead)
        let te = respHeaders.first { $0.0.lowercased() == "transfer-encoding" }?.1.lowercased() ?? ""
        let ce = respHeaders.first { $0.0.lowercased() == "content-encoding" }?.1.lowercased() ?? ""
        let rctype = respHeaders.first { $0.0.lowercased() == "content-type" }?.1 ?? ""
        if te.contains("chunked") { respBody = dechunk(respBody) }

        // --- 响应阶段规则 ---
        var touched = false
        for r in rules where r.on && (r.phase == "res" || r.phase == "both") {
            guard matchURL(r.url, fullURL) else { continue }
            hitNames.append(r.name.isEmpty ? "res" : r.name)
            if !r.setHeader.isEmpty { touched = true }

            // 压缩过的正文改不了：gzip 的字节流替换会直接毁掉内容
            if !r.bodyMatch.isEmpty, ce.isEmpty,
               let text = String(data: respBody, encoding: .utf8),
               let replaced = replaceAll(r.bodyMatch, text, with: r.bodyReplace) {
                respBody = Data(replaced.utf8)
                touched = true
            }
        }

        if touched && ce.isEmpty {
            var rebuilt = Data()
            let statusLine = respLines.first ?? "HTTP/1.1 200 OK"
            rebuilt.append(Data((statusLine + "\r\n").utf8))
            for (k, v) in respHeaders {
                let lk = k.lowercased()
                if lk == "transfer-encoding" || lk == "content-length" || lk == "connection" { continue }
                rebuilt.append(Data("\(k): \(v)\r\n".utf8))
            }
            rebuilt.append(Data("Content-Length: \(respBody.count)\r\n".utf8))
            rebuilt.append(Data("Connection: close\r\n\r\n".utf8))
            rebuilt.append(respBody)
            _ = sendAll(c, rebuilt)
        } else {
            _ = sendAll(c, resp)
        }

        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        record(ProxyHit(method: method, url: fullURL, status: status,
                        bytes: respBody.count, ms: ms, tunnel: false,
                        hits: hitNames,
                        note: touched ? "已改写" : (ctype.isEmpty ? "" : String(ctype.prefix(30)))))
    }

    // MARK: 规则

    private func matchURL(_ pattern: String, _ url: String) -> Bool {
        if pattern.isEmpty { return true }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let r = NSRange(url.startIndex..., in: url)
        return re.firstMatch(in: url, range: r) != nil
    }

    private func replaceAll(_ pattern: String, _ text: String, with tpl: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let r = NSRange(text.startIndex..., in: text)
        guard re.firstMatch(in: text, range: r) != nil else { return nil }
        return re.stringByReplacingMatches(in: text, range: r, withTemplate: tpl)
    }

    private func parseHeaderLines(_ s: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for line in s.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            guard let i = t.firstIndex(of: ":") else { continue }
            let k = String(t[t.startIndex..<i]).trimmingCharacters(in: .whitespaces)
            let v = String(t[t.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { out.append((k, v)) }
        }
        return out
    }

    // MARK: socket 工具

    private func setTimeout(_ fd: Int32, _ sec: Int) {
        var tv = timeval(tv_sec: sec, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func connectHost(_ host: String, port: Int) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
            return nil
        }
        defer { freeaddrinfo(first) }

        var cur: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cur {
            let fd = Darwin.socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd >= 0 {
                setTimeout(fd, 20)
                if Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
                    return fd
                }
                Darwin.close(fd)
            }
            cur = ai.pointee.ai_next
        }
        return nil
    }

    private func readHead(_ fd: Int32) -> (Data, Data)? {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        let marker = Data("\r\n\r\n".utf8)
        while buf.count < 256 * 1024 {
            let n = chunk.withUnsafeMutableBytes { p in
                Darwin.recv(fd, p.baseAddress, p.count, 0)
            }
            if n <= 0 { return nil }
            buf.append(contentsOf: chunk[0..<n])
            if let r = buf.range(of: marker) {
                return (buf.subdata(in: 0..<r.upperBound),
                        buf.subdata(in: r.upperBound..<buf.count))
            }
        }
        return nil
    }

    private func readExactly(_ fd: Int32, _ n: Int) -> Data? {
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        while out.count < n {
            let want = min(chunk.count, n - out.count)
            let got = chunk.withUnsafeMutableBytes { p in
                Darwin.recv(fd, p.baseAddress, want, 0)
            }
            if got <= 0 { break }
            out.append(contentsOf: chunk[0..<got])
        }
        return out
    }

    private func readAll(_ fd: Int32) -> Data? {
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 32768)
        while true {
            let n = chunk.withUnsafeMutableBytes { p in
                Darwin.recv(fd, p.baseAddress, p.count, 0)
            }
            if n < 0 { return out.isEmpty ? nil : out }
            if n == 0 { break }
            out.append(contentsOf: chunk[0..<n])
            if out.count > 32 * 1024 * 1024 { break }
        }
        return out
    }

    @discardableResult
    private func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        let total = data.count
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            while sent < total {
                let n = Darwin.send(fd, base.advanced(by: sent), total - sent, 0)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    private func parseHeaders(_ head: Data) -> [(String, String)] {
        guard let s = String(data: head, encoding: .utf8) else { return [] }
        var out: [(String, String)] = []
        for line in s.components(separatedBy: "\r\n").dropFirst() {
            if line.isEmpty { break }
            guard let i = line.firstIndex(of: ":") else { continue }
            let k = String(line[line.startIndex..<i]).trimmingCharacters(in: .whitespaces)
            let v = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            out.append((k, v))
        }
        return out
    }

    /// 把 chunked 还原成裸正文；解析不动就原样返回
    private func dechunk(_ data: Data) -> Data {
        var out = Data()
        var i = data.startIndex
        while i < data.endIndex {
            guard let crlf = data.range(of: Data("\r\n".utf8), in: i..<data.endIndex) else { break }
            let sizeStr = String(data: data[i..<crlf.lowerBound], encoding: .utf8)?
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 16) else { break }
            if size == 0 { break }
            let start = crlf.upperBound
            let end = data.index(start, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            out.append(data[start..<end])
            i = data.index(end, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return out.isEmpty ? data : out
    }

    // MARK: 记录

    private func record(_ h: ProxyHit) {
        DispatchQueue.main.async {
            self.hits.append(h)
            if self.hits.count > self.maxHits {
                self.hits.removeFirst(self.hits.count - self.maxHits)
            }
        }
    }
}
