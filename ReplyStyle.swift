import Foundation

// Adapted from the locally installed humanizer writing guidance, not an AI detector.
enum ReplyStyle {
    static func instructions(humanize: Bool, language: String) -> String {
        let output: String
        switch language {
        case "en": output = "Write all three replies in English, usually 5–30 words each."
        case "zh": output = "三条回复都用中文，每条通常 10–45 字。"
        default: output = "跟随对方最新一条实质消息的语言回复；英文消息用英文，中文消息用中文。界面语言不决定回复语言。英文每条通常 5–30 词，中文每条通常 10–45 字。"
        }
        guard humanize else { return output }
        return output + """

        Humanizer conversational editing pass: draft, silently check, then return only the final three replies.
        Keep the person's meaning, facts, relationship boundaries and chosen tone. Preserve names, numbers and quoted wording.
        Sound like a brief message to this specific person: react to what they actually said, use plain words and contractions when appropriate.
        Cut generic encouragement, customer-service language, flattery, canned openings, overexplaining, slogans and decorative metaphors.
        Avoid three alternatives with the same sentence structure or paraphrases of a single cliché. Vary them only when the context supports it.
        Do not invent feelings, personal experiences, opinions, shared memories, promises or relationship closeness to sound human.
        Do not add intentional errors, invisible characters or forced slang. No Markdown, commentary, self-audit or AI scores.
        For Chinese: 少用“值得注意的是”“综上所述”和口号式安慰；口语自然即可，不硬塞成语、撒娇、反问或网络梗。
        A single phrase is not proof of AI writing. Short chat replies cannot be reliably scored. Keep a natural phrase if it fits.
        """
    }
}

func L(_ chinese: String, _ english: @autoclosure () -> String) -> String {
    UserDefaults.standard.string(forKey: "interfaceLanguage") == "en" ? english() : chinese
}
