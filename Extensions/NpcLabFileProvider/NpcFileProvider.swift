//
//  NpcFileProvider.swift
//  NpcLabFileProvider
//
//  在系统「文件」App 里挂一个 小徐TuT 位置，浏览 App Group 里的两样东西：
//    · Inbox/      别的 App 分享进来的文件
//    · Workspace/  用户自己的工作区
//
//  看不到 rootfs：那玩意在主 App 沙箱的 Application Support 里，
//  扩展没有跨容器读权限，这是 iOS 的硬限制，不是没做。
//
//  只读实现：create / modify / delete 一律返回"不支持"。
//  真要写，得把 Linux 内核起在这个扩展里，那不现实（扩展内存上限约 24MB）。
//  要从终端往工作区写，走 App 内的通道，不走这里。
//

import FileProvider
import UniformTypeIdentifiers

// MARK: - 条目

// NSFileProviderItem 继承 NSObjectProtocol（class-only），所以这里必须是
// class 不能是 struct，否则报 "non-class type cannot conform to class protocol"。
final class NpcItem: NSObject, NSFileProviderItem {

    var itemIdentifier: NSFileProviderItemIdentifier
    var parentItemIdentifier: NSFileProviderItemIdentifier
    var filename: String
    var contentType: UTType
    var capabilities: NSFileProviderItemCapabilities
    var documentSize: NSNumber?
    var creationDate: Date?
    var contentModificationDate: Date?

    /// 相对共享容器的路径，空字符串代表根
    var relPath: String

    init(identifier: NSFileProviderItemIdentifier,
         parent: NSFileProviderItemIdentifier,
         name: String,
         type: UTType,
         caps: NSFileProviderItemCapabilities,
         size: Int? = nil,
         created: Date? = nil,
         modified: Date? = nil,
         rel: String) {
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parent
        self.filename = name
        self.contentType = type
        self.capabilities = caps
        self.documentSize = size.map { NSNumber(value: $0) }
        self.creationDate = created
        self.contentModificationDate = modified
        self.relPath = rel
        super.init()
    }
}

// MARK: - 扩展

final class NpcFileProvider: NSObject, NSFileProviderReplicatedExtension {

    static let group = "group.com.npclab.client"

    let domain: NSFileProviderDomain

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {}

    // MARK: 路径

    /// 共享容器根。App Group 没配通就退回扩展自己的 Documents（会空，但不崩）
    private var rootURL: URL {
        if let g = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.group) {
            return g
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 把 identifier 还原成磁盘路径
    private func url(for id: NSFileProviderItemIdentifier) -> URL? {
        if id == .rootContainer { return rootURL }
        // 自己的 identifier 就是相对路径，用 / 连接
        let rel = id.rawValue
        guard !rel.contains("..") else { return nil }
        return rootURL.appendingPathComponent(rel)
    }

    /// 磁盘路径反推 identifier
    /// 名字不能叫 identifier(for:)：item(for identifier:) 的形参就叫 identifier，
    /// 会把方法名遮住，调用时变成 "cannot call value of non-function type"。
    /// 访问级别要 fileprivate：NpcEnumerator 也要用。
    fileprivate func itemIdentifier(for url: URL) -> NSFileProviderItemIdentifier {
        let root = rootURL.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        guard p.hasPrefix(root) else { return .rootContainer }
        var rel = String(p.dropFirst(root.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel.isEmpty ? .rootContainer : NSFileProviderItemIdentifier(rel)
    }

    // MARK: item

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {

        guard let u = url(for: identifier) else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }

        if identifier == .rootContainer {
            completionHandler(NpcItem(identifier: .rootContainer,
                                      parent: .rootContainer,
                                      name: "小徐TuT",
                                      type: .folder,
                                      caps: [.allowsReading, .allowsContentEnumerating],
                                      rel: ""), nil)
            return Progress()
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }

        let attrs = (try? FileManager.default.attributesOfItem(atPath: u.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue
        let mtime = attrs[.modificationDate] as? Date
        let btime = attrs[.creationDate] as? Date
        let type = isDir.boolValue ? UTType.folder : (UTType(filenameExtension: u.pathExtension) ?? .data)

        let parentURL = u.deletingLastPathComponent()
        let item = NpcItem(identifier: identifier,
                           parent: parentURL.standardizedFileURL.path == rootURL.standardizedFileURL.path
                               ? .rootContainer
                               : itemIdentifier(for: parentURL),
                           name: u.lastPathComponent,
                           type: type,
                           caps: isDir.boolValue
                               ? [.allowsReading, .allowsContentEnumerating]
                               : [.allowsReading],
                           size: size,
                           created: btime,
                           modified: mtime,
                           rel: identifier.rawValue)
        completionHandler(item, nil)
        return Progress()
    }

    // MARK: 读内容

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {

        guard let src = url(for: itemIdentifier) else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }

        // 系统要的是"给我一个临时 URL"，所以拷一份出去
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fp-\(UUID().uuidString)-\(src.lastPathComponent)")

        do {
            try FileManager.default.copyItem(at: src, to: tmp)
        } catch {
            completionHandler(nil, nil, error)
            return Progress()
        }

        let attrs = (try? FileManager.default.attributesOfItem(atPath: src.path)) ?? [:]
        let item = NpcItem(identifier: itemIdentifier,
                           parent: .rootContainer,
                           name: src.lastPathComponent,
                           type: UTType(filenameExtension: src.pathExtension) ?? .data,
                           caps: [.allowsReading],
                           size: (attrs[.size] as? NSNumber)?.intValue,
                           created: attrs[.creationDate] as? Date,
                           modified: attrs[.modificationDate] as? Date,
                           rel: itemIdentifier.rawValue)
        completionHandler(tmp, item, nil)
        return Progress()
    }

    // MARK: 写操作一律拒绝

    private func readOnly() -> Error {
        NSError(domain: NSFileProviderErrorDomain,
                code: NSFileProviderError.notAuthenticated.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "小徐TuT 工作区是只读的"])
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, readOnly())
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false, readOnly())
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(readOnly())
        return Progress()
    }

    // MARK: 枚举

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        guard let u = url(for: containerItemIdentifier) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return NpcEnumerator(container: containerItemIdentifier, dir: u, provider: self)
    }
}

// MARK: - 枚举器

final class NpcEnumerator: NSObject, NSFileProviderEnumerator {

    private let container: NSFileProviderItemIdentifier
    private let dir: URL
    private unowned let provider: NpcFileProvider
    private var didEnumerate = false

    init(container: NSFileProviderItemIdentifier, dir: URL, provider: NpcFileProvider) {
        self.container = container
        self.dir = dir
        self.provider = provider
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        // 一次性全给，不分页（工作区文件不多）
        guard !didEnumerate else {
            observer.finishEnumerating(upTo: nil)
            return
        }
        didEnumerate = true

        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey,
                                      .contentModificationDateKey, .creationDateKey]
        let list = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])) ?? []

        var items: [NSFileProviderItem] = []
        for u in list.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let v = try? u.resourceValues(forKeys: Set(keys))
            let isDir = v?.isDirectory ?? false
            let id = provider.itemIdentifier(for: u)
            items.append(NpcItem(identifier: id,
                                 parent: container,
                                 name: u.lastPathComponent,
                                 type: isDir ? .folder
                                     : (UTType(filenameExtension: u.pathExtension) ?? .data),
                                 caps: isDir
                                     ? [.allowsReading, .allowsContentEnumerating]
                                     : [.allowsReading],
                                 size: v?.fileSize,
                                 created: v?.creationDate,
                                 modified: v?.contentModificationDate,
                                 rel: id.rawValue))
        }

        observer.didEnumerate(items)
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from anchor: NSFileProviderSyncAnchor) {
        // 没有变更跟踪，让系统重新全量枚举
        observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("v1".utf8)))
    }
}
