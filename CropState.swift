import Foundation
import CoreGraphics
struct CropState {
    enum Stage { case header, body, review, finished }
    var stage: Stage = .header
    var header: CGRect?
    var body: CGRect?
    mutating func selectSingle(_ rect: CGRect) -> Bool {
        guard stage == .header, rect.width >= 100, rect.height >= 40 else { return false }
        header = .zero; body = rect; stage = .review
        return true
    }
    mutating func select(_ rect: CGRect) -> Bool {
        switch stage {
        case .header:
            guard rect.width >= 100, rect.height >= 20, rect.height <= 160 else { return false }
            header=rect; stage = .body; return true
        case .body:
            guard let header=header, rect.width >= 220, rect.height >= 100, rect.minY > header.maxY else { return false }
            body=rect; stage = .review; return true
        default: return false
        }
    }
    mutating func confirm() -> (CGRect,CGRect)? {
        guard stage == .review, let header=header, let body=body else { return nil }
        stage = .finished; return (header,body)
    }
}
