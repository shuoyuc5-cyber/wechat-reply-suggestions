import Cocoa

enum CurrentConversation {
    struct Regions {
        let title: CGRect
        let messages: CGRect
    }

    static func regions(in image: CGImage) throws -> Regions {
        let scale = min(1, 1100 / Double(image.width), 900 / Double(image.height))
        let width = Int(Double(image.width) * scale)
        let height = Int(Double(image.height) * scale)
        guard width >= 300, height >= 220,
              let pixels = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0),
              let data = pixels.data else { throw layoutError() }
        pixels.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        func pixel(_ x: Int, _ y: Int) -> Int { Int(bytes[y * width + x]) }

        // A pane divider must extend across most of the sampled rows or columns.
        func divider(_ range: Range<Int>, samples: [Int], across: (Int, Int) -> Int) -> Int? {
            var bestPosition: Int?
            var bestScore = 2
            for position in range {
                let contrasts = samples.map { sample in
                    let before = across(position - 2, sample)
                    let middle = across(position, sample)
                    let after = across(position + 2, sample)
                    return max(abs(before - middle), abs(middle - after), abs(before - after))
                }.sorted()
                let score = contrasts[contrasts.count / 4]
                if score > bestScore {
                    bestScore = score
                    bestPosition = position
                }
            }
            return bestPosition
        }

        let rows = (0..<48).map { height * (15 + $0 * 70 / 47) / 100 }
        guard let sidebar = divider(width * 16 / 100..<width * 59 / 100, samples: rows, across: pixel) else { throw layoutError() }
        let left = sidebar + 5
        let columns = (0..<48).map { left + (width - left) * (7 + $0 * 86 / 47) / 100 }
        let horizontal: (Int, Int) -> Int = { y, x in pixel(x, y) }
        guard let titleBottom = divider(height * 3 / 100..<height * 17 / 100, samples: columns, across: horizontal),
              let composer = divider(height * 43 / 100..<height * 94 / 100, samples: columns, across: horizontal) else { throw layoutError() }

        func originalRect(x: Int, y: Int, width w: Int, height h: Int) -> CGRect {
            CGRect(x: Double(x) * Double(image.width) / Double(width),
                   y: Double(y) * Double(image.height) / Double(height),
                   width: Double(w) * Double(image.width) / Double(width),
                   height: Double(h) * Double(image.height) / Double(height)).integral
        }
        return Regions(title: originalRect(x: left, y: 0, width: (width-left)*3/4, height: titleBottom - 2),
                       messages: originalRect(x: left, y: titleBottom + 4, width: width - left - 4,
                                              height: composer - titleBottom - 8))
    }

    static func recognize(
        _ image: CGImage,
        readText: (CGImage) throws -> [OCRText] = LocalScreenReader.text,
        describeImage: (CGImage) async throws -> String = LocalSelectionAI.describeChat
    ) async throws -> (draft: OCRDraft, hasTitle: Bool) {
        let regions = try regions(in: image)
        guard let title = image.cropping(to: regions.title),
              let messages = image.cropping(to: regions.messages) else { throw layoutError() }
        let name = try? LocalScreenReader.headerText(rows: readText(title))
        let draft: OCRDraft
        if let transcript = try? LocalScreenReader.transcriptDraft(messages, rows: readText(messages), labelByBubbleColor: true) {
            draft = transcript
        } else {
            try Task.checkCancellation()
            let description = try await describeImage(messages)
            guard !description.isEmpty else {
                throw readerError(L("当前窗口没有识别到可用的消息或图片。请在微信打开聊天，再读取。", "No usable message or image was recognized. Open a conversation in WeChat and read again."))
            }
            let label = L("【本机视觉识别，请核对】", "【Local vision description, verify】")
            draft = OCRDraft(text: label + "\n" + description, needsReview: true)
        }
        guard let name else { return (draft, false) }
        let prefix = "【" + L("会话标题", "Conversation title") + "】" + name + "\n"
        let recent = String(draft.text.suffix(12000 - prefix.count))
        return (OCRDraft(text: prefix + recent, needsReview: draft.needsReview), true)
    }

    private static func layoutError() -> NSError {
        readerError(L("没能可靠分辨微信的标题、聊天区和输入框。请展开微信主窗口并打开一个聊天，再点「读取当前聊天」。", "Could not reliably locate the title, messages and composer. Open a conversation in the expanded WeChat main window and try Read current chat again."))
    }
}

extension Assistant {
    func readCurrentConversation(options: [String: Any]) {
        guard !readInProgress, windowAccess?.isChoosing != true else {
            emit(["type": "notice", "text": L("正在处理上一项读取，请稍候。", "A read is already in progress.")])
            return
        }
        guard !screenAccessDenied else {
            emit(["type": "readStatus", "text": L("上次的窗口访问已失效。点「选择微信窗口并读取」可重新选择。", "Previous window access expired. Use Choose WeChat window and read to select it again.")])
            return
        }
        stopReading(L("正在识别当前微信会话…", "Reading the current WeChat conversation…"), preserveEditor: true)
        let epoch = readEpoch
        readInProgress = true
        selectionTask = Task {
            do {
                let scope = try await currentWeChatScope()
                let isCurrent = await MainActor.run {
                    guard epoch == self.readEpoch else {
                        self.readInProgress = false
                        return false
                    }
                    self.windowScope = scope
                    return true
                }
                guard isCurrent else { return }
                let frame = CGRect(origin: .zero, size: scope.window.frame.size)
                let image = try await captureWindow(window: scope.window, rect: frame, requireUnchangedFrame: false)
                try Task.checkCancellation()
                let (draft, hasTitle) = try await CurrentConversation.recognize(image, describeImage: { messages in
                    await MainActor.run {
                        guard epoch == self.readEpoch else { return }
                        self.emit(["type": "readStatus", "text": L("文字识别无结果，正在本机分析聊天图片…", "No OCR text found. Analyzing chat images locally…")])
                    }
                    return try await LocalSelectionAI.describeChat(messages)
                })
                await MainActor.run {
                    guard epoch == self.readEpoch else {
                        self.readInProgress = false
                        return
                    }
                    self.emit(["type": "ocrPreview", "text": draft.text])
                    let accepted = self.reviewOCR(draft, epoch: epoch, oneShot: true, currentChatHasTitle: hasTitle)
                    self.completeOneShot(accepted, epoch: epoch, options: options)
                }
            } catch {
                await MainActor.run { self.finishOneShotFailure(error, epoch: epoch, preserveEditor: true) }
            }
        }
    }
}
