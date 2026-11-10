import Cocoa
@preconcurrency import ScreenCaptureKit
import Vision
import VideoToolbox

struct OCRSelection {
    let windowID: CGWindowID
    let pid: pid_t
    let frame: CGRect
    let header: CGRect
    let body: CGRect
    let headerText: String
    let fingerprint: [UInt8]
}
struct OCRBinding { let selection: OCRSelection; let profile: UUID }
func readerError(_ text: String) -> NSError { NSError(domain: "LocalScreenReader", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

final class CropPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ChatRegionPicker: NSObject {
    var panel: NSPanel?
    var completion: ((CGRect, CGRect) -> Void)?
    var cancelled: (() -> Void)?
    func show(frame: CGRect, singleArea: Bool = false, suggestedRect: CGRect? = nil) {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let rect = NSRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
        let panel = CropPanel(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .modalPanel
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.worksWhenModal = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        let view = CropSelectionView(frame: NSRect(origin: .zero, size: rect.size))
        view.singleArea = singleArea
        if singleArea {
            view.status.stringValue = L("拖动框选对方发来的文字，松开鼠标即识别；之后仍需核对确认。", "Drag over incoming text. Release to recognize, then review and confirm.")
            view.use.title = L("识别选区", "Recognize selection")
        }
        view.done = { [weak self] header, body in
            self?.panel?.orderOut(nil)
            self?.completion?(header, body)
            let panel = self?.panel
            DispatchQueue.main.async { [weak self, panel] in if self?.panel === panel { self?.panel = nil } }
        }
        view.cancel = { [weak self] in
            self?.panel?.orderOut(nil); self?.cancelled?()
            let panel = self?.panel
            DispatchQueue.main.async { [weak self, panel] in if self?.panel === panel { self?.panel=nil } }
        }
        if singleArea, let rect = suggestedRect, CGRect(origin:.zero,size:frame.size).contains(rect), view.selection.selectSingle(rect) {
            view.use.isEnabled = true
            view.status.stringValue = L("绿色框是本地 AI 的建议。先检查是否只包含对方文字；不合适请手动调整。", "Green box: local AI suggestion. Check that it includes only incoming text; adjust manually if needed.")
        }
        panel.contentView = view
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(view)
    }
}
final class CropSelectionView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var start: CGPoint?
    var dragRect = CGRect.zero
    var selection = CropState()
    var singleArea = false
    var done: ((CGRect, CGRect) -> Void)?
    var cancel: (() -> Void)?
    let status = NSTextField(wrappingLabelWithString: L("① 拖动框选联系人标题区域；完成后继续框选消息区。", "1. Select the contact title, then select the message area."))
    let use = NSButton(title: L("使用选区", "Use selection"), target: nil, action: nil)
    override init(frame: NSRect) {
        super.init(frame: frame)
        status.textColor = .white
        status.font = .systemFont(ofSize: 17, weight: .medium)
        status.frame = NSRect(x:24,y:bounds.height-112,width:bounds.width-48,height:48)
        addSubview(status)
        let redo=NSButton(title:L("手动调整", "Adjust manually"),target:self,action:#selector(resetSelection))
        redo.frame=NSRect(x:24,y:bounds.height-54,width:110,height:32); addSubview(redo)
        let cancel=NSButton(title:L("取消", "Cancel"),target:self,action:#selector(cancelSelection))
        cancel.frame=NSRect(x:145,y:bounds.height-54,width:90,height:32); addSubview(cancel)
        use.target=self; use.action=#selector(confirmSelection); use.isEnabled=false
        use.frame=NSRect(x:bounds.width-145,y:bounds.height-54,width:120,height:32); addSubview(use)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) unsupported") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.2).setFill(); bounds.fill()
        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect:NSRect(x:12,y:bounds.height-124,width:bounds.width-24,height:112),xRadius:10,yRadius:10).fill()
        for (rect,color) in [(selection.header,NSColor.systemOrange),(selection.body,NSColor.systemGreen)] {
            if let rect=rect { color.setStroke(); let path=NSBezierPath(rect:rect); path.lineWidth=3; path.stroke() }
        }
        NSColor.systemGreen.setStroke(); let path=NSBezierPath(rect:dragRect); path.lineWidth=3; path.stroke()
    }
    override func mouseDown(with event:NSEvent) {
        guard selection.stage != .review, selection.stage != .finished else { return }
        start=convert(event.locationInWindow,from:nil); dragRect = .zero
    }
    override func mouseDragged(with event:NSEvent) {
        guard let start=start else { return }
        let point=convert(event.locationInWindow,from:nil)
        dragRect=CGRect(x:min(start.x,point.x),y:min(start.y,point.y),width:abs(start.x-point.x),height:abs(start.y-point.y)).intersection(bounds)
        needsDisplay=true
    }
    override func mouseUp(with event:NSEvent) {
        guard start != nil else { return }; start=nil
        if singleArea ? selection.selectSingle(dragRect) : selection.select(dragRect) {
            dragRect = .zero
            if selection.stage == .body { status.stringValue=L("② 框选右侧文字消息区，排除左侧会话列表、标题及输入框。", "2. Select message text on the right. Exclude the sidebar, title and input box.") }
            if selection.stage == .review { status.stringValue = singleArea ? L("选区已就绪，正在识别文字…", "Selection ready. Recognizing text…") : L("两块区域已选好。检查后点击「使用选区」继续，浮层不会自动关闭。", "Both areas are selected. Check them, then click Use selection to continue."); use.isEnabled=true }
        } else { status.stringValue = singleArea ? L("请重新框选至少 100×40 的文字区域。", "Select a text area of at least 100×40.") : L("选区不合适，请重新拖动：标题高度20–160；消息区须在标题下方且至少220×100。", "Invalid selection. Title height: 20–160. Message area must be below it and at least 220×100.") }
        needsDisplay=true
        if singleArea && selection.stage == .review {
            DispatchQueue.main.async { [weak self] in self?.confirmSelection() }
        }
    }
    @objc func resetSelection() { selection=CropState(); start=nil; dragRect = .zero; use.isEnabled=false; status.stringValue = singleArea ? L("只框选对方发来的文字消息。", "Select only incoming text messages.") : L("① 重新框选联系人标题区域。", "1. Select the contact title again."); needsDisplay=true }
    @objc func confirmSelection() { guard let (header,body)=selection.confirm() else { return }; use.isEnabled=false; done?(header,body) }
    @objc func cancelSelection() { guard selection.stage != .finished else { return }; selection.stage = .finished; cancel?() }
    override func keyDown(with event:NSEvent) { if event.keyCode==53 { cancelSelection() }; if event.keyCode==36 { confirmSelection() } }
}

struct OCRText { let text: String; let box: CGRect; let confidence: Float }
struct OCRDraft {
    let text: String
    let needsReview: Bool

    init(text: String, needsReview: Bool) {
        self.text = LocalScreenReader.redactingCredentials(text)
        self.needsReview = needsReview
    }
}
// The continuation is consumed exactly once under the lock.
final class CaptureCompletion: @unchecked Sendable {
    private let lock=NSLock()
    private var continuation: CheckedContinuation<CGImage,Error>?
    init(_ continuation: CheckedContinuation<CGImage,Error>) { self.continuation=continuation }
    func finish(_ result: Result<CGImage,Error>) {
        lock.lock();let pending=continuation;continuation=nil;lock.unlock()
        pending?.resume(with:result)
    }
}
private final class WindowFrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // Mutable state is confined to the sample queue.
    var complete: ((CGImage?, Error?) -> Void)?
    var cancelled = false

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let complete,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pixels = sample.imageBuffer else { return }
        self.complete = nil
        var image: CGImage?
        let result = VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        complete(image, result == noErr ? nil : NSError(domain: NSOSStatusErrorDomain, code: Int(result)))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.complete?(nil, error); self.complete = nil }
    }

    let queue = DispatchQueue(label: "local.reply.window-frame")
}

enum LocalScreenReader {
    static func awaitCapture(timeout: TimeInterval = 15, start: (@escaping (CGImage?,Error?) -> Void) -> Void) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let pending=CaptureCompletion(continuation)
            DispatchQueue.global().asyncAfter(deadline:.now()+timeout) {
                pending.finish(.failure(readerError(L("系统截图超时，请重新选择微信窗口；也可先粘贴文字生成回复。", "Screenshot timed out. Select the WeChat window again, or paste text to generate replies."))))
            }
            start { image,error in
                if let error=error { pending.finish(.failure(error)) }
                else if let image=image { pending.finish(.success(image)) }
                else { pending.finish(.failure(readerError(L("系统没有返回截图，请重新选择微信窗口。", "No screenshot returned. Select the WeChat window again.")))) }
            }
        }
    }
    static func singleMessageDraft(rows: [OCRText]) throws -> OCRDraft {
        let lines = rows.map { $0.text.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw readerError(L("选区没有识别到文字。请框选清晰的文字气泡，不要选择图片或空白区域。", "No text found. Select clear text bubbles, not an image or empty area.")) }
        let value = lines.joined(separator:"\n")
        guard value.count <= 11995 else { throw readerError(L("识别文字超过 12000 字，请缩小选区。", "More than 12,000 characters recognized. Select a smaller area.")) }
        return OCRDraft(text:value, needsReview:rows.contains { $0.confidence < 0.5 })
    }
    static func accessDenied(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain && error.code == -3801
    }
    static func failureMessage(_ error: Error, appPath: String) -> String {
        if accessDenied(error) {
            return L("macOS 拒绝了这次窗口读取。点「选择微信窗口并读取」可重新授权。当前程序：\(appPath)", "macOS denied this capture. Use Choose WeChat window and read to grant access again. Current app: \(appPath)")
        }
        let error = error as NSError
        if error.domain == "LocalScreenReader" { return error.localizedDescription }
        return L("读取失败：\(error.localizedDescription)（\(error.domain) \(error.code)）。这不一定是权限问题。", "Read failed: \(error.localizedDescription) (\(error.domain) \(error.code)). This may not be a permission issue.")
    }
    static func sourceRect(_ rect: CGRect, windowSize: CGSize, contentRect: CGRect) throws -> CGRect {
        guard windowSize.width > 0, windowSize.height > 0,
              !rect.isEmpty, CGRect(origin: .zero, size: windowSize).contains(rect),
              !contentRect.isEmpty else { throw readerError(L("微信窗口大小已变化，请重新选择区域", "WeChat window size changed. Select the areas again.")) }
        let sx = contentRect.width / windowSize.width, sy = contentRect.height / windowSize.height
        let source = CGRect(x: contentRect.minX + rect.minX * sx, y: contentRect.minY + rect.minY * sy,
                            width: rect.width * sx, height: rect.height * sy)
        guard contentRect.contains(source) else { throw readerError(L("选区超出系统截图范围，请重新选择区域", "Selection exceeds the capture area. Select it again.")) }
        return source
    }
    static func capturePickerWindow(_ filter: SCContentFilter) async throws -> CGImage {
        let config = SCStreamConfiguration()
        let rect = filter.contentRect
        guard rect.width >= 1, rect.height >= 1 else {
            throw readerError(L("所选窗口没有可读取的画面，请展开微信主窗口。", "Restore the selected WeChat window to capture it."))
        }
        let scale = max(1, CGFloat(filter.pointPixelScale))
        config.width = Int(ceil(rect.width * scale))
        config.height = Int(ceil(rect.height * scale))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.capturesAudio = false
        if #available(macOS 14.2, *) { config.includeChildWindows = false }
        let output = WindowFrameOutput()
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        let frame: CGImage
        do {
            frame = try await awaitCapture(timeout: 6) { done in
                output.queue.async {
                    output.complete = done
                    stream.startCapture { error in
                        output.queue.async {
                            if let error {
                                output.complete?(nil, error)
                                output.complete = nil
                            } else if output.cancelled {
                                stream.stopCapture { _ in }
                            }
                        }
                    }
                }
            }
        } catch {
            output.queue.sync {
                output.complete = nil
                output.cancelled = true
            }
            try? await stream.stopCapture()
            throw error
        }
        try await stream.stopCapture()
        return frame
    }
    static func capture(window: SCWindow, rect: CGRect, authorizedFilter: SCContentFilter? = nil) async throws -> CGImage {
        let filter = authorizedFilter ?? SCContentFilter(desktopIndependentWindow: window)
        let wholeWindow = rect == CGRect(origin: .zero, size: window.frame.size)
        let source = try sourceRect(rect, windowSize: window.frame.size, contentRect: filter.contentRect)
        let scale = max(1, CGFloat(filter.pointPixelScale))
        if #available(macOS 26.0, *) {
            let config = SCScreenshotConfiguration()
            if !wholeWindow { config.sourceRect = source }
            config.width = Int(ceil(source.width * scale)); config.height = Int(ceil(source.height * scale))
            config.showsCursor = false; config.ignoreShadows = true
            config.includeChildWindows = false; config.dynamicRange = .sdr
            return try await awaitCapture { done in
                SCScreenshotManager.captureScreenshot(contentFilter:filter,configuration:config) { output,error in done(output?.sdrImage,error) }
            }
        }
        let config = SCStreamConfiguration()
        if !wholeWindow { config.sourceRect = source }
        config.width = Int(ceil(source.width * scale)); config.height = Int(ceil(source.height * scale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.capturesAudio = false
        return try await awaitCapture { done in
            SCScreenshotManager.captureImage(contentFilter:filter,configuration:config) { image,error in done(image,error) }
        }
    }
    static func text(_ image: CGImage) throws -> [OCRText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            return OCRText(text: best.string, box: observation.boundingBox, confidence: best.confidence)
        }.sorted { abs($0.box.midY-$1.box.midY) > 0.015 ? $0.box.midY > $1.box.midY : $0.box.minX < $1.box.minX }
    }
    static func headerText(_ image: CGImage) throws -> String {
        try headerText(rows: text(image))
    }
    static func headerText(rows: [OCRText]) throws -> String {
        let value = rows.filter { $0.confidence >= 0.5 }.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count < 180, !["微信","WeChat","Weixin"].contains(value) else { throw readerError(L("标题识别不清，请重新框选联系人姓名区域", "Contact title is unclear. Select the contact name again.")) }
        return value
    }
    static func fingerprint(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 128*32)
        bytes.withUnsafeMutableBytes { buffer in
            if let context = CGContext(data: buffer.baseAddress, width: 128, height: 32, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) { context.draw(image, in: CGRect(x:0,y:0,width:128,height:32)) }
        }
        return bytes
    }
    static func sameHeader(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard !a.isEmpty, a.count == b.count else { return false }
        let changed = zip(a,b).filter { abs(Int($0)-Int($1)) > 12 }.count
        return Double(changed)/Double(a.count) < 0.003
    }
    static func transcript(_ image: CGImage) throws -> String {
        let draft = try transcriptDraft(image, rows: text(image))
        guard !draft.needsReview else { throw readerError(L("识别内容需要人工核对", "Recognized text needs review.")) }
        return draft.text
    }
    static func transcriptDraft(_ image: CGImage, rows: [OCRText], labelByBubbleColor: Bool = false) throws -> OCRDraft {
        let rep = NSBitmapImageRep(cgImage: image)
        var messages: [String] = []
        var needsReview = false
        for row in rows.reversed() {
            let content = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty { continue }
            if content.range(of: #"^(\d{1,2}:\d{2}|\d{4}[年/.-]\d{1,2}[月/.-]\d{1,2}日?(\s*\d{1,2}:\d{2})?|(昨天|今天|星期[一二三四五六日天])(\s*\d{1,2}:\d{2})?|以下为新消息|以下是新消息)$"#, options: .regularExpression) != nil { continue }
            let box = row.box
            let x0 = max(0,Int(box.minX*Double(image.width))-12), x1 = min(image.width-1,Int(box.maxX*Double(image.width))+12)
            let y0 = max(0,Int((1-box.maxY)*Double(image.height))-8), y1 = min(image.height-1,Int((1-box.minY)*Double(image.height))+8)
            var green = 0; var total = 0
            for y in stride(from:y0,through:y1,by:4) { for x in stride(from:x0,through:x1,by:4) {
                guard let c = rep.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else { continue }
                total += 1
                if c.greenComponent > 0.20 &&
                    c.greenComponent - c.redComponent > 0.06 &&
                    c.greenComponent - c.blueComponent > 0.06 { green += 1 }
            } }
            let who: String
            if total > 0 && Double(green)/Double(total) > 0.20 { who = labelByBubbleColor ? "我" : "我（绿色气泡，OCR）" }
            else if labelByBubbleColor { who = "对方" }
            else if box.minX < 0.24 && box.midX < 0.68 { who = "对方（左侧文字，OCR）" }
            else { who = "待核对说话人"; needsReview = true }
            let prefix = row.confidence < 0.5 ? "[待核对文字] " : ""
            if row.confidence < 0.5 { needsReview = true }
            messages.append("\(prefix)[\(who)] \(content)")
            if messages.count == 35 { break }
        }
        guard !messages.isEmpty else { throw readerError(L("框选区域里没有可识别的文字消息", "No readable text messages in the selected area.")) }
        return OCRDraft(text: String(messages.reversed().joined(separator:"\n").suffix(12000)), needsReview: needsReview)
    }
    static func redactingCredentials(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?<![A-Za-z0-9_-])(?:sk-[A-Za-z0-9_-]{20,}|AIza[A-Za-z0-9_-]{35})(?![A-Za-z0-9_-])"#,
            with: L("[已隐藏疑似 API Key]", "[Possible API key hidden]"),
            options: .regularExpression
        )
    }

    static func reviewedText(_ text: String, oneShot: Bool = false) -> String? {
        var accepted = redactingCredentials(text)
        if oneShot {
            accepted = accepted.replacingOccurrences(of: #"(?m)^[ \t]*\[待核对文字\][ \t]*"#, with: "", options: .regularExpression)
            accepted = accepted.replacingOccurrences(of: #"(?m)^[ \t]*\[待核对说话人\]"#, with: "[说话人未确定]", options: .regularExpression)
        } else if accepted.contains("待核对文字") || accepted.contains("待核对说话人") {
            return nil
        }
        accepted = accepted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accepted.isEmpty, accepted.count <= 12000 else { return nil }
        return accepted
    }
}

extension Assistant {
    func reviewOCR(_ draft: OCRDraft, epoch: Int, oneShot: Bool = false, currentChatHasTitle: Bool? = nil) -> String? {
        guard epoch == readEpoch, oneShot || ocrBinding != nil else { return nil }
        readTimer?.invalidate(); readTimer = nil; autoReading = false; currentText = ""
        emit(["type":"autoRead","enabled":false,"confirmed":!oneShot])
        emit(["type":"readStatus","text":L("截图成功，正在核对识别文字；自动更新已暂停。", "Screenshot captured. Review the recognized text. Updates are paused."),"clear":!oneShot])
        if floatingPanel?.isVisible != true { window.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps:true)
        let alert = NSAlert()
        alert.messageText = L("核对聊天文字", "Review message text")
        alert.informativeText = L("可直接修改下面的识别结果。把「待核对」行改成正确的文字和说话人，或删除图片、表情里的无关文字。确认前不保存到档案，不交给模型。", "Edit the text below. Correct or delete lines marked 待核对 (needs review), including unrelated text from images. Nothing is saved to the profile or sent to a model until you confirm.")
        if oneShot {
            alert.informativeText = L("请核对以下内容确实是对方发来的消息，可直接修改错字。点击确认后会按当前语气和模型生成三条建议；云端模型仍会单独确认发送和费用。本次不建立档案、不自动继续读取。", "Check that this text contains only incoming messages; edit any errors. Confirm to generate three replies with your selected tone and model. Cloud requests still require separate approval and may incur fees. This capture creates no profile or ongoing reading.") + (draft.needsReview ? L("\n有文字识别置信度较低，请仔细核对。", "\nSome text has low recognition confidence. Please check it carefully.") : "")
        }
        if let hasTitle = currentChatHasTitle {
            alert.messageText = L("核对当前微信会话", "Review current WeChat chat")
            alert.informativeText = hasTitle
                ? L("请核对会话标题、消息和说话人。可直接修改识别结果，确认后生成回复建议。", "Check the conversation title, messages, and speakers. Edit any recognition errors, then confirm to generate reply suggestions.")
                : L("未识别到会话标题。请核对下方文字来自你要回复的聊天，确认后可直接生成建议。", "No conversation title was recognized. Confirm that the text is from the chat you want before generating replies.")
        }
        if oneShot && draft.needsReview {
            alert.informativeText += L("\n带「待核对」的文字可以直接修改，也可以在核对后一起确认。", "\nYou can edit the marked text or confirm it as shown after reviewing.")
        }
        let scroll = NSScrollView(frame: NSRect(x:0,y:0,width:520,height:240))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: NSRect(x:0,y:0,width:500,height:240))
        editor.isRichText = false; editor.font = .systemFont(ofSize:14)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.string = draft.text; scroll.documentView = editor; alert.accessoryView = scroll
        alert.window.initialFirstResponder = editor
        let confirmTitle: String
        if currentChatHasTitle != nil {
            confirmTitle = L("确认聊天文字并生成", "Confirm chat text and generate")
        } else {
            confirmTitle = oneShot ? L("确认对方消息并生成", "Confirm incoming text & generate") : L("确认文字，用于回复", "Confirm text for replies")
        }
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: L("暂不使用", "Not now"))
        while alert.runModal() == .alertFirstButtonReturn {
            guard epoch == readEpoch, oneShot || ocrBinding != nil else { return nil }
            if let text = LocalScreenReader.reviewedText(editor.string, oneShot: oneShot) { return text }
            alert.informativeText = oneShot
                ? L("请保留 1–12000 字的聊天内容后再确认。", "Keep 1–12,000 characters of chat text before confirming.")
                : L("请填写 1–12000 字，并核对标记的文字和说话人后再确认。", "Enter 1–12,000 characters and resolve the marked text and speakers before confirming.")
        }
        return nil
    }
    func screenFailure(_ error: Error) -> String {
        if LocalScreenReader.accessDenied(error) {
            screenAccessDenied = true
            clearWindowScope()
        }
        return LocalScreenReader.failureMessage(error, appPath: Bundle.main.bundleURL.path)
    }
    func beginOCR() {
        if windowScope == nil { prepareWeChatScope { [weak self] in self?.beginOCR() }; return }
        guard !readInProgress else { return }
        stopReading(L("正在设置本机截图识别", "Setting up local screenshot reading."),revokeWindow:false)
        guard !screenAccessDenied else {
            emit(["type":"readStatus","text":L("上次系统截图访问被拒绝。点「选择微信窗口并读取」可重新授权。", "The system denied the previous capture. Use Choose WeChat window and read to grant access again."),"clear":true]); return
        }
        // ScreenCaptureKit enforces authorization; a separate preflight must not block it.
        readInProgress = true
        let epoch = readEpoch
        Task { [self] in
            do {
                let windows = try await self.availableWeChatWindows()
                guard !windows.isEmpty else { throw readerError(L("系统没有找到可截取的微信主窗口，请展开微信并打开一个聊天后重试", "No capturable WeChat main window found. Restore WeChat and open a conversation.")) }
                await MainActor.run {
                    self.readInProgress = false
                    guard epoch == self.readEpoch else { return }
                    var target = windows[0]
                    if windows.count > 1 {
                        let choose = NSAlert()
                        choose.messageText = L("选择要读取的微信窗口", "Choose a WeChat window")
                        choose.informativeText = L("只会截取接下来在这个窗口中框选的区域。请选包含当前聊天的主窗口。", "Only selected areas of this window will be captured. Choose the main conversation window.")
                        let items = NSPopUpButton(frame:NSRect(x:0,y:0,width:420,height:28))
                        for w in windows { items.addItem(withTitle: "\(w.title ?? "微信") · \(Int(w.frame.width))×\(Int(w.frame.height)) · #\(w.windowID)") }
                        choose.accessoryView = items
                        choose.addButton(withTitle:L("使用这个窗口", "Use this window")); choose.addButton(withTitle:L("取消", "Cancel"))
                        guard choose.runModal() == .alertFirstButtonReturn, epoch == self.readEpoch else { return }
                        target = windows[items.indexOfSelectedItem]
                    }
                    guard target.isOnScreen else { self.stopReading(L("所选微信窗口未展开，请先恢复这个窗口再重试", "Restore the selected WeChat window, then try again.")); return }
                    let picker = ChatRegionPicker()
                    picker.cancelled = { [weak owner = self] in owner?.stopReading(L("已取消截图识别", "Screenshot reading canceled.")); owner?.window.makeKeyAndOrderFront(nil) }
                    picker.completion = { [weak owner = self] header, body in owner?.prepareOCR(window:target,header:header,body:body,epoch:epoch) }
                    self.regionPicker = picker
                    self.window.orderOut(nil)
                    NSRunningApplication(processIdentifier: target.owningApplication!.processID)?.activate(options: [])
                    picker.show(frame:target.frame)
                }
            } catch { await MainActor.run { self.readInProgress = false; if epoch == self.readEpoch { self.stopReading(self.screenFailure(error)); self.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true) } } }
        }
    }
    func prepareOCR(window target: SCWindow, header: CGRect, body: CGRect, epoch: Int) {
        emit(["type":"readStatus","text":L("正在识别联系人标题；确认联系人后才会读取消息正文。", "Reading the contact title. Messages will only be read after you confirm the contact.")])
        Task { [self] in
            do {
                let image = try await self.captureWindow(window:target,rect:header)
                let title = try LocalScreenReader.headerText(image)
                let selection = OCRSelection(windowID:target.windowID,pid:target.owningApplication!.processID,frame:target.frame,header:header,body:body,headerText:title,fingerprint:LocalScreenReader.fingerprint(image))
                await MainActor.run {
                    guard epoch == self.readEpoch else { return }
                    self.window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps:true)
                    let candidates = self.profiles.profiles().filter { $0.name == title || $0.sourceKey == "ocr:"+title }
                    let alert = NSAlert()
                    alert.messageText = L("确认 OCR 会话：\(title)", "Confirm OCR conversation: \(title)")
                    alert.informativeText = L("请核对姓名。这不是微信账号 ID，重名不能证明是同一人；默认建立新档案。只允许读取你框选的区域，每 4 秒一次。标题变化或切换会话时会停止；普通输入不会暂停。仅在你同意后读取、保存消息文字。", "Verify the name. It is not a WeChat account ID; names can be shared. A new profile is the default. Only your selected area is read, every 4 seconds. Title or conversation changes stop access; ordinary typing does not. Messages are read and saved only with your approval.")
                    let view = NSView(frame:NSRect(x:0,y:0,width:390,height:85))
                    let choices = NSPopUpButton(frame:NSRect(x:0,y:46,width:390,height:28))
                    choices.addItem(withTitle:L("新建独立档案（推荐）", "Create a separate profile (recommended)"))
                    for p in candidates { choices.addItem(withTitle:L("使用已有：\(p.name) · \(p.id.uuidString.prefix(8))", "Use existing: \(p.name) · \(p.id.uuidString.prefix(8))")) }
                    let direct = NSButton(checkboxWithTitle:L("我确认这是单人聊天，并已框选正确区域", "I confirm this is a one-to-one chat and the selected areas are correct"),target:nil,action:nil)
                    direct.frame=NSRect(x:0,y:8,width:390,height:28)
                    view.addSubview(choices); view.addSubview(direct); alert.accessoryView=view
                    alert.addButton(withTitle:L("同意，读取并保存", "Allow reading and saving")); alert.addButton(withTitle:L("取消", "Cancel"))
                    guard alert.runModal() == .alertFirstButtonReturn, direct.state == .on, epoch == self.readEpoch else { self.stopReading(L("未确认单人聊天，截图识别未开启", "One-to-one chat not confirmed. Screenshot reading was not started.")); return }
                    do {
                        let p: ContactProfile
                        if choices.indexOfSelectedItem == 0 { p=ContactProfile(id:UUID(),name:title,sourceKey:"ocr:"+title,snapshots:[]); try self.profiles.save(p) }
                        else { p=candidates[choices.indexOfSelectedItem-1] }
                        self.ocrBinding=OCRBinding(selection:selection,profile:p.id)
                        self.activeProfile=p.id; self.autoReading=true
                        self.emit(["type":"profile","name":p.name+" · 本机OCR","id":p.id.uuidString])
                        self.emit(["type":"autoRead","enabled":true])
                        self.installInteractionGuard(selection:selection)
                        self.readWeChat(prompt:false)
                        self.readTimer=Timer.scheduledTimer(withTimeInterval:4,repeats:true) { [weak owner = self] _ in owner?.readWeChat(prompt:false) }
                    } catch { self.stopReading(L("档案保存失败，读取未开启", "Could not save the profile. Reading was not started.")) }
                }
            } catch { await MainActor.run { if epoch == self.readEpoch { self.stopReading(self.screenFailure(error)); self.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true) } } }
        }
    }
    func installInteractionGuard(selection: OCRSelection) {
        interactionMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.keyDown]) { [weak self] event in
            guard let self = self, self.ocrBinding != nil, NSWorkspace.shared.frontmostApplication?.processIdentifier == selection.pid else { return }
            var navigation = false
            if event.type == .keyDown {
                navigation = !event.modifierFlags.intersection([.command,.control,.option]).isEmpty || [48,123,124,125,126].contains(event.keyCode)
            } else {
                let mouse = NSEvent.mouseLocation
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                let p = CGPoint(x:mouse.x,y:top-mouse.y)
                let sidebar = min(selection.header.minX,selection.body.minX)-8
                navigation = selection.frame.contains(p) && p.x-selection.frame.minX < sidebar
            }
            if navigation { self.stopReading(L("检测到会话导航操作，已结束当前授权；请确认新会话。", "Conversation navigation detected. Access ended. Confirm the new conversation.")) }
        }
    }
    func readOCR(_ binding: OCRBinding) {
        guard !readInProgress else { return }
        let epoch=readEpoch
        readInProgress=true
        Task { [self] in
            do {
                if let session=CGSessionCopyCurrentDictionary() as? [String:Any], session["CGSSessionScreenIsLocked"] as? Bool == true { throw readerError(L("屏幕锁定，截图识别已停止", "Screen locked. Screenshot reading stopped.")) }
                let s=binding.selection
                let windows=try await self.availableWeChatWindows()
                guard let target=windows.first(where:{$0.windowID==s.windowID && $0.owningApplication?.processID==s.pid}), target.frame==s.frame else { throw readerError(L("微信窗口已移动、缩放或关闭，请重新框选", "WeChat window moved, resized or closed. Select the areas again.")) }
                let before=try await self.captureWindow(window:target,rect:s.header)
                guard try LocalScreenReader.headerText(before)==s.headerText, LocalScreenReader.sameHeader(LocalScreenReader.fingerprint(before),s.fingerprint) else { throw readerError(L("聊天标题区域变化，已停止；不会把新聊天存入旧档案", "Conversation title changed. Reading stopped; the new chat will not be saved to the old profile.")) }
                let image=try await self.captureWindow(window:target,rect:s.body)
                let draft=try LocalScreenReader.transcriptDraft(image, rows: LocalScreenReader.text(image))
                let after=try await self.captureWindow(window:target,rect:s.header)
                guard try LocalScreenReader.headerText(after)==s.headerText, LocalScreenReader.sameHeader(LocalScreenReader.fingerprint(after),s.fingerprint) else { throw readerError(L("识别期间聊天发生变化，本次内容已丢弃", "Conversation changed during recognition. This capture was discarded.")) }
                let accepted: (String?, Bool) = await MainActor.run {
                    guard epoch == self.readEpoch, self.ocrBinding != nil else { return (nil,false) }
                    if draft.needsReview || self.currentText.isEmpty { return (self.reviewOCR(draft,epoch:epoch),true) }
                    return (draft.text,false)
                }
                guard let text = accepted.0 else {
                    await MainActor.run {
                        self.readInProgress=false
                        if epoch == self.readEpoch { self.emit(["type":"readStatus","text":L("尚未确认识别文字，自动更新已暂停。会话和选区保留，可重新开启更新再核对。", "Text not confirmed. Updates paused; conversation and selection retained. Resume updates to review again."),"clear":true]) }
                    }
                    return
                }
                if accepted.1 {
                    let latest = try await self.availableWeChatWindows()
                    guard let current = latest.first(where:{$0.windowID==s.windowID && $0.owningApplication?.processID==s.pid}), current.frame == s.frame else { throw readerError(L("核对期间微信窗口已变化，本次内容未保存", "WeChat window changed during review. Content was not saved.")) }
                    let verified = try await self.captureWindow(window:current,rect:s.header)
                    guard try LocalScreenReader.headerText(verified)==s.headerText, LocalScreenReader.sameHeader(LocalScreenReader.fingerprint(verified),s.fingerprint) else { throw readerError(L("核对期间会话已变化，本次内容未保存", "Conversation changed during review. Content was not saved.")) }
                }
                await MainActor.run {
                    self.readInProgress=false
                    guard epoch==self.readEpoch, self.ocrBinding != nil else { return }
                    do { try self.profiles.record(binding.profile,text:text) }
                    catch { self.stopReading(L("档案保存失败，已停止截图识别", "Could not save the profile. Screenshot reading stopped.")); return }
                    self.currentText=text
                    self.emit(["type":"context","text":text,"automatic":!accepted.1])
                    if accepted.1 { self.emit(["type":"readStatus","text":L("识别文字已确认，可生成回复。自动更新保持暂停；需要时可重新开启。 ", "Text confirmed. Generate replies now. Updates stay paused; you can resume them when needed.")]) }
                }
            } catch { await MainActor.run { self.readInProgress=false; if epoch==self.readEpoch { self.stopReading(self.screenFailure(error)); self.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true) } } }
        }
    }
}
