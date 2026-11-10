import Cocoa
import ScreenCaptureKit

extension Assistant {
    func beginOneShotOCR(options: [String:Any]) {
        if windowScope == nil { prepareWeChatScope { [weak self] in self?.beginOneShotOCR(options:options) }; return }
        guard !readInProgress else {
            emit(["type":"notice","text":L("仍在处理上一次读取，请稍候。", "A capture is still being processed. Please wait.")]); return
        }
        stopReading(L("准备一次性 OCR：只框选对方发来的文字消息。", "Preparing one-time OCR: select incoming text messages only."),revokeWindow:false)
        let epoch = readEpoch
        readInProgress = true
        Task {
            do {
                let windows = try await self.availableWeChatWindows()
                guard !windows.isEmpty else { throw readerError(L("未找到微信聊天窗口，请先打开微信聊天。", "No WeChat conversation window found. Open a chat first.")) }
                await MainActor.run {
                    self.readInProgress = false
                    guard epoch == self.readEpoch else { return }
                    var target = windows[0]
                    if windows.count > 1 {
                        let alert = NSAlert()
                        alert.messageText = L("选择微信聊天窗口", "Choose a WeChat conversation window")
                        let choices = NSPopUpButton(frame:NSRect(x:0,y:0,width:400,height:28))
                        for window in windows { choices.addItem(withTitle:"\(window.title ?? "WeChat") · \(Int(window.frame.width))×\(Int(window.frame.height))") }
                        alert.accessoryView = choices
                        alert.addButton(withTitle:L("使用这个窗口", "Use this window")); alert.addButton(withTitle:L("取消", "Cancel"))
                        guard alert.runModal() == .alertFirstButtonReturn, epoch == self.readEpoch else { return }
                        target = windows[choices.indexOfSelectedItem]
                    }
                    guard target.isOnScreen else { self.stopReading(L("请先展开微信聊天窗口，再框选消息。", "Restore the WeChat conversation window before selecting messages.")); return }
                    if options["smartSelection"] as? Bool == true {
                        self.suggestOneShotAI(window:target,epoch:epoch,options:options)
                    } else { self.showOneShotPicker(window:target,epoch:epoch,options:options) }
                }
            } catch { await MainActor.run { self.finishOneShotFailure(error,epoch:epoch) } }
        }
    }

    func finishOneShotFailure(_ error: Error, epoch: Int, preserveEditor: Bool = false) {
        readInProgress = false
        guard epoch == readEpoch else { return }
        let message = screenFailure(error)
        stopReading(message, preserveEditor: preserveEditor)
        emit(["type":"error","text":message])
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }

    func recognizeOneShot(window target: SCWindow, rect: CGRect, epoch: Int, options: [String:Any]) {
        guard epoch == readEpoch, !readInProgress else { return }
        readInProgress = true
        if floatingPanel?.isVisible != true { showMainWindow() }
        emit(["type":"readStatus","text":L("正在截取所选区域并在本机识别文字…", "Capturing the selected area and recognizing text locally…")])
        Task {
            do {
                let windows = try await self.availableWeChatWindows()
                guard let current = windows.first(where:{$0.windowID==target.windowID && $0.owningApplication?.processID==target.owningApplication?.processID}), current.frame==target.frame else {
                    throw readerError(L("框选时微信窗口位置或大小发生变化，请重新框选。", "WeChat moved or resized during selection. Select the area again."))
                }
                let image = try await self.captureWindow(window:current,rect:rect)
                let draft = try LocalScreenReader.singleMessageDraft(rows:LocalScreenReader.text(image))
                let accepted: String? = await MainActor.run {
                    guard epoch == self.readEpoch else { return nil }
                    self.emit(["type":"ocrPreview","text":draft.text])
                    self.emit(["type":"readStatus","text":L("已识别 \(draft.text.count) 字，请在弹窗核对后确认生成。", "Recognized \(draft.text.count) characters. Review and confirm in the dialog.")])
                    return self.reviewOCR(draft,epoch:epoch,oneShot:true)
                }
                await MainActor.run {
                    self.completeOneShot(accepted.map { "[对方]\n" + $0 }, epoch: epoch, options: options)
                }
            } catch { await MainActor.run { self.finishOneShotFailure(error,epoch:epoch) } }
        }
    }
    func completeOneShot(_ text: String?, epoch: Int, options: [String: Any]) {
        readInProgress = false
        guard epoch == readEpoch else { return }
        regionPicker = nil
        guard let text else {
            emit(["type": "ocrReviewCancelled"])
            emit(["type": "readStatus", "text": L("已取消本次生成。", "Generation cancelled.")])
            return
        }
        currentText = text
        emit(["type": "readStatus", "text": L("OCR 文字已确认，正在生成回复…", "OCR text confirmed. Generating replies…")])
        emit(["type": "ocrReady", "text": text, "epoch": epoch, "options": options])
        generate(context: text, intent: options["intent"] as? String ?? "",
                 tone: options["tone"] as? String ?? "自然日常",
                 provider: options["provider"] as? String ?? "local",
                 cloudModel: options["cloudModel"] as? String ?? "deepseek-flash")
    }

}

extension Assistant {
    func showOneShotPicker(window target: SCWindow, epoch: Int, options: [String:Any], suggestion: CGRect? = nil) {
        guard epoch == readEpoch else { return }
        let picker = ChatRegionPicker()
        picker.cancelled = { [weak owner = self] in owner?.stopReading(L("已取消本次 OCR。", "OCR capture canceled.")); owner?.window.makeKeyAndOrderFront(nil) }
        picker.completion = { [weak owner = self] _, body in owner?.recognizeOneShot(window:target,rect:body,epoch:epoch,options:options) }
        regionPicker = picker
        window.orderOut(nil)
        if let pid=target.owningApplication?.processID { NSRunningApplication(processIdentifier:pid)?.activate(options:[]) }
        picker.show(frame:target.frame,singleArea:true,suggestedRect:suggestion)
    }

    func suggestOneShotAI(window target: SCWindow, epoch: Int, options: [String:Any]) {
        guard epoch == readEpoch else { return }
        let alert = NSAlert()
        alert.messageText = L("允许本地 AI 建议选区？", "Allow local AI to suggest a selection?")
        alert.informativeText = L("本次会截取整个所选微信窗口用于定位，可能包含会话列表和消息内容。图片只在内存中处理，仅发送到本机 Ollama 的已安装视觉模型（优先 qwen2.5vl:7b），不会交给 DeepSeek 或 Gemini，也不写入档案或截图文件。AI 只建议位置；你检查绿色框并确认后才会识别消息和生成回复。", "This captures the entire selected WeChat window for layout analysis, including its conversation list and messages. The image stays in memory and is sent only to an installed vision model in local Ollama (preferring qwen2.5vl:7b), never DeepSeek or Gemini. No screenshot or profile is saved. AI only suggests a position; check the green box and confirm before messages are recognized and replies generated.")
        alert.addButton(withTitle:L("同意本机分析", "Allow local analysis"));alert.addButton(withTitle:L("改为手动框选", "Select manually"))
        let answer = alert.runModal()
        guard epoch == readEpoch else { return }
        guard answer == .alertFirstButtonReturn else { showOneShotPicker(window:target,epoch:epoch,options:options);return }
        readInProgress = true
        emit(["type":"readStatus","text":L("本地视觉 AI 正在分析选区，首次加载模型可能较慢…", "Local vision AI is locating the message. Initial model loading may take a while…")])
        selectionTask = Task {
            var suggestion: CGRect?
            var failure: String?
            do {
                try Task.checkCancellation()
                let windows = try await self.availableWeChatWindows()
                guard let current=windows.first(where:{$0.windowID==target.windowID && $0.owningApplication?.processID==target.owningApplication?.processID}), current.frame==target.frame else { throw readerError(L("微信窗口已变化，请手动框选。", "WeChat window changed. Select manually.")) }
                try Task.checkCancellation()
                let image = try await self.captureWindow(window:current,rect:CGRect(origin:.zero,size:current.frame.size))
                try Task.checkCancellation()
                suggestion = try await LocalSelectionAI.suggest(image:image,size:current.frame.size)
            } catch { failure = L("本地 AI 定位未完成：", "Local AI selection did not finish: ") + error.localizedDescription + L("。将改为手动框选；如连接失败，请先打开 Ollama。", ". Select manually; if the connection failed, open Ollama first.") }
            if Task.isCancelled { await MainActor.run { self.readInProgress=false }; return }
            do {
                let windows = try await self.availableWeChatWindows()
                guard let current=windows.first(where:{$0.windowID==target.windowID && $0.owningApplication?.processID==target.owningApplication?.processID}), current.isOnScreen else { throw readerError(L("微信窗口已关闭或未展开，本次定位已停止。", "WeChat closed or is not visible. Selection stopped.")) }
                await MainActor.run {
                    self.readInProgress = false
                    guard epoch == self.readEpoch else { return }
                    if current.frame != target.frame { suggestion=nil;failure=L("窗口在分析期间移动或缩放，已丢弃 AI 选区，请重新框选。", "Window moved or resized during analysis. AI suggestion discarded; select again.") }
                    if let failure=failure { self.emit(["type":"notice","text":failure]) }
                    self.showOneShotPicker(window:current,epoch:epoch,options:options,suggestion:suggestion)
                }
            } catch { await MainActor.run { self.finishOneShotFailure(error,epoch:epoch) } }
        }
    }
}
