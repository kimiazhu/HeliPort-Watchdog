import Foundation
import ServiceManagement
import CoreServices

/// 随系统启动（登录项）封装。
/// 首选 SMAppService（macOS 13+）；register/unregister 抛错时回退 deprecated
/// LSSharedFileList（session login items），回退逻辑隔离在本文件内。
enum LoginItems {

    enum LoginItemsError: LocalizedError {
        case notBundleApp
        case sharedFileListUnavailable

        var errorDescription: String? {
            switch self {
            case .notBundleApp:
                return "当前未以 .app bundle 方式运行，无法注册登录项（请用 make-app.sh 打包后运行）"
            case .sharedFileListUnavailable:
                return "无法访问系统登录项（LSSharedFileList 创建失败）"
            }
        }
    }

    /// 是否以 .app bundle 方式运行（swift run / 裸二进制为 false）
    static var isBundleApp: Bool {
        Bundle.main.bundleIdentifier != nil
            && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// 已注册（enabled 或 requiresApproval）均视为已勾选
    static func isEnabled() -> Bool {
        guard isBundleApp else { return false }
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        @unknown default:
            return false
        }
    }

    /// 启用/停用登录项；返回是否需要用户到「系统设置 → 通用 → 登录项」批准（requiresApproval）。
    @discardableResult
    static func setEnabled(_ on: Bool) throws -> Bool {
        guard isBundleApp else {
            throw LoginItemsError.notBundleApp
        }
        if on {
            do {
                try SMAppService.mainApp.register()
                return SMAppService.mainApp.status == .requiresApproval
            } catch {
                try SharedFileList.add()
                return false
            }
        } else {
            do {
                try SMAppService.mainApp.unregister()
                return false
            } catch {
                try SharedFileList.remove()
                return false
            }
        }
    }

    // MARK: - LSSharedFileList 回退（deprecated，仅 SMAppService 异常时使用）

    private enum SharedFileList {

        static func add() throws {
            guard let list = list() else {
                throw LoginItemsError.sharedFileListUnavailable
            }
            if contains(list) { return }
            let item = LSSharedFileListInsertItemURL(
                list,
                kLSSharedFileListItemLast.takeRetainedValue(),
                nil, nil,
                Bundle.main.bundleURL as CFURL,
                nil, nil
            )
            if item == nil {
                throw LoginItemsError.sharedFileListUnavailable
            }
        }

        static func remove() throws {
            guard let list = list() else {
                throw LoginItemsError.sharedFileListUnavailable
            }
            guard let bundlePath = bundleFilePath() else { return }
            for item in snapshotItems(list) {
                guard let url = resolvedURL(item) else { continue }
                if url.standardizedFileURL.path == bundlePath {
                    let status = LSSharedFileListItemRemove(list, item)
                    if status != noErr {
                        throw LoginItemsError.sharedFileListUnavailable
                    }
                }
            }
        }

        private static func contains(_ list: LSSharedFileList) -> Bool {
            guard let bundlePath = bundleFilePath() else { return false }
            for item in snapshotItems(list) {
                guard let url = resolvedURL(item) else { continue }
                if url.standardizedFileURL.path == bundlePath {
                    return true
                }
            }
            return false
        }

        private static func bundleFilePath() -> String? {
            Bundle.main.bundleURL.standardizedFileURL.path
        }

        private static func list() -> LSSharedFileList? {
            LSSharedFileListCreate(
                kCFAllocatorDefault,
                kLSSharedFileListSessionLoginItems.takeRetainedValue(),
                nil
            )?.takeRetainedValue()
        }

        private static func snapshotItems(_ list: LSSharedFileList) -> [LSSharedFileListItem] {
            var seed: UInt32 = 0
            guard let array = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem] else {
                return []
            }
            return array
        }

        private static func resolvedURL(_ item: LSSharedFileListItem) -> URL? {
            LSSharedFileListItemCopyResolvedURL(item, 0, nil)?.takeRetainedValue() as URL?
        }
    }
}
