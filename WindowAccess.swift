import Cocoa
import ScreenCaptureKit

struct WindowScope {
    let window: SCWindow
    let filter: SCContentFilter
    let fromPicker: Bool
}
final class WindowAccess: NSObject, SCContentSharingPickerObserver {
    var completion: ((Result<WindowScope,Error>) -> Void)?
    private var active = false
    var isChoosing: Bool { active && completion != nil }
    static func accepts(bundleIDs: [String]) -> Bool {
        bundleIDs.count == 1 && bundleIDs[0] == "com.tencent.xinWeChat"
    }
    static func sameFrame(_ current: CGRect, _ selected: CGRect) -> Bool {
        [abs(current.minX-selected.minX),abs(current.minY-selected.minY),abs(current.width-selected.width),abs(current.height-selected.height)].allSatisfy{$0<=1}
    }
    static func visibleFrame(of window: SCWindow) -> CGRect? {
        let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow, .excludeDesktopElements], window.windowID) as? [[String: Any]]
        guard let item = windows?.first,
              item[kCGWindowNumber as String] as? UInt32 == window.windowID,
              item[kCGWindowIsOnscreen as String] as? Bool == true,
              item[kCGWindowOwnerPID as String] as? Int == Int(window.owningApplication?.processID ?? -1),
              let bounds = item[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }
    func present() {
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow]
        config.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "local.shuoyu.replystudio"]
        config.allowsChangingSelectedContent = false
        picker.defaultConfiguration = config
        picker.add(self); active = true; picker.isActive = true
        picker.present(using:.window)
    }
    private func finish(_ result: Result<WindowScope, Error>) {
        let callback = completion
        completion = nil
        callback?(result)
    }
    func cancel() {
        guard active else { return }; active = false
        SCContentSharingPicker.shared.remove(self)
        SCContentSharingPicker.shared.isActive = false
        completion = nil
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DispatchQueue.main.async { self.finish(.failure(readerError(L("已取消系统窗口选择，没有读取消息。", "Window selection canceled. No messages were read.")))) }
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        DispatchQueue.main.async {
            if #available(macOS 15.2, *) {
                let windows = filter.includedWindows
                guard filter.style == .window, windows.count == 1, let window = windows.first,
                      Self.accepts(bundleIDs:windows.compactMap{$0.owningApplication?.bundleIdentifier}) else {
                    self.finish(.failure(readerError(L("请选择单个微信聊天窗口，不能选择其他应用或整个屏幕。", "Select a single WeChat conversation window, not another app or an entire display.")))); return
                }
                self.finish(.success(WindowScope(window: window, filter: filter, fromPicker: true)))
            } else { self.finish(.failure(readerError(L("系统窗口授权模式需要 macOS 15.2 或更新版本。", "System window access requires macOS 15.2 or later.")))) }
        }
    }
    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        DispatchQueue.main.async { self.finish(.failure(error)) }
    }
}

extension Assistant {
    func selectWeChatWindow(then completion: @escaping () -> Void) {
        guard !readInProgress, windowAccess?.isChoosing != true else { return }
        stopReading(L("请在系统选择器中选择单个微信聊天窗口。", "Choose a single WeChat conversation window in the system picker."), preserveEditor: true)
        clearWindowScope()
        let access = WindowAccess()
        let epoch = readEpoch
        windowAccess = access
        access.completion = { [weak owner = self] result in
            guard let owner=owner,epoch==owner.readEpoch else { return }
            switch result {
            case .success(let scope):
                owner.windowScope = scope
                owner.screenAccessDenied = false
                completion()
            case .failure(let error):
                owner.clearWindowScope()
                owner.emit(["type":"error","text":error.localizedDescription])
            }
        }
        NSApp.activate(ignoringOtherApps:true)
        access.present()
    }
    func clearWindowScope() {
        windowAccess?.cancel()
        windowAccess = nil
        windowScope = nil
    }

    func currentWeChatScope() async throws -> WindowScope {
        // The picker filter is scoped to one user-approved window. Keep it intact.
        if let scope = windowScope, scope.fromPicker { return scope }
        guard CGPreflightScreenCaptureAccess() else {
            throw readerError(L("当前进程没有可用的屏幕录制权限。点「选择微信窗口并读取」可直接授权单个窗口。", "Screen Recording access is unavailable for this process. Use Choose WeChat window and read to grant access to one window."))
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == "com.tencent.xinWeChat" &&
            $0.windowLayer == 0 && $0.frame.width >= 350 && $0.frame.height >= 300
        }
        let ordered = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String:Any]] ?? []
        let target = ordered.lazy.compactMap { item -> SCWindow? in
            guard let id = item[kCGWindowNumber as String] as? NSNumber else { return nil }
            return windows.first { $0.windowID == id.uint32Value }
        }.first ?? windows.first
        guard let target else {
            throw readerError(L("找不到可见的微信聊天窗口，请打开微信主窗口并进入一个聊天。", "Open a conversation in the visible WeChat main window."))
        }
        return WindowScope(window: target, filter: SCContentFilter(desktopIndependentWindow: target), fromPicker: false)
    }

    func prepareWeChatScope(then completion: @escaping () -> Void) {
        guard !readInProgress, windowAccess?.isChoosing != true else { return }
        let epoch = readEpoch
        readInProgress = true
        Task {
            do {
                let scope = try await currentWeChatScope()
                await MainActor.run {
                    self.readInProgress = false
                    guard epoch == self.readEpoch else { return }
                    self.windowScope = scope
                    self.screenAccessDenied = false
                    completion()
                }
            } catch {
                await MainActor.run { self.finishOneShotFailure(error, epoch: epoch, preserveEditor: true) }
            }
        }
    }

    func availableWeChatWindows() async throws -> [SCWindow] {
        guard let scope=windowScope else { throw readerError(L("请先通过系统选择器选择微信窗口。", "Select a WeChat window using the system picker first.")) }
        return [scope.window]
    }
    func captureWindow(window target: SCWindow, rect: CGRect, requireUnchangedFrame: Bool = true) async throws -> CGImage {
        guard let scope=windowScope,scope.window.windowID==target.windowID,
              scope.window.owningApplication?.processID==target.owningApplication?.processID else {
            throw readerError(L("窗口授权已结束，请重新选择微信窗口。", "Window access ended. Select the WeChat window again."))
        }
        if scope.fromPicker && !requireUnchangedFrame {
            return try await LocalScreenReader.capturePickerWindow(scope.filter)
        }
        guard let current = WindowAccess.visibleFrame(of: target) else {
            throw readerError(L("微信窗口当前不可见。请展开微信主窗口后再读取。", "The WeChat window is hidden. Restore it and read again."))
        }
        guard !requireUnchangedFrame || WindowAccess.sameFrame(current, target.frame) else {
            throw readerError(L("微信窗口已移动或缩放，请重新选择区域。", "WeChat moved or resized. Select the area again."))
        }
        return try await LocalScreenReader.capture(window:target,rect:rect,authorizedFilter:scope.filter)
    }
}
