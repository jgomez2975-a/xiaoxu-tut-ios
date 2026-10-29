//
//  OpenSheet.swift
//  NpcLab
//
//  终端里 npclab-open 发上来的 OSC 1337 请求，最终在这里落地。
//  按 OpenRequest.kind 分流：网页走 WKWebView，PDF/Office 走 QuickLook，
//  图片走自己的缩放视图，纯文本读出来渲染，其余退回系统分享面板。
//

import SwiftUI
import WebKit
import QuickLook
import UIKit

// MARK: - 主入口

struct OpenSheet: View {
    let req: OpenRequest
    @Environment(\.dismiss) private var dismiss
    @State private var shareItem: SharePayload?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(req.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("关闭") { dismiss() }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            if let f = req.fileURL {
                                shareItem = SharePayload(url: f)
                            } else if let u = URL(string: req.url) {
                                shareItem = SharePayload(url: u)
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                .sheet(item: $shareItem) { s in
                    ShareSheet(items: [s.url])
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch req.kind {
        case .web:
            if let u = URL(string: req.url) {
                WebPane(url: u)
            } else {
                Unavailable(text: "URL 解析失败：\(req.url)")
            }

        case .image:
            if let f = req.fileURL {
                ImagePane(url: f)
            } else {
                Unavailable(text: "找不到文件")
            }

        case .markdown, .text:
            if let f = req.fileURL {
                TextPane(url: f, isMarkdown: req.kind == .markdown)
            } else {
                Unavailable(text: "找不到文件")
            }

        default:
            if let f = req.fileURL {
                QuickLookPane(url: f)
            } else {
                Unavailable(text: "找不到文件")
            }
        }
    }
}

// MARK: - 兜底

struct Unavailable: View {
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30)).foregroundColor(T.orange)
            Text(text).font(.system(size: 13)).foregroundColor(T.txt2)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(T.bg)
    }
}

// MARK: - 网页

struct WebPane: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        /// target="_blank" 的链接不会自己跳，得接住
        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let u = action.request.url else {
                decisionHandler(.allow); return
            }
            if action.targetFrame == nil {
                webView.load(URLRequest(url: u))
                decisionHandler(.cancel)
                return
            }
            // 非 http(s) 的（tel: mailto: itms-services:）交给系统
            if let s = u.scheme?.lowercased(),
               !["http", "https", "about", "data", "file"].contains(s) {
                UIApplication.shared.open(u)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

// MARK: - 图片

struct ImagePane: View {
    let url: URL
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    private var image: UIImage? {
        UIImage(contentsOfFile: url.path)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                T.bg
                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { v in scale = min(max(lastScale * v, 0.5), 8) }
                                .onEnded { _ in lastScale = scale }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                scale = scale > 1.5 ? 1 : 2.5
                                lastScale = scale
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    Unavailable(text: "无法解码图片")
                }
            }
        }
        .background(T.bg)
    }
}

// MARK: - 文本

struct TextPane: View {
    let url: URL
    let isMarkdown: Bool

    private var text: String {
        // 只读前 512KB，日志文件可能很大
        guard let h = try? FileHandle(forReadingFrom: url) else { return "无法打开文件" }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 512 * 1024)) ?? Data()
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? "（二进制内容，不是文本）"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if isMarkdown {
                    MDText(raw: text.isEmpty ? "（空文件）" : text, size: 13)
                        .padding(14)
                } else {
                    Text(text.isEmpty ? "（空文件）" : text)
                        .font(T.mono(11.5))
                        .foregroundColor(T.txt)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
        }
        .background(T.bg)
    }
}

// MARK: - QuickLook

struct QuickLookPane: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }

    func updateUIViewController(_ c: QLPreviewController, context: Context) {
        c.reloadData()
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

// MARK: - 分享

struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}
