import SwiftUI
import PhotosUI

struct ChatView: View {
    @EnvironmentObject var st: AppSettings
    @EnvironmentObject var hub: NodeHub
    @EnvironmentObject var engine: ChatEngine
    @EnvironmentObject var agent: ToolAgent

    @State private var draft = ""
    @State private var sheet: ActiveSheet?
    @FocusState private var focused: Bool
    @State private var copiedId: UUID?

    // 附件
    @State private var pendingImages: [String] = []
    @State private var pickItems: [PhotosPickerItem] = []

    // 语音输入
    @StateObject private var voice = VoiceInput()

    /// 同一个 View 上挂多个 .sheet 只有最后一个生效，所以统一走一个枚举。
    enum ActiveSheet: Identifiable {
        case prompt
        case camera
        case image(String)

        var id: String {
            switch self {
            case .prompt: return "prompt"
            case .camera: return "camera"
            case .image(let n): return "img:" + n
            }
        }
    }

    /// 当前走哪条路：工具循环 or 纯流式
    private var useTools: Bool { st.toolLoop }
    private var busy: Bool { useTools ? agent.streaming : engine.streaming }

    private var injected: PromptBuilder.Parts {
        PromptBuilder.assemble(st, bridge: hub.state)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(T.line)
            transcript
            inputBar
        }
        .background(Backdrop())
        .navigationTitle("对话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    sheet = .prompt
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text(String(format: "%.1fk", Double(injected.bytes) / 1024))
                            .font(T.mono(11))
                    }
                    .font(.system(size: 12))
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        hub.refresh(st)
                    } label: { Label("探活节点", systemImage: "antenna.radiowaves.left.and.right") }
                    Button(role: .destructive) {
                        st.resetChat()
                    } label: { Label("清空会话", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .prompt:
                PromptPreview(parts: injected)
            case .camera:
                CameraPicker { img in
                    sheet = nil
                    guard let img = img, let name = Attachment.save(img) else { return }
                    if pendingImages.count < Attachment.maxPerMessage {
                        pendingImages.append(name)
                    } else {
                        Attachment.remove(name)      // 超配额就删掉，不然会一直堆在盘上
                    }
                }
                .ignoresSafeArea()
            case .image(let n):
                ImageViewer(name: n)
            }
        }
        .onChange(of: pickItems) { items in
            guard !items.isEmpty else { return }
            Task { await loadPicked(items) }
        }
    }

    // MARK: 附件

    private func loadPicked(_ items: [PhotosPickerItem]) async {
        var added: [String] = []
        for it in items {
            if pendingImages.count + added.count >= Attachment.maxPerMessage { break }
            guard let d = try? await it.loadTransferable(type: Data.self),
                  let img = UIImage(data: d),
                  let name = Attachment.save(img) else { continue }
            added.append(name)
        }
        await MainActor.run {
            pendingImages.append(contentsOf: added)
            pickItems = []                    // 清空，否则重复选同一张不触发 onChange
        }
    }

    private func dropImage(_ name: String) {
        pendingImages.removeAll { $0 == name }
        Attachment.remove(name)
    }

    private var attachButtons: some View {
        HStack(spacing: 2) {
            PhotosPicker(
                selection: $pickItems,
                maxSelectionCount: max(1, Attachment.maxPerMessage - pendingImages.count),
                matching: .images,
                photoLibrary: .shared()
            ) {
                Image(systemName: pendingImages.isEmpty ? "photo.on.rectangle" : "photo.badge.checkmark")
                    .font(.system(size: 15))
                    .foregroundColor(pendingImages.isEmpty ? T.txt2 : T.teal)
                    .frame(width: 30, height: 40)
            }

            Button {
                sheet = .camera
            } label: {
                Image(systemName: "camera")
                    .font(.system(size: 15))
                    .foregroundColor(T.txt2)
                    .frame(width: 30, height: 40)
            }
            .buttonStyle(.plain)

            VoiceButton(voice: voice) { text in
                // 识别结果接在已有草稿后面，别把用户打的字冲掉
                if draft.isEmpty {
                    draft = text
                } else {
                    draft += (draft.hasSuffix(" ") ? "" : " ") + text
                }
            }
        }
    }

    // MARK: 顶栏

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(hub.state.online ? T.green : T.txt3)
                .frame(width: 6, height: 6)
            Text(hub.state.online ? "节点 \(st.bridgeURL.replacingOccurrences(of: "http://", with: ""))"
                                  : (st.bridgeOn ? "节点离线" : "纯本地"))
                .font(T.mono(10.5)).foregroundColor(T.txt2)
            Spacer()
            Pill(text: st.model.isEmpty ? "未设模型" : st.model, color: T.accent)
            Pill(text: st.skillMode == "index" ? "技能 20" : (st.skillMode == "full" ? "技能全文" : "技能关"),
                 color: st.skillMode == "off" ? T.txt3 : T.purple)
            Pill(text: st.toolLoop ? "工具开" : "纯对话",
                 color: st.toolLoop ? T.teal : T.txt3)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(T.bg2.opacity(0.7))
    }

    // MARK: 消息

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if st.messages.isEmpty {
                        EmptyHint(icon: "bubble.left.and.bubble.right",
                                  title: "还没有对话",
                                  sub: "人设与技能已经装在设备里，接上模型就能开始")
                            .padding(.top, 40)
                    }
                    ForEach(st.messages) { m in
                        bubble(m).id(m.id)
                    }
                    if !engine.live.isEmpty && !useTools {
                        bubble(ChatMessage(role: "assistant", text: engine.live))
                            .id("live")
                    }
                    // 工具循环：非流式，所以只显示「在跑什么」
                    if useTools && agent.streaming {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text(agent.current.map { "调用 \($0)…" } ?? "思考中…")
                                .font(T.mono(11))
                                .foregroundColor(T.txt3)
                            if agent.round > 1 {
                                Text("第 \(agent.round) 轮")
                                    .font(T.mono(9))
                                    .foregroundColor(T.txt3.opacity(0.7))
                            }
                        }
                        .padding(.leading, 6)
                    }
                    if !useTools && engine.streaming && engine.live.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text("思考中…").font(.system(size: 12)).foregroundColor(T.txt3)
                        }
                        .padding(.leading, 6)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .onChange(of: st.messages.count) { _ in scroll(proxy) }
            .onChange(of: engine.live) { _ in scroll(proxy) }
            .onAppear { scroll(proxy, animated: false) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    @ViewBuilder
    private func bubble(_ m: ChatMessage) -> some View {
        let mine = m.role == "user"
        HStack(alignment: .top, spacing: 8) {
            if mine { Spacer(minLength: 40) }
            if !mine {
                ZStack {
                    Circle().fill(m.error ? T.red.opacity(0.2) : T.accent.opacity(0.16))
                    Text(m.error ? "!" : "N")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(m.error ? T.red : T.accent)
                }
                .frame(width: 24, height: 24)
                .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                if mine {
                    if !m.images.isEmpty {
                        // 多图横排，一次最多 4 张（Attachment.maxPerMessage）
                        HStack(spacing: 5) {
                            ForEach(m.images, id: \.self) { n in
                                Group {
                                    if let img = Attachment.image(n) {
                                        Image(uiImage: img).resizable().scaledToFill()
                                    } else {
                                        ZStack {
                                            T.card
                                            Image(systemName: "photo").foregroundColor(T.txt3)
                                        }
                                    }
                                }
                                .frame(width: 62, height: 62)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .onTapGesture { sheet = .image(n) }
                            }
                        }
                    }
                    if !m.text.isEmpty {
                        Text(m.text)
                            .font(.system(size: 14))
                            .foregroundColor(T.txt)
                            .textSelection(.enabled)
                    }
                } else {
                    MDText(raw: m.text)
                }
                Text(hhmmss(m.ts))
                    .font(T.mono(9)).foregroundColor(T.txt3)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(mine ? T.accent.opacity(0.20) : T.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(mine ? T.accent.opacity(0.28) : T.line, lineWidth: 1)
            )
            .contextMenu {
                Button {
                    UIPasteboard.general.string = m.text
                    copiedId = m.id
                } label: { Label("复制", systemImage: "doc.on.doc") }
            }

            if !mine { Spacer(minLength: 20) }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    // MARK: 输入

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(T.line)

            if !pendingImages.isEmpty {
                AttachmentStrip(names: pendingImages,
                                onRemove: { dropImage($0) },
                                onPreview: { sheet = .image($0) })
            }

            if voice.isListening {
                VoiceOverlay(voice: voice)
            }

            HStack(alignment: .bottom, spacing: 4) {
                attachButtons

                TextField("给 Npc 派活…", text: $draft, axis: .vertical)
                    .font(.system(size: 14))
                    .foregroundColor(T.txt)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .glass(12)

                Button {
                    if busy {
                        if useTools { agent.stop() } else { engine.stop() }
                    } else {
                        let t = draft
                        let imgs = pendingImages
                        // 没 Key 就别把图吃掉——发不出去还留在输入区
                        guard !st.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
                            engine.err = "还没填 API Key（设置 → 模型）"
                            return
                        }
                        draft = ""
                        pendingImages = []
                        // 按这句话重新挑 20 条技能，而不是用空 query 预拼的那份
                        let sys = PromptBuilder.assemble(st, bridge: hub.state, query: t).full
                        if useTools {
                            agent.send(st, system: sys, text: t,
                                       bridge: Bridge(st), hub: hub)
                        } else {
                            engine.send(st, system: sys, text: t, images: imgs)
                        }
                    }
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(busy ? T.red : (draft.isEmpty && pendingImages.isEmpty ? T.card : T.accent))
                        Image(systemName: busy ? "stop.fill" : "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(draft.isEmpty && pendingImages.isEmpty && !busy ? T.txt3 : .white)
                    }
                    .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .disabled(draft.isEmpty && pendingImages.isEmpty && !busy)
            }
            .padding(.horizontal, 8).padding(.vertical, 9)
            .background(T.bg2.opacity(0.85))
        }
    }
}

// MARK: - 注入预览

struct PromptPreview: View {
    var parts: PromptBuilder.Parts
    @Environment(\.dismiss) private var dismiss
    @State private var showFull = true

    private var layers: [(String, String)] {
        [("Layer 1 · 人设 SOUL.md", parts.soul),
         ("Layer 2 · 技能披露 available_skills", parts.skills),
         ("Layer 3 · 工具链 toolchain", parts.tools),
         ("Layer 4 · 运行时 runtime", parts.runtime),
         ("Layer 5 · 思维模板 ops-notes", parts.block),
         ("尾注", parts.tail)]
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Card {
                        HStack {
                            Text("SYSTEM 合计").font(.system(size: 12)).foregroundColor(T.txt2)
                            Spacer()
                            Text("\(humanBytes(parts.bytes)) · ≈\(parts.bytes / 1700)k token")
                                .font(T.mono(11.5)).foregroundColor(T.accent)
                        }
                        ForEach(layers.indices, id: \.self) { i in
                            if !layers[i].1.isEmpty {
                                HStack {
                                    Text(layers[i].0).font(.system(size: 11.5)).foregroundColor(T.txt2)
                                    Spacer()
                                    Text(humanBytes(layers[i].1.utf8.count))
                                        .font(T.mono(10.5)).foregroundColor(T.txt3)
                                }
                            }
                        }
                    }

                    Picker("", selection: $showFull) {
                        Text("拼好的全文").tag(true)
                        Text("按层拆开").tag(false)
                    }
                    .pickerStyle(.segmented)

                    if showFull {
                        Card {
                            Text(parts.full)
                                .font(T.mono(10.5))
                                .foregroundColor(T.txt2)
                                .textSelection(.enabled)
                        }
                    } else {
                        ForEach(layers.indices, id: \.self) { i in
                            if !layers[i].1.isEmpty {
                                Card {
                                    Text(layers[i].0).font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(T.accent)
                                    Text(layers[i].1).font(T.mono(10))
                                        .foregroundColor(T.txt2).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
            .background(Backdrop())
            .navigationTitle("注入预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
