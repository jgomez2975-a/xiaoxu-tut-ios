//
//  X509Builder.swift
//  NpcLab
//
//  手写最小 X.509 v3 证书 DER 编码器 + RSA 签名。
//
//  iOS 没有 OpenSSL，Security 框架又只读不写证书，所以这里自己按 ASN.1 DER
//  拼一张证书：TBSCertificate → 用 RSA 私钥 SHA256 签名 → 包进 Certificate。
//  支持自签根 CA（isCA）与用 CA 签的叶子证书（带 subjectAltName）。
//

import Foundation
import Security

enum X509Builder {

    // MARK: - DER 基本类型

    private static func len(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var v = n, bytes: [UInt8] = []
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        return [UInt8(0x80 | bytes.count)] + bytes
    }

    private static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + len(content.count) + content
    }

    private static func int(_ n: UInt64) -> [UInt8] {
        if n == 0 { return [0] }
        var v = n, b: [UInt8] = []
        while v > 0 { b.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        if b[0] & 0x80 != 0 { b.insert(0, at: 0) }
        return b
    }

    private static func seq(_ items: [[UInt8]]) -> [UInt8] {
        tlv(0x30, items.flatMap { $0 })
    }

    private static func set(_ items: [[UInt8]]) -> [UInt8] {
        tlv(0x31, items.flatMap { $0 })
    }

    private static func oid(_ dotted: String) -> [UInt8] {
        let comps = dotted.split(separator: ".").map { Int($0)! }
        var enc: [UInt8] = [UInt8(comps[0] * 40 + comps[1])]
        for c in comps.dropFirst(2) {
            var v = c, stack: [UInt8] = [UInt8(v & 0x7f)]
            v >>= 7
            while v > 0 { stack.insert(UInt8((v & 0x7f) | 0x80), at: 0); v >>= 7 }
            enc.append(contentsOf: stack)
        }
        return tlv(0x06, enc)
    }

    private static func utf8(_ s: String) -> [UInt8] {
        tlv(0x0c, Array(s.utf8))
    }

    private static func ia5(_ s: String) -> [UInt8] {
        tlv(0x16, Array(s.utf8))
    }

    private static func nullVal() -> [UInt8] { tlv(0x05, []) }

    private static func bitString(_ bytes: [UInt8], unused: UInt8 = 0) -> [UInt8] {
        tlv(0x03, [unused] + bytes)
    }

    // MARK: - 算法标识

    // sha256WithRSAEncryption = 1.2.840.113549.1.1.11
    private static func sha256RSAAlgID() -> [UInt8] {
        seq([oid("1.2.840.113549.1.1.11"), nullVal()])
    }

    // rsaEncryption = 1.2.840.113549.1.1.1
    private static func rsaAlgID() -> [UInt8] {
        seq([oid("1.2.840.113549.1.1.1"), nullVal()])
    }

    // MARK: - 名称 (subject/issuer)

    private static func name(_ cn: String) -> [UInt8] {
        // RDN: CN=cn  (oid 2.5.4.3)
        let attr = seq([oid("2.5.4.3"), utf8(cn)])
        return seq([set([attr])])
    }

    // MARK: - 有效期

    private static func timeValidity(days: Int) -> [UInt8] {
        let now = Date()
        let notBefore = now.addingTimeInterval(-3600)
        let notAfter = now.addingTimeInterval(Double(days) * 86400)
        let f = DateFormatter()
        f.dateFormat = "yyMMddHHmmssZ"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        let nb = f.string(from: notBefore)
        let na = f.string(from: notAfter)
        return seq([
            tlv(0x17, Array(nb.utf8)),  // UTCTime
            tlv(0x17, Array(na.utf8)),
        ])
    }

    // MARK: - SubjectPublicKeyInfo

    private static func spki(_ key: SecKey) -> [UInt8] {
        // 从 SecKey 拿 RSA 公钥的 (n, e)
        guard let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            return seq([rsaAlgID(), bitString([])])
        }
        // ExternalRepresentation 对 RSA 是 PKCS#1: SEQUENCE { n INTEGER, e INTEGER }
        let bytes = [UInt8](data)
        guard bytes.count > 10 else { return seq([rsaAlgID(), bitString([])]) }
        var idx = 0
        // 跳过外层 SEQUENCE 头
        _ = bytes[idx]; idx += 1
        var outerLen = Int(bytes[idx]); idx += 1
        if outerLen & 0x80 != 0 { let c = outerLen & 0x7f; outerLen = 0; for _ in 0..<c { outerLen = (outerLen << 8) | Int(bytes[idx]); idx += 1 } }
        // 读 modulus（第一个 INTEGER）
        let nVal = readDERInt(bytes, &idx)
        // 读 exponent（第二个 INTEGER）
        let eVal = readDERInt(bytes, &idx)
        let pubKey = seq([intBig(nVal), intBig(eVal)])
        return seq([rsaAlgID(), bitString(pubKey)])
    }

    private static func readDERInt(_ bytes: [UInt8], _ i: inout Int) -> [UInt8] {
        _ = bytes[i]; i += 1
        var l = Int(bytes[i]); i += 1
        if l & 0x80 != 0 { let c = l & 0x7f; l = 0; for _ in 0..<c { l = (l << 8) | Int(bytes[i]); i += 1 } }
        let val = Array(bytes[i..<i + l]); i += l
        return val
    }

    private static func intBig(_ b: [UInt8]) -> [UInt8] {
        var v = b
        if v.count > 0 && v[0] & 0x80 != 0 { v.insert(0, at: 0) }
        return tlv(0x02, v)
    }

    // MARK: - 扩展

    private static func basicConstraints(isCA: Bool) -> [UInt8] {
        // BasicConstraints ::= SEQUENCE { cA BOOLEAN DEFAULT FALSE }
        let bc = seq([tlv(0x01, isCA ? [0xff] : [0x00])])
        return seq([oid("2.5.29.19"), tlv(0x01, [0xff]), tlv(0x04, bc)]) // critical
    }

    private static func keyUsage(isCA: Bool) -> [UInt8] {
        // keyCertSign + cRLSign (CA)；digitalSignature + keyEncipherment (leaf)
        let k = isCA ? UInt8(0b00000110) : UInt8(0b10100000)
        let ku = bitString([k], unused: 1)
        return seq([oid("2.5.29.15"), tlv(0x01, [0xff]), tlv(0x04, ku)])
    }

    private static func subjectAltName(host: String) -> [UInt8] {
        let dns = tlv(0x82, Array(host.utf8)) // [2] dNSName
        let gen = tlv(0x30, dns)
        return seq([oid("2.5.29.17"), tlv(0x04, gen)])
    }

    private static func extKeyUsageServerAuth() -> [UInt8] {
        // serverAuth = 1.3.6.1.5.5.7.3.1
        let eku = seq([oid("1.3.6.1.5.5.7.3.1")])
        return seq([oid("2.5.29.37"), tlv(0x04, eku)])
    }

    // MARK: - 主入口

    static func build(subject: String, publicKey: SecKey, isCA: Bool, days: Int,
                      host: String?, signerCert: SecCertificate?,
                      signerKey: SecKey?) -> Data {
        // 签发者：有 signerCert 用它，否则自签（用 subject 自身）
        let issuerCN = signerCert != nil ? subjectOf(signerCert!) : subject

        var exts: [[UInt8]] = [
            basicConstraints(isCA: isCA),
            keyUsage(isCA: isCA),
        ]
        if isCA {
            // CA 还需要 subjectKeyIdentifier，这里略，够用
        } else if let h = host {
            exts.append(subjectAltName(host: h))
            exts.append(extKeyUsageServerAuth())
        }

        let extensions = seq([
            seq(exts.map { $0 })
        ])

        let tbs = seq([
            tlv(0xa0, [2]),                    // version v3 (explicit [0] = 2)
            int(UInt64.random(in: 1...0xffffffff)),  // serialNumber
            sha256RSAAlgID(),                  // signature
            name(issuerCN),                    // issuer
            timeValidity(days: days),          // validity
            name(subject),                     // subject
            spki(publicKey),                   // subjectPublicKeyInfo
            tlv(0xa3, extensions),             // extensions [3]
        ])

        // 签名：TBS 用 SHA256，RSA 私钥签名
        let signingKey = signerKey ?? publicKey
        let sig = rsaSign(tbs, key: signingKey)

        let cert = seq([
            tbs,
            sha256RSAAlgID(),
            bitString(sig),
        ])
        return Data(cert)
    }

    private static func subjectOf(_ cert: SecCertificate) -> String {
        guard let s = SecCertificateCopySubjectSummary(cert) else { return "Unknown" }
        return s as String
    }

    // MARK: - RSA 签名

    private static func rsaSign(_ tbs: [UInt8], key: SecKey) -> [UInt8] {
        // .rsaSignatureMessagePKCS1v15SHA256 会先对 message 做 SHA256 再 RSA 签名，
        // 所以这里直接传原始 TBS，不要自己再 pre-hash（否则双重哈希）。
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(tbs) as CFData,
            &error
        ) as Data? else {
            return []
        }
        return [UInt8](sig)
    }

    private static func sha256(_ d: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        d.withUnsafeBytes { p in
            _ = CC_SHA256(p.baseAddress, CC_LONG(d.count), &digest)
        }
        return Data(digest)
    }
}
