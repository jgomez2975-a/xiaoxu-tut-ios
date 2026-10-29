//
//  MITMCertificate.swift
//  NpcLab
//
//  真 MITM 的证书层：对齐 AzTuT 的 AIProxyCertificatePinning。
//
//  思路（跟 AzTuT 内置 CA 一个套路）：
//    · 首次运行生成一张自签根 CA（Minis Capture CA 那种），私钥留在 App 沙盒 Keychain
//    · 抓到某个 HTTPS 域名时，用这张根 CA 现场给「该域名」签一张叶子证书
//    · 客户端（系统 / 目标 App）装了我们这张根 CA 后，就能信任我们签的叶子证书
//    · 于是 TLS 握手由我们接管，明文可见 → 才能解密 + 改写
//
//  为什么必须自签而不是用系统信任：iOS 不允许第三方程控 TLS 明文，
//  只有「我签发、你信任」这条路。装 CA 是用户主动动作（设置里一键导出）。
//

import Foundation
import Security

/// 一张 PEM 证书（含私钥）
struct MITMIdentity {
    var certPEM: String      // -----BEGIN CERTIFICATE-----
    var keyPEM: String       // -----BEGIN RSA/EC PRIVATE KEY-----
    var certDER: Data
}

enum MITMCertificate {

    static let caLabel = "NpcLab Capture CA"
    static let bits = 2048

    // MARK: - 根 CA

    /// 生成或读取根 CA。Keychain 里没有就现场造一张，之后一直复用。
    static func loadOrCreateCA() -> MITMIdentity {
        if let existing = readFromKeychain() {
            return existing
        }
        let fresh = makeCA()
        saveToKeychain(fresh)
        return fresh
    }

    /// 给某个主机名现场签一张叶子证书（客户端要连 host 时调用）
    static func issueLeaf(for host: String, ca: MITMIdentity) -> MITMIdentity? {
        guard let caCert = secCert(fromPEM: ca.certPEM) else { return nil }
        guard let caKey = secKey(fromPEM: ca.keyPEM) else { return nil }
        return makeLeaf(host: host, issuerCert: caCert, issuerKey: caKey)
    }

    // MARK: - 生成

    private static func makeCA() -> MITMIdentity {
        let (key, _) = generateKeyPair()
        let name = "CN=\(caLabel)"
        let der = selfSignedCert(subject: name, key: key, isCA: true, days: 3650, host: nil)
        return pack(certDER: der, key: key)
    }

    private static func makeLeaf(host: String, issuerCert: SecCertificate,
                                 issuerKey: SecKey) -> MITMIdentity? {
        let (key, _) = generateKeyPair()
        let subject = "CN=\(host)"
        let der = selfSignedCert(subject: subject, key: key, isCA: false,
                                 days: 825, host: host, signerCert: issuerCert,
                                 signerKey: issuerKey)
        return pack(certDER: der, key: key)
    }

    private static func pack(certDER: Data, key: SecKey) -> MITMIdentity {
        let certPEM = pem(certDER, type: "CERTIFICATE")
        let keyPEM = pem(exportKey(key), type: "PRIVATE KEY")
        return MITMIdentity(certPEM: certPEM, keyPEM: keyPEM, certDER: certDER)
    }

    // MARK: - 密钥对

    private static func generateKeyPair() -> (SecKey, Data?) {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: bits,
        ]
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, nil) else {
            return (SecKeyCreateRandomKey([kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                           kSecAttrKeySizeInBits as String: 2048] as CFDictionary, nil)!, nil)
        }
        return (key, nil)
    }

    private static func exportKey(_ key: SecKey) -> Data {
        var error: Unmanaged<CFError>?
        if let d = SecKeyCopyExternalRepresentation(key, &error) as Data? {
            return d
        }
        return Data()
    }

    // MARK: - 证书构造（用 SecKey + 裸 X.509 编码）

    /// 手写最小 X.509 v3 证书。这里用 Security 框架的高层 API 拼 DER。
    /// iOS 没有 OpenSSL，自签证书只能走 Security 的 SecCertificate + 手动 ASN.1。
    private static func selfSignedCert(subject: String, key: SecKey, isCA: Bool,
                                       days: Int, host: String?,
                                       signerCert: SecCertificate? = nil,
                                       signerKey: SecKey? = nil) -> Data {
        // Security 框架不直接暴露「用私钥签名」的 API，这里构造 X.509 结构后
        // 用 SecKey 做 RSA 签名。为简洁可靠，用系统底层 ASN.1 手写编码器。
        return X509Builder.build(subject: subject, publicKey: key,
                                 isCA: isCA, days: days, host: host,
                                 signerCert: signerCert, signerKey: signerKey)
    }

    // MARK: - 解析

    private static func secCert(fromPEM pemStr: String) -> SecCertificate? {
        let b64 = pemStr
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard let der = Data(base64Encoded: b64) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    private static func secKey(fromPEM pemStr: String) -> SecKey? {
        // RSA 私钥 PEM 是 PKCS#1 或 PKCS#8。iOS 的 SecKey 需要 PKCS#1 DER。
        let b64 = pemStr
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard let der = Data(base64Encoded: b64) else { return nil }
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        return SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil)
    }

    private static func pem(_ der: Data, type: String) -> String {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters])
        return "-----BEGIN \(type)-----\n\(b64)\n-----END \(type)-----\n"
    }

    // MARK: - Keychain 持久化

    private static func readFromKeychain() -> MITMIdentity? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "npclab.mitm",
            kSecAttrAccount as String: caLabel,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        let parts = s.components(separatedBy: "\u{0000}") // certPEM \0 keyPEM
        guard parts.count == 2 else { return nil }
        return MITMIdentity(certPEM: parts[0], keyPEM: parts[1],
                            certDER: Data(base64Encoded: parts[0]
                                .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
                                .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
                                .replacingOccurrences(of: "\n", with: "")) ?? Data())
    }

    private static func saveToKeychain(_ id: MITMIdentity) {
        let s = id.certPEM + "\u{0000}" + id.keyPEM
        let data = Data(s.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "npclab.mitm",
            kSecAttrAccount as String: caLabel,
        ]
        var upd: [String: Any] = base
        upd[kSecValueData as String] = data
        let _ = SecItemDelete(base as CFDictionary)
        let _ = SecItemAdd(upd as CFDictionary, nil)
    }

    /// 导出根 CA 给用户装（设置页「导出 CA 证书」）
    static func exportCAPEM() -> String {
        loadOrCreateCA().certPEM
    }
}
