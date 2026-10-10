#if os(macOS)
import AppKit
import CoreServices
import SwiftUI

/// A Finder-like file tree shown on the right side of a terminal window.
/// The root follows the working directory of the last focused surface.
struct FileSidebarView: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView

    @AppStorage("FileSidebarShowHidden") private var showHidden = false
    @State private var root: URL?
    @State private var reloadToken = 0

    /// The surface's working directory. This is only known when the shell reports it
    /// (shell integration / OSC 7), and multiplexers often swallow that report.
    private var surfaceURL: URL? {
        guard let pwd = surfaceView.pwd, !pwd.isEmpty else { return nil }
        return URL(fileURLWithPath: pwd, isDirectory: true)
    }

    private var defaultURL: URL {
        surfaceURL ?? FileManager.default.homeDirectoryForCurrentUser
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let root {
                FileOutlineView(
                    root: root,
                    showHidden: showHidden,
                    reloadToken: reloadToken,
                    surfaceView: surfaceView,
                    onSetRoot: { self.root = $0 })
            } else {
                Spacer()
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { root = defaultURL }
        .onChange(of: surfaceView.pwd) { _ in
            if let surfaceURL { root = surfaceURL }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        if panel.runModal() == .OK, let url = panel.url { root = url }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(root?.lastPathComponent ?? "")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(root?.path ?? "")
            Spacer(minLength: 4)
            headerButton("arrow.up", help: "상위 폴더") {
                root = root?.deletingLastPathComponent()
            }
            .disabled(root == nil || root?.path == "/")
            headerButton("folder", help: "폴더 선택") { chooseFolder() }
            headerButton("location", help: "터미널 위치로") { root = defaultURL }
            headerButton(showHidden ? "eye" : "eye.slash", help: "숨김 파일 보기") { showHidden.toggle() }
            headerButton("arrow.clockwise", help: "새로고침") { reloadToken += 1 }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

/// The draggable divider between the terminal and the file sidebar.
struct FileSidebarResizeHandle: View {
    @Binding var width: Double
    @State private var startWidth: Double?

    var body: some View {
        Divider()
            .overlay(
                Color.clear
                    .frame(width: 6)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? width
                                startWidth = start
                                width = min(max(start - value.translation.width, 160), 640)
                            }
                            .onEnded { _ in startWidth = nil }
                    )
            )
    }
}

// MARK: - Outline

private final class FileItem: NSObject {
    let url: URL
    let isDirectory: Bool
    var children: [FileItem]?

    var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }
}

private struct FileOutlineView: NSViewRepresentable {
    let root: URL
    let showHidden: Bool
    let reloadToken: Int
    let surfaceView: Ghostty.SurfaceView
    let onSetRoot: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.allowsMultipleSelection = true
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)

        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu
        context.coordinator.outlineView = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.surfaceView = surfaceView
        coordinator.onSetRoot = onSetRoot
        coordinator.update(root: root, showHidden: showHidden, reloadToken: reloadToken)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        weak var outlineView: NSOutlineView?
        weak var surfaceView: Ghostty.SurfaceView?
        var onSetRoot: ((URL) -> Void)?

        private var root: URL?
        private var showHidden = false
        private var reloadToken = 0
        private var rootItems: [FileItem] = []
        private var watcher: DirectoryWatcher?

        func update(root: URL, showHidden: Bool, reloadToken: Int) {
            if root != self.root {
                self.root = root
                self.showHidden = showHidden
                self.reloadToken = reloadToken
                rootItems = children(of: root)
                outlineView?.reloadData()
                outlineView?.scrollRowToVisible(0)
                watcher = DirectoryWatcher(path: root.path) { [weak self] paths in
                    MainActor.assumeIsolated { self?.filesChanged(paths) }
                }
            } else if showHidden != self.showHidden || reloadToken != self.reloadToken {
                self.showHidden = showHidden
                self.reloadToken = reloadToken
                reloadPreservingState()
            }
            outlineView?.sizeLastColumnToFit()
        }

        // MARK: Loading

        private func children(of url: URL) -> [FileItem] {
            let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
            let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys, options: options) else { return [] }

            return urls.map { url in
                var values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true {
                    values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: Set(keys))
                }
                let isDirectory = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
                return FileItem(url: url, isDirectory: isDirectory)
            }.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }

        private func loadedChildren(_ item: FileItem) -> [FileItem] {
            if let children = item.children { return children }
            let children = children(of: item.url)
            item.children = children
            return children
        }

        private var visibleItems: [FileItem] {
            guard let outlineView else { return [] }
            return (0..<outlineView.numberOfRows).compactMap { outlineView.item(atRow: $0) as? FileItem }
        }

        private func reloadPreservingState() {
            guard let outlineView, let root else { return }
            let expanded = Set(visibleItems.filter { outlineView.isItemExpanded($0) }.map(\.url.path))
            let selected = Set(outlineView.selectedRowIndexes.compactMap {
                (outlineView.item(atRow: $0) as? FileItem)?.url.path
            })
            let scrollOrigin = outlineView.enclosingScrollView?.contentView.bounds.origin

            rootItems = children(of: root)
            outlineView.reloadData()
            expand(rootItems, paths: expanded)

            let rows = IndexSet(visibleItems.enumerated().compactMap { selected.contains($1.url.path) ? $0 : nil })
            outlineView.selectRowIndexes(rows, byExtendingSelection: false)
            if let scrollOrigin { outlineView.enclosingScrollView?.contentView.scroll(to: scrollOrigin) }
        }

        private func expand(_ items: [FileItem], paths: Set<String>) {
            for item in items where item.isDirectory && paths.contains(item.url.path) {
                outlineView?.expandItem(item)
                expand(item.children ?? [], paths: paths)
            }
        }

        /// FSEvents reports every change below the root, so only reload when
        /// a directory that is actually on screen changed.
        private func filesChanged(_ paths: [String]) {
            guard let outlineView, let root else { return }
            var watched: Set<String> = [canonical(root.path)]
            for item in visibleItems where outlineView.isItemExpanded(item) {
                watched.insert(canonical(item.url.path))
            }
            if paths.contains(where: { watched.contains(canonical($0)) }) {
                reloadPreservingState()
            }
        }

        private func canonical(_ path: String) -> String {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let item = item as? FileItem else { return rootItems.count }
            return loadedChildren(item).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let item = item as? FileItem else { return rootItems[index] }
            return loadedChildren(item)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FileItem)?.isDirectory ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            (item as? FileItem)?.url as NSURL?
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? FileItem else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("FileCell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView)
                ?? makeCell(identifier)
            cell.textField?.stringValue = item.name
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
            cell.toolTip = item.url.path
            return cell
        }

        private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier

            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyUpOrDown

            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingMiddle
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            cell.addSubview(image)
            cell.addSubview(text)
            cell.imageView = image
            cell.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        @objc func doubleClicked(_ sender: NSOutlineView) {
            guard let item = sender.item(atRow: sender.clickedRow) as? FileItem else { return }
            if item.isDirectory {
                if sender.isItemExpanded(item) { sender.collapseItem(item) } else { sender.expandItem(item) }
            } else {
                NSWorkspace.shared.open(item.url)
            }
        }

        // MARK: Context menu

        /// The items a context menu applies to: the selection if the clicked
        /// row is part of it, otherwise only the clicked row.
        private var menuTargets: [FileItem] {
            guard let outlineView, outlineView.clickedRow >= 0 else { return [] }
            if outlineView.selectedRowIndexes.contains(outlineView.clickedRow) {
                return outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileItem }
            }
            return [outlineView.item(atRow: outlineView.clickedRow) as? FileItem].compactMap { $0 }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            let targets = menuTargets
            let urls = targets.map(\.url)

            guard !targets.isEmpty else {
                if let root {
                    menu.addItem(item("Finder에서 열기") { NSWorkspace.shared.open(root) })
                    menu.addItem(item("새로고침") { [weak self] in self?.reloadPreservingState() })
                }
                return
            }

            menu.addItem(item("열기") { urls.forEach { NSWorkspace.shared.open($0) } })
            menu.addItem(item("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting(urls) })
            menu.addItem(.separator())
            menu.addItem(item("터미널에 경로 입력") { [weak self] in
                self?.sendToTerminal(urls.map { Ghostty.Shell.escape($0.path) }.joined(separator: " ") + " ")
            })
            if targets.count == 1, let directory = targets.first, directory.isDirectory {
                menu.addItem(item("터미널에서 이 폴더로 이동") { [weak self] in
                    self?.runInTerminal("cd " + Ghostty.Shell.quote(directory.url.path))
                })
                menu.addItem(item("이 폴더를 루트로") { [weak self] in self?.onSetRoot?(directory.url) })
            }
            menu.addItem(item("경로 복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            })
            menu.addItem(.separator())
            menu.addItem(item("휴지통으로 이동") { [weak self] in
                for url in urls { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
                self?.reloadPreservingState()
            })
        }

        private func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(ClosureMenuTarget.run), keyEquivalent: "")
            let target = ClosureMenuTarget(action)
            item.target = target
            item.representedObject = target
            return item
        }

        // MARK: Terminal

        /// Inserts text at the prompt like a paste.
        private func sendToTerminal(_ text: String) {
            guard let surfaceView else { return }
            surfaceView.surfaceModel?.sendText(text)
            surfaceView.window?.makeFirstResponder(surfaceView)
        }

        /// Types a command and presses return. Pastes never execute, so this goes
        /// through the `text:` binding action whose argument is a Zig string literal.
        private func runInTerminal(_ command: String) {
            guard let surfaceView else { return }
            let literal = command
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            _ = surfaceView.surfaceModel?.perform(action: "text:" + literal + "\\r")
            surfaceView.window?.makeFirstResponder(surfaceView)
        }
    }
}

private final class ClosureMenuTarget: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run() { action() }
}

// MARK: - FSEvents

private final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void

    init?(path: String, onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            watcher.onChange(paths)
        }

        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
#endif
