# 微信回复建议 1.7.9

macOS 微信回复建议助手：读取或手动输入聊天内容，核对后生成三条回复建议。由用户选择、复制和发送，不自动发送微信消息。

## 系统要求

- Apple Silicon Mac，macOS 14 或更新版本。系统窗口选择器相关功能需要 macOS 15.2 或更新版本。
- 本地生成需要安装并运行 Ollama，并准备 `qwen3:8b` 模型；本地视觉功能优先使用 `qwen2.5vl:7b`。
- 云端生成可选 DeepSeek 或 Gemini，需自行配置对应 API Key，可能产生费用。

## 下载与使用

1. 下载仓库中的 `WechatReplySuggestions-1.7.9-macos-arm64.zip`，解压后打开应用。应用使用临时签名，macOS 可能要求用户在系统设置中确认打开。
2. 打开微信聊天，在助手中选择「读取当前聊天」或「选择微信窗口并读取」，根据系统提示选择微信窗口。也可手动框选消息或粘贴聊天文字。
3. 核对识别出的文字和说话人，选择语气、回复语言与模型，再生成建议。OCR 和视觉识别可能出错，请在使用前检查。
4. 选择、复制或修改建议，由自己决定是否发送。

## 隐私

屏幕内容在用户选择和确认后处理。本地识别使用 macOS Vision；本地视觉模型通过本机 Ollama 处理图片。使用云端模型前，应用会展示将发送的内容并要求确认。API Key 保存在 macOS 钥匙串。已确认的会话档案可能以明文保存在本机应用支持目录中。

## 从源码构建

安装 Xcode Command Line Tools，在项目目录运行：

```bash
bash build.sh
```

脚本针对 Apple Silicon 和 macOS 14 构建，在项目目录的上一级生成 `微信回复建议.app`，并使用临时签名。更新签名可能需要重新授予系统权限。

## 许可与致谢

项目使用 [MIT 许可证](LICENSE)。识别思路参考 terryyang20233/wechat-auto-reply；第三方许可见 [THIRD_PARTY_LICENSE.txt](THIRD_PARTY_LICENSE.txt)。Humanizer 的说明见 [HUMANIZER_INTEGRATION.md](HUMANIZER_INTEGRATION.md)。
