//
//  ShareViewController.swift
//  NpcLabShare
//
//  从别的 App 分享文件 / 图片 / 链接进来。
//  收下的东西落到共享容器的 Inbox/，主 App 下次进前台会扫这个目录。
//
//  为什么不在扩展里直接跳主 App：iOS 不允许扩展随便 openURL。
//  走 responder chain 的私有路子（UIApplication.shared.open 在扩展里拿不到）
//  在部分系统版本上会被拒，稳的做法是只落地、不跳转。
//

import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.043, green: 0.047, blue: 0.063, alpha: 1)

        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.text = "正在接收…"

        spinner.color = .white
        spinner.startAnimating()

        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await collect() }
    }

    // MARK: 收

    private func collect() async {
        guard let ctx = extensionContext,
              let items = ctx.inputItems as? [NSExtensionItem] else {
            finish("没有可接收的内容", ok: false)
            return
        }

        let inbox = ShareInbox.directory
        do {
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        } catch {
            finish("建目录失败：\(error.localizedDescription)", ok: false)
            return
        }

        var saved: [String] = []

        for item in items {
            // 纯文本 / URL 走这一支
            if let s = item.attributedContentText?.string, !s.isEmpty {
                let name = "text-\(stamp()).txt"
                let url = inbox.appendingPathComponent(name)
                if (try? s.write(to: url, atomically: true, encoding: .utf8)) != nil {
                    saved.append(name)
                }
            }

            for provider in item.attachments ?? [] {
                if let name = await save(provider, into: inbox) {
                    saved.append(name)
                }
            }
        }

        if saved.isEmpty {
            finish("没有可保存的内容", ok: false)
        } else {
            finish("已收入 Inbox（\(saved.count) 项）", ok: true)
        }
    }

    /// 从一个 NSItemProvider 里把东西存下来，返回落地的文件名
    private func save(_ provider: NSItemProvider, into dir: URL) async -> String? {
        // 1. 文件（最通用，二进制、ipa、图片都走它）
        if provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) {
            let name = provider.suggestedName ?? "item-\(stamp())"
            let ext = Self.ext(for: provider)
            let filename = ext.isEmpty ? name : name + "." + ext
            let dst = unique(in: dir, name: filename)

            if let src = await loadFile(provider) {
                // 沙箱外的 URL 要先拿安全作用域
                let scoped = src.startAccessingSecurityScopedResource()
                defer { if scoped { src.stopAccessingSecurityScopedResource() } }
                if (try? FileManager.default.copyItem(at: src, to: dst)) != nil {
                    return dst.lastPathComponent
                }
                if let data = try? Data(contentsOf: src),
                   (try? data.write(to: dst)) != nil {
                    return dst.lastPathComponent
                }
            }
            if let data = await loadData(provider) {
                if (try? data.write(to: dst)) != nil {
                    return dst.lastPathComponent
                }
            }
        }

        // 2. 纯 URL（链接分享）
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let u = await loadURL(provider) {
                let name = "url-\(stamp()).txt"
                let dst = dir.appendingPathComponent(name)
                if (try? u.absoluteString.write(to: dst, atomically: true, encoding: .utf8)) != nil {
                    return name
                }
            }
        }

        return nil
    }

    private func loadFile(_ p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            p.loadItem(forTypeIdentifier: UTType.item.identifier, options: nil) { item, _ in
                cont.resume(returning: item as? URL)
            }
        }
    }

    private func loadData(_ p: NSItemProvider) async -> Data? {
        await withCheckedContinuation { cont in
            p.loadDataRepresentation(forTypeIdentifier: UTType.item.identifier) { d, _ in
                cont.resume(returning: d)
            }
        }
    }

    private func loadURL(_ p: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = p.loadObject(ofClass: NSURL.self) { obj, _ in
                cont.resume(returning: obj as? URL)
            }
        }
    }

    // MARK: 小工具

    private static func ext(for p: NSItemProvider) -> String {
        for t in p.registeredTypeIdentifiers {
            if let ut = UTType(t), let e = ut.preferredFilenameExtension {
                return e
            }
        }
        return ""
    }

    private func unique(in dir: URL, name: String) -> URL {
        var dst = dir.appendingPathComponent(name)
        var i = 2
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        while FileManager.default.fileExists(atPath: dst.path) {
            let n = ext.isEmpty ? "\(base)-\(i)" : "\(base)-\(i).\(ext)"
            dst = dir.appendingPathComponent(n)
            i += 1
        }
        return dst
    }

    private func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private func finish(_ msg: String, ok: Bool) {
        DispatchQueue.main.async {
            self.spinner.stopAnimating()
            self.statusLabel.text = msg
            self.statusLabel.textColor = ok
                ? UIColor(red: 0.19, green: 0.82, blue: 0.45, alpha: 1)
                : UIColor(red: 1, green: 0.32, blue: 0.28, alpha: 1)
        }
        // 给用户看一眼再收掉
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            self.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

// MARK: - 共享目录

enum ShareInbox {
    /// App Group 通了就用它，没通就退回扩展自己的临时目录
    /// （临时目录主 App 读不到，但至少扩展不会崩）
    static var directory: URL {
        if let g = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.npclab.client") {
            return g.appendingPathComponent("Inbox", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("NpcLabInbox", isDirectory: true)
    }
}
