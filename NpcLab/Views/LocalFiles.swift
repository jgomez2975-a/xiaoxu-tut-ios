//
//  LocalFiles.swift
//  NpcLab
//
//  本机读写：浏览 App 自己的工作区，改文本、建目录、导入、删除。
//  不需要节点，也不受 App Group 限制（没 App Group 时落在 Documents，
//  配合 UIFileSharingEnabled，「文件」App 里同样看得到）。
//

import SwiftUI
import UniformTypeIdentifiers

struct LocalFilesView: View {

    @EnvironmentObject var st: AppSettings

    @State private var dir: URL = Workspace.container
    @State private var items: [Entry] = []
    @State private var editing: Entry?
    @State private var info: Entry?
    @State private var showImporter = false
    @State private var showNewFolder = false
    @State private var newName = ""
    @State private var msg = ""

    struct Entry: Identifiable, Hashable {
        var url: URL
        var isDir: Bool
        var size: Int64
        var mtime: Date?
        var id: String { url.path }
        var name: String { url.lastPathComponent }
    }

    var body: some View {
        PanelShell(title: "本机文件", sub: "App 沙盒里的读写；「文件」App 里也能看到同一个目录") {

            Card {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill").foregroundColor(T.orange)
                    Text(friendly(dir.path))
                        .font(T.mono(10.5)).foregroundColor(T.txt2)
                        .lineLimit(2).truncationMode(.middle)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button {
                        if dir.path != Workspace.container.path {
                            dir = dir.deletingLastPathComponent()
                            reload()
                        }
                    } label: {
                        Label("上级", systemImage: "arrow.up")
                            .font(.system(size: 12))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(T.card).foregroundColor(T.txt2)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        newName = ""
                        showNewFolder = true
                    } label: {
                        Label("新建", systemImage: "folder.badge.plus")
                            .font(.system(size: 12))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(T.card).foregroundColor(T.txt2)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        showImporter = true
                    } label: {
                        Label("导入", systemImage: "square.and.arrow.down")
                            .font(.system(size: 12))
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(T.card).foregroundColor(T.txt2)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Spacer()
                    Text("\(items.count) 项").font(T.mono(10)).foregroundColor(T.txt3)
                }
                if !msg.isEmpty {
                    Text(msg).font(T.mono(10)).foregroundColor(T.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                if items.isEmpty {
                    Text(dir.path.hasSuffix("/Workspace")
                         ? "工作区是空的。点「导入」从文件 App 拿一个进来，或者先在终端里写点东西。"
                         : "这个目录是空的。")
                        .font(.system(size: 11.5)).foregroundColor(T.txt3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(items) { e in
                    Button {
                        if e.isDir {
                            dir = e.url
                            reload()
                        } else {
                            info = e
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: e.isDir ? "folder" : icon(e))
                                .font(.system(size: 13))
                                .foregroundColor(e.isDir ? T.orange : T.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.name)
                                    .font(.system(size: 12.5)).foregroundColor(T.txt)
                                    .lineLimit(1).truncationMode(.middle)
                                HStack(spacing: 6) {
                                    if !e.isDir {
                                        Text(ByteCountFormatter.string(fromByteCount: e.size,
                                                                       countStyle: .file))
                                            .font(T.mono(9)).foregroundColor(T.txt3)
                                    }
                                    if let d = e.mtime {
                                        Text(shortDate(d)).font(T.mono(9)).foregroundColor(T.txt3)
                                    }
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10)).foregroundColor(T.txt3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("这些文件在「文件」App → 小徐TuT 里也能直接改。终端里对应的路径是 /root（Linux 自己的文件系统），两套是分开的。")
                .font(.system(size: 10.5)).foregroundColor(T.txt3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                var n = 0
                for u in urls {
                    let scoped = u.startAccessingSecurityScopedResource()
                    defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                    let dst = uniqueURL(dir.appendingPathComponent(u.lastPathComponent))
                    if (try? FileManager.default.copyItem(at: u, to: dst)) != nil { n += 1 }
                }
                msg = n > 0 ? "导入 \(n) 个文件" : "导入失败"
                reload()
            case .failure(let e):
                msg = e.localizedDescription
            }
        }
        .sheet(item: $editing) { e in
            FileEditor(url: e.url) { reload() }
        }
        .sheet(item: $info) { e in
            FileInfoSheet(entry: e) {
                info = nil
                editing = e
            } onDelete: {
                info = nil
                delete(e)
            }
        }
        .sheet(isPresented: $showNewFolder) {
            PromptSheet(title: "新建文件夹", hint: "建在当前目录下",
                        placeholder: "名字", initial: "") { name in
                let t = name.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { return }
                let u = dir.appendingPathComponent(t, isDirectory: true)
                try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
                reload()
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        var out: [Entry] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        if let list = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) {
            for u in list {
                let v = try? u.resourceValues(forKeys: Set(keys))
                out.append(Entry(url: u,
                                 isDir: v?.isDirectory ?? false,
                                 size: Int64(v?.fileSize ?? 0),
                                 mtime: v?.contentModificationDate))
            }
        }
        out.sort {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        items = out
    }

    private func delete(_ e: Entry) {
        do {
            try FileManager.default.removeItem(at: e.url)
            msg = "已删除 \(e.name)"
        } catch {
            msg = "删除失败：\(error.localizedDescription)"
        }
        reload()
    }

    private func uniqueURL(_ u: URL) -> URL {
        var dst = u
        var i = 2
        let base = (u.lastPathComponent as NSString).deletingPathExtension
        let ext = (u.lastPathComponent as NSString).pathExtension
        while FileManager.default.fileExists(atPath: dst.path) {
            let n = ext.isEmpty ? "\(base)-\(i)" : "\(base)-\(i).\(ext)"
            dst = u.deletingLastPathComponent().appendingPathComponent(n)
            i += 1
        }
        return dst
    }

    private func icon(_ e: Entry) -> String {
        let x = e.name.lowercased()
        if x.hasSuffix(".sh") || x.hasSuffix(".py") || x.hasSuffix(".js") { return "curlybraces" }
        if x.hasSuffix(".json") || x.hasSuffix(".plist") { return "doc.text" }
        if x.hasSuffix(".png") || x.hasSuffix(".jpg") || x.hasSuffix(".jpeg") || x.hasSuffix(".webp") {
            return "photo"
        }
        if x.hasSuffix(".zip") || x.hasSuffix(".tar") || x.hasSuffix(".gz") { return "archivebox" }
        if x.hasSuffix(".ipa") || x.hasSuffix(".dylib") || x.hasSuffix(".so") { return "shippingbox" }
        return "doc"
    }

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }

    /// 把沙盒的绝对路径压成好读的形式
    private func friendly(_ p: String) -> String {
        let root = Workspace.container.path
        if p == root { return "/ (小徐TuT)" }
        if p.hasPrefix(root) {
            return "小徐TuT" + p.dropFirst(root.count)
        }
        return p
    }
}

// MARK: - 文本编辑

struct FileEditor: View {
    let url: URL
    var onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var original = ""
    @State private var tooBig = false
    @State private var msg = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if tooBig {
                    Text("文件太大（>2MB），这里不做编辑。用终端里的 less/sed 处理。")
                        .font(.system(size: 12)).foregroundColor(T.orange)
                        .padding(16)
                } else {
                    TextEditor(text: $text)
                        .font(T.mono(11.5))
                        .scrollContentBackground(.hidden)
                        .background(Color.black.opacity(0.25))
                        .padding(8)
                }
                if !msg.isEmpty {
                    Text(msg).font(T.mono(10)).foregroundColor(T.orange).padding(8)
                }
            }
            .background(Backdrop())
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(tooBig || text == original)
                        .fontWeight(.semibold)
                }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 2 * 1024 * 1024 else {
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                text = s
                original = s
            } else {
                tooBig = true
            }
            return
        }
        tooBig = true
    }

    private func save() {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            original = text
            NpcLog.write("[file] 保存 \(url.lastPathComponent) \(text.count)字")
            onSave()
            dismiss()
        } catch {
            msg = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 文件信息

struct FileInfoSheet: View {
    let entry: LocalFilesView.Entry
    var onEdit: () -> Void
    var onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var sendMsg = ""
    @ObservedObject private var rev = RevLocal.shared

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card {
                        Text(entry.name).font(.system(size: 15, weight: .semibold))
                            .foregroundColor(T.txt)
                        Text(entry.url.path).font(T.mono(10)).foregroundColor(T.txt3)
                            .textSelection(.enabled)
                        HStack(spacing: 10) {
                            Pill(text: ByteCountFormatter.string(fromByteCount: entry.size,
                                                                 countStyle: .file),
                                 color: T.accent)
                            if let d = entry.mtime {
                                Text(d.formatted(date: .abbreviated, time: .shortened))
                                    .font(T.mono(10)).foregroundColor(T.txt3)
                            }
                        }
                    }

                    Card {
                        Button {
                            onEdit()
                            dismiss()
                        } label: {
                            Label("用文本编辑器打开", systemImage: "square.and.pencil")
                                .font(.system(size: 13)).foregroundColor(T.accent)
                        }
                        .buttonStyle(.plain)

                        Button {
                            sendMsg = "正在送入 Linux…"
                            rev.importFile(entry.url)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                sendMsg = "已交给逆向分析：去「设置 → 逆向分析 → 本机」看结果"
                            }
                        } label: {
                            Label("送去逆向分析（radare2）", systemImage: "binoculars")
                                .font(.system(size: 13)).foregroundColor(T.purple)
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            onDelete()
                            dismiss()
                        } label: {
                            Label("删除", systemImage: "trash")
                                .font(.system(size: 13)).foregroundColor(T.red)
                        }
                        .buttonStyle(.plain)

                        if !sendMsg.isEmpty {
                            Text(sendMsg).font(T.mono(10)).foregroundColor(T.txt3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(14)
            }
            .background(Backdrop())
            .navigationTitle("文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
