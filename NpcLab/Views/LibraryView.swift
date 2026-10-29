import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var st: AppSettings

    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("技能 \(PackData.shared.skills.count)").tag(0)
                Text("工具 \(PackData.shared.tools.count)").tag(1)
                Text("文档").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14).padding(.vertical, 8)

            Divider().overlay(T.line)

            switch tab {
            case 0: SkillsPane()
            case 1: ToolsPane()
            default: DocsPane()
            }
        }
        .background(Backdrop())
        .navigationTitle("技能库 / 工具链")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 技能

struct SkillsPane: View {
    @EnvironmentObject var st: AppSettings
    @State private var q = ""
    @State private var code = ""
    @State private var detail: Skill?

    private var list: [Skill] {
        var arr = PackData.shared.search(q)
        if !code.isEmpty { arr = arr.filter { $0.code == code } }
        return arr
    }

    var body: some View {
        VStack(spacing: 8) {
            SearchBar(text: $q, placeholder: "id / 描述 / 触发词")
                .padding(.horizontal, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("全部", "")
                    ForEach(PackData.shared.domains) { d in
                        chip("\(d.name) \(d.count)", d.code)
                    }
                }
                .padding(.horizontal, 12)
            }

            HStack {
                Text("\(list.count) 条").font(T.mono(10.5)).foregroundColor(T.txt3)
                if !st.pinned.isEmpty {
                    Text("· 置顶 \(st.pinned.count)").font(T.mono(10.5)).foregroundColor(T.accent)
                }
                Spacer()
                Text("长按置顶 / 取消").font(.system(size: 10)).foregroundColor(T.txt3)
            }
            .padding(.horizontal, 14)

            List {
                ForEach(list) { s in
                    Button {
                        detail = s
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            VStack(spacing: 3) {
                                Text(s.code)
                                    .font(T.mono(9, .bold))
                                    .foregroundColor(T.accent)
                                if st.pinned.contains(s.id) {
                                    Image(systemName: "pin.fill")
                                        .font(.system(size: 8)).foregroundColor(T.orange)
                                }
                            }
                            .frame(width: 34)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.name).font(T.mono(11.5))
                                    .foregroundColor(T.txt).lineLimit(1)
                                Text(s.desc).font(.system(size: 11.5))
                                    .foregroundColor(T.txt3)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 4)
                            Text(humanBytes(s.bytes)).font(T.mono(9)).foregroundColor(T.txt3)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        Button {
                            togglePin(s.id)
                        } label: {
                            Label(st.pinned.contains(s.id) ? "取消置顶" : "置顶",
                                  systemImage: st.pinned.contains(s.id) ? "pin.slash" : "pin")
                        }
                        Button {
                            UIPasteboard.general.string = s.id
                        } label: { Label("复制 ID", systemImage: "doc.on.doc") }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .sheet(item: $detail) { s in
            SkillDetail(skill: s, pinned: st.pinned.contains(s.id)) {
                togglePin(s.id)
            }
        }
    }

    private func togglePin(_ id: String) {
        if let i = st.pinned.firstIndex(of: id) {
            st.pinned.remove(at: i)
        } else {
            st.pinned.append(id)
        }
    }

    private func chip(_ title: String, _ c: String) -> some View {
        Button {
            code = c
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: code == c ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(code == c ? T.accent.opacity(0.22) : T.card)
                .foregroundColor(code == c ? T.accent : T.txt2)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SkillDetail: View {
    var skill: Skill
    var pinned: Bool
    var onPin: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var body_: String {
        PackData.shared.body(for: skill.id) ?? "（本包内没有这篇 SKILL.md 的正文）"
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Card {
                        Text(skill.name).font(T.mono(13, .semibold)).foregroundColor(T.txt)
                        HStack(spacing: 6) {
                            Pill(text: skill.code)
                            Pill(text: skill.domain, color: T.purple)
                            Pill(text: humanBytes(skill.bytes), color: T.txt3)
                            if skill.lines > 0 {
                                Pill(text: "\(skill.lines) 行", color: T.txt3)
                            }
                        }
                        Text(skill.desc).font(.system(size: 12)).foregroundColor(T.txt2)
                        if !skill.triggers.isEmpty {
                            Text("触发词：" + skill.triggers.prefix(12).joined(separator: " / "))
                                .font(.system(size: 10.5)).foregroundColor(T.txt3)
                        }
                    }
                    Card {
                        HStack {
                            Text("SKILL.md").font(T.mono(11)).foregroundColor(T.txt3)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = body_
                            } label: {
                                Label("复制全文", systemImage: "doc.on.doc")
                                    .font(.system(size: 11)).foregroundColor(T.accent)
                            }
                            .buttonStyle(.plain)
                        }
                        Text(body_)
                            .font(T.mono(10.5))
                            .foregroundColor(T.txt2)
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
            }
            .background(Backdrop())
            .navigationTitle("技能")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(pinned ? "取消置顶" : "置顶") {
                        onPin()
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 工具

struct ToolsPane: View {
    @State private var q = ""
    @State private var group = ""
    @State private var detail: Tool?

    private var list: [Tool] {
        var arr = PackData.shared.tools
        if !group.isEmpty { arr = arr.filter { $0.group == group } }
        let k = q.trimmingCharacters(in: .whitespaces).lowercased()
        if !k.isEmpty {
            arr = arr.filter {
                $0.id.lowercased().contains(k) || $0.purpose.lowercased().contains(k)
            }
        }
        return arr
    }

    private var groupName: [String: String] {
        var m: [String: String] = [:]
        for g in PackData.shared.toolGroups { m[g.id] = g.name }
        return m
    }

    var body: some View {
        VStack(spacing: 8) {
            SearchBar(text: $q, placeholder: "工具名 / 用途")
                .padding(.horizontal, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("全部", "")
                    ForEach(PackData.shared.toolGroups) { g in
                        chip("\(g.name) \(g.count)", g.id)
                    }
                }
                .padding(.horizontal, 12)
            }

            List {
                ForEach(list) { t in
                    Button {
                        detail = t
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Text(t.id)
                                .font(T.mono(11.5, .medium))
                                .foregroundColor(T.txt)
                                .frame(width: 96, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t.purpose).font(.system(size: 11.5))
                                    .foregroundColor(T.txt3).lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                HStack(spacing: 5) {
                                    Pill(text: t.kindLabel,
                                         color: t.kind == "bundled" ? T.green
                                            : (t.kind == "fetchable" ? T.orange : T.txt3))
                                    if !t.version.isEmpty {
                                        Text(t.version).font(T.mono(9)).foregroundColor(T.txt3)
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .sheet(item: $detail) { t in
            ToolDetail(tool: t, group: groupName[t.group] ?? t.group)
        }
    }

    private func chip(_ title: String, _ id: String) -> some View {
        Button { group = id } label: {
            Text(title)
                .font(.system(size: 11.5, weight: group == id ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(group == id ? T.accent.opacity(0.22) : T.card)
                .foregroundColor(group == id ? T.accent : T.txt2)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ToolDetail: View {
    var tool: Tool
    var group: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Card {
                        Text(tool.id).font(T.mono(15, .semibold)).foregroundColor(T.txt)
                        HStack(spacing: 6) {
                            Pill(text: tool.kindLabel,
                                 color: tool.kind == "bundled" ? T.green : T.orange)
                            if !tool.version.isEmpty { Pill(text: tool.version, color: T.teal) }
                            if !tool.size.isEmpty { Pill(text: tool.size, color: T.txt3) }
                        }
                        Text(tool.purpose).font(.system(size: 12)).foregroundColor(T.txt2)
                    }
                    kv("分组", group)
                    if !tool.platform.isEmpty {
                        kv("平台", tool.platform.joined(separator: " / "))
                    }
                    if !tool.path.isEmpty { kv("路径", tool.path) }
                    if !tool.upstream.isEmpty { kv("上游", tool.upstream) }
                    if !tool.note.isEmpty { kv("备注", tool.note) }
                    if !tool.install.isEmpty {
                        Card {
                            Text("安装 / 取回").font(.system(size: 12, weight: .semibold))
                                .foregroundColor(T.accent)
                            CodeBox(code: tool.install, lang: "shell")
                        }
                    }
                    if !tool.verify.isEmpty {
                        Card {
                            Text("探活").font(.system(size: 12, weight: .semibold))
                                .foregroundColor(T.green)
                            CodeBox(code: tool.verify, lang: "shell")
                        }
                    }
                }
                .padding(14)
            }
            .background(Backdrop())
            .navigationTitle("工具")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        Card(padding: 12) {
            Text(k).font(.system(size: 10.5)).foregroundColor(T.txt3)
            Text(v).font(T.mono(11)).foregroundColor(T.txt2).textSelection(.enabled)
        }
    }
}

// MARK: - 文档

struct DocsPane: View {
    @State private var q = ""
    @State private var detail: PackDoc?
    @State private var tick = 0

    private var groups: [(String, String)] {
        [("docs", "总入口"), ("templates", "模板"), ("toolkits", "工具包"),
         ("refs", "参考"), ("scripts", "脚本"), ("boot", "引导")]
    }

    private var list: [PackDoc] {
        PackData.shared.loadDocsIfNeeded()
        var arr = PackData.shared.docs
        let k = q.trimmingCharacters(in: .whitespaces).lowercased()
        if !k.isEmpty {
            arr = arr.filter {
                $0.title.lowercased().contains(k) || $0.path.lowercased().contains(k)
                    || $0.desc.lowercased().contains(k)
            }
        }
        return arr
    }

    var body: some View {
        VStack(spacing: 8) {
            SearchBar(text: $q, placeholder: "文档名 / 路径")
                .padding(.horizontal, 12)
            let _ = tick

            List {
                ForEach(groups.indices, id: \.self) { gi in
                    let g = groups[gi]
                    let items = list.filter { $0.group == g.0 }
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { d in
                                Button { detail = d } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: d.body.isEmpty ? "doc" : "doc.text.fill")
                                            .font(.system(size: 12))
                                            .foregroundColor(d.body.isEmpty ? T.txt3 : T.accent)
                                            .padding(.top, 2)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(d.title).font(.system(size: 13))
                                                .foregroundColor(T.txt).lineLimit(1)
                                            Text(d.path).font(T.mono(9.5))
                                                .foregroundColor(T.txt3).lineLimit(1)
                                            if !d.desc.isEmpty {
                                                Text(d.desc).font(.system(size: 10.5))
                                                    .foregroundColor(T.txt3).lineLimit(2)
                                                    .multilineTextAlignment(.leading)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                        Text(d.size).font(T.mono(9)).foregroundColor(T.txt3)
                                    }
                                    .padding(.vertical, 3)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(Color.clear)
                            }
                        } header: {
                            Text(g.1).font(.system(size: 11, weight: .semibold))
                                .foregroundColor(T.txt3)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .onAppear {
            PackData.shared.loadDocsIfNeeded()
            tick += 1
        }
        .sheet(item: $detail) { d in
            DocDetail(doc: d)
        }
    }
}

struct DocDetail: View {
    var doc: PackDoc
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Card {
                        Text(doc.title).font(.system(size: 15, weight: .semibold))
                            .foregroundColor(T.txt)
                        Text(doc.path).font(T.mono(10)).foregroundColor(T.txt3)
                        if !doc.desc.isEmpty {
                            Text(doc.desc).font(.system(size: 11.5)).foregroundColor(T.txt2)
                        }
                    }
                    if doc.body.isEmpty {
                        EmptyHint(icon: "doc", title: "正文未随包",
                                  sub: "这篇在 \(doc.path)，App 内只有索引")
                    } else {
                        Card {
                            MDText(raw: doc.body, size: 12.5)
                        }
                    }
                }
                .padding(14)
            }
            .background(Backdrop())
            .navigationTitle("文档")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
