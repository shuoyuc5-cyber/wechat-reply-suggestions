import Cocoa

extension Assistant {
    func checkLocalOCR() {
        func sample(title: String? = nil, uncertain: Bool = false) -> CGImage {
            let size=NSSize(width:800,height:title == nil ? 360 : 120)
            let image=NSImage(size:size); image.lockFocus()
            NSColor(calibratedWhite:0.94,alpha:1).setFill(); NSRect(origin:.zero,size:size).fill()
            let attrs: [NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:26),.foregroundColor:NSColor.black]
            if let title=title { (title as NSString).draw(at:NSPoint(x:30,y:40),withAttributes:attrs) }
            else if uncertain { ("Uncertain speaker" as NSString).draw(at:NSPoint(x:390,y:180),withAttributes:attrs) }
            else {
                NSColor.white.setFill(); NSBezierPath(roundedRect:NSRect(x:24,y:220,width:390,height:70),xRadius:10,yRadius:10).fill()
                ("Hello from Alice" as NSString).draw(at:NSPoint(x:44,y:240),withAttributes:attrs)
                NSColor(red:0.58,green:0.90,blue:0.32,alpha:1).setFill(); NSBezierPath(roundedRect:NSRect(x:380,y:100,width:390,height:70),xRadius:10,yRadius:10).fill()
                ("Thanks see you" as NSString).draw(at:NSPoint(x:410,y:120),withAttributes:attrs)
            }
            image.unlockFocus()
            return NSBitmapImageRep(data:image.tiffRepresentation!)!.cgImage!
        }
        let header=sample(title:"Alice"), other=sample(title:"Different Person"), chat=sample(), unknown=sample(uncertain:true)
        emit(["type":"notice","text":L("正在用内置示例检查本机文字识别，不读取微信…", "Checking OCR with built-in samples, without reading WeChat…")])
        readQueue.async {
            var details = ""
            do {
                details = try LocalScreenReader.text(chat).map { "\($0.text):\($0.confidence)" }.joined(separator: "; ")
                guard !LocalScreenReader.sameHeader(LocalScreenReader.fingerprint(header),LocalScreenReader.fingerprint(other)) else { throw readerError(L("标题变化检测未通过", "Title change detection failed.")) }
                guard try LocalScreenReader.headerText(header).contains("Alice") else { throw readerError(L("标题文字识别未通过", "Title recognition failed.")) }
                let single=try LocalScreenReader.singleMessageDraft(rows:LocalScreenReader.text(chat))
                guard single.text.contains("Hello from Alice") && single.text.contains("Thanks see you") else { throw readerError(L("一次性 OCR 文字读取未通过", "One-time OCR text reading failed")) }
                let transcript=try LocalScreenReader.transcript(chat)
                guard transcript.contains("对方") && transcript.contains("Hello from Alice") && transcript.contains("我（绿色") && transcript.contains("Thanks see you") else { throw readerError(L("文字或气泡位置识别未通过", "Text or bubble position recognition failed.")) }
                var rejected=false
                do { _=try LocalScreenReader.transcript(unknown) } catch { rejected=true }
                guard rejected else { throw readerError(L("不明确说话人的拦截检查未通过", "Unknown speaker guard check failed.")) }
                self.emit(["type":"notice","text":L("本机文字识别检查通过：示例文字、气泡方向、标题变化和不明确说话人拦截均正常。", "Local OCR passed: sample text, bubble direction, title changes and unknown speaker guards.")])
            } catch { self.emit(["type":"notice","text":L("本机文字识别检查未通过：", "Local OCR check failed: ")+error.localizedDescription + L("（内置样例：", " (built-in sample: ") + details + "）"]) }
        }
    }
}
