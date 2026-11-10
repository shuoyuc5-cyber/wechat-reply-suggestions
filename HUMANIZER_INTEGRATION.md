# Humanizer in Reply Suggestions 1.6

Studied the installed humanizer SKILL.md and its native Chinese appendix at /Users/shuoyuchen110417/.codex/skills/humanizer/. The app implements a small, original adaptation of its conversational writing guidance in ReplyStyle.swift; it does not bundle the skill, its examples or its scoring engine.

The optional More natural / 更自然 switch defaults on. It adds a draft/self-check/final instruction inside the existing generation request, shared by Ollama, DeepSeek and Gemini. It adds no second request, new service, dependency, credential or cloud destination. The original tone, facts and relationship boundaries remain authoritative. The pass removes filler and generic praise, avoids canned chatbot phrases and Markdown, and asks for distinct, context-specific alternatives without inventing experiences or intimacy.

Short chat messages cannot support reliable authorship scores. No AI probability or detector-evasion claim is presented. The Chinese appendix is provisional, so sentence-length statistics, blanket word bans and deliberate mistakes are not implemented. Quoted wording, proper names and numbers must be preserved. Final quality still depends on the selected model and the user's review.

Interface language (Chinese / English) and reply language (Match chat / Chinese / English) are independent, persisted preferences. Switching interface language does not translate, rewrite or discard conversations, intent or generated replies.
