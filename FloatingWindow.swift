import Cocoa
import WebKit

final class AssistantPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum FloatingLayout {
    static func frame(saved: NSRect?, screen: NSRect) -> NSRect {
        let proposed = saved ?? NSRect(x:screen.maxX-424,y:screen.maxY-680,width:400,height:640)
        let width = min(screen.width,max(360,proposed.width))
        let height = min(screen.height,max(420,proposed.height))
        return NSRect(x:min(max(proposed.minX,screen.minX),screen.maxX-width),y:min(max(proposed.minY,screen.minY),screen.maxY-height),width:width,height:height)
    }
}

extension Assistant {
    func showMainWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }
    func setFloating(_ enabled: Bool, announce: Bool = true) {
        guard window != nil else { return }
        if enabled && floatingPanel == nil {
            let config = WKWebViewConfiguration()
            config.userContentController.add(self,name:"native")
            let view = WKWebView(frame:.zero,configuration:config)
            let panel = AssistantPanel(contentRect:NSRect(x:0,y:0,width:380,height:480),styleMask:[.titled,.closable,.resizable,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.title = L("回复建议浮窗 · 1.7.9", "Reply Suggestions Float · 1.7.9")
            panel.isReleasedWhenClosed=false;panel.hidesOnDeactivate=false;panel.isFloatingPanel=true
            panel.level = .floating;panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
            panel.minSize=NSSize(width:340,height:260);panel.contentView=view;panel.delegate=self
            floatingWeb=view;floatingPanel=panel
            let saved=UserDefaults.standard.string(forKey:"floatingFrame").map(NSRectFromString)
            let screen=window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1200,height:800)
            panel.setFrame(FloatingLayout.frame(saved:saved,screen:screen),display:true)
            if let url=Bundle.main.url(forResource:"float",withExtension:"html"),let html=try? String(contentsOf:url,encoding:.utf8) { view.loadHTMLString(html,baseURL:nil) }
        }
        let wasFloating=isFloating
        isFloating=enabled;UserDefaults.standard.set(enabled,forKey:"floatingWindow")
        if enabled { floatingPanel?.orderFrontRegardless() } else { rememberFloatingFrame();floatingPanel?.orderOut(nil) }
        if !enabled && wasFloating { stopReading(L("浮窗已隐藏，读取已停止。", "Float hidden. Reading stopped."),preserveEditor:activeProfile == nil && !readInProgress) }
        if announce { emit(["type":"floating","enabled":enabled]) }
    }
    func rememberFloatingFrame() {
        if let panel=floatingPanel { UserDefaults.standard.set(NSStringFromRect(panel.frame),forKey:"floatingFrame") }
    }
    func windowDidMove(_ notification: Notification) {
        if (notification.object as? NSWindow) === floatingPanel { rememberFloatingFrame() }
    }
    func windowDidEndLiveResize(_ notification: Notification) {
        if (notification.object as? NSWindow) === floatingPanel { rememberFloatingFrame() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === floatingPanel { setFloating(false); return false }
        sender.orderOut(nil)
        stopReading(L("窗口已隐藏，读取已停止。", "Window hidden. Reading stopped."))
        return false
    }
}
