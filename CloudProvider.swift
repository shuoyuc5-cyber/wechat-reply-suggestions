import Cocoa
import Security

enum CloudKey {
    static func query(_ provider: String) -> [String:Any] { [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.shuoyu.replystudio." + provider,kSecAttrAccount as String:"api-key"] }
    static func read(_ provider:String) -> String? {
        var q=query(provider); q[kSecReturnData as String]=true; q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary,&result)==errSecSuccess, let data=result as? Data else { return nil }
        return String(data:data,encoding:.utf8)
    }
    static func save(_ key:String, provider:String) throws {
        let data=Data(key.utf8)
        var result=SecItemUpdate(query(provider) as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if result==errSecItemNotFound {
            var q=query(provider); q[kSecValueData as String]=data; q[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            result=SecItemAdd(q as CFDictionary,nil)
        }
        guard result==errSecSuccess else { throw NSError(domain:"Keychain",code:Int(result),userInfo:[NSLocalizedDescriptionKey:L("钥匙串保存失败（\(result)）", "Could not save to Keychain (\(result)).")]) }
    }
}
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session:URLSession, task:URLSessionTask, willPerformHTTPRedirection response:HTTPURLResponse, newRequest request:URLRequest, completionHandler:@escaping(URLRequest?)->Void) { completionHandler(nil) }
}
extension Assistant {
    func configureCloud(provider:String) {
        let name=provider == "gemini" ? "Gemini" : "DeepSeek"
        let alert=NSAlert()
        alert.messageText=L("设置 \(name) API Key", "Set \(name) API key")
        alert.informativeText=L("Key 只保存到本机 macOS 钥匙串，不显示在网页或聊天记录中。请直接在此输入；留空取消修改。API 使用由你的 \(name) 账户按量计费。", "Your key is stored only in macOS Keychain, never in the web interface or chat history. Enter it here; leave blank to keep the existing key. Your \(name) account is billed for API usage.")
        let field=NSSecureTextField(frame:NSRect(x:0,y:0,width:400,height:28)); field.placeholderString=L("粘贴你的 \(name) API Key", "Paste your \(name) API key")
        alert.accessoryView=field
        alert.addButton(withTitle:L("存入钥匙串", "Save to Keychain")); alert.addButton(withTitle:L("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key=field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !key.isEmpty, key.count<500, !key.contains("\n") else { emit(["type":"notice","text":L("未保存：Key 为空或格式不正确", "Not saved: the key is empty or invalid.")]); return }
        do { try CloudKey.save(key, provider:provider); emit(["type":"notice","text":L("\(name) Key 已保存到本机钥匙串。选择 \(name) 后生成时会再次确认发送内容。", "\(name) key saved to Keychain. Each \(name) generation asks you to confirm the text being sent.")] ) }
        catch { emit(["type":"notice","text":error.localizedDescription]) }
    }
    func cloudConsent(provider:String, context:String,history:String) -> String? {
        let name=provider == "gemini" ? "Gemini" : "DeepSeek"
        let host=provider == "gemini" ? "generativelanguage.googleapis.com" : "api.deepseek.com"
        guard let key=CloudKey.read(provider), !key.isEmpty else { emit(["type":"error","text":L("请先点「设置 \(name) Key」，在应用弹窗中填写密钥", "Click Set \(name) Key and enter your key in the app dialog first.")]); return nil }
        let epoch=readEpoch
        let alert=NSAlert()
        alert.messageText=L("本次使用 \(name) 云端生成？", "Use \(name) for this request?")
        alert.informativeText=L("下方文字包含当前聊天上下文、当前档案的历史片段和你想表达的意思，将发送到 \(host)，产生 API token 费用。不会发送截图或其他联系人档案。请检查后确认；取消可改用本地 Ollama。", "The text below includes current messages, this profile's earlier context and your intent. It will be sent to \(host) and incur API token charges. No screenshots or other profiles are sent. Review before approving, or cancel to use local Ollama.")
        let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:480,height:180)); scroll.hasVerticalScroller=true
        let text=NSTextView(frame:scroll.bounds); text.isEditable=false; text.string=history+"\n\n"+context
        scroll.documentView=text; alert.accessoryView=scroll
        alert.addButton(withTitle:L("同意发送并计费", "Send and accept API charges")); alert.addButton(withTitle:L("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else {
            if epoch == readEpoch { emit(["type":"readStatus","text":L("已取消云端生成，文字已保留，可选择本地模型后再生成。", "Cloud generation canceled. Text is retained; choose the local model to generate instead.")]) }
            return nil
        }
        guard epoch == readEpoch else { return nil }
        return key
    }
    func complete(_ payload:[String:Any], cloudKey:String?, cloudModel:String, provider:String, completion:@escaping(Result<[String:Any],Error>)->Void) {
        guard let key=cloudKey else { request("/api/chat",payload:payload,completion:completion); return }
        let allowed=["deepseek-flash","deepseek-v4-pro"]
        guard (provider == "deepseek" && allowed.contains(cloudModel)) || (provider == "gemini" && cloudModel.range(of:#"^gemini-[a-zA-Z0-9._-]{1,80}$"#,options:.regularExpression) != nil) else { completion(.failure(readerError(L("云端模型名称不正确", "Invalid cloud model name.")))); return }
        let name=provider == "gemini" ? "Gemini" : "DeepSeek"
        let endpoint=provider == "gemini" ? "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions" : "https://api.deepseek.com/chat/completions"
        var req=URLRequest(url:URL(string:endpoint)!)
        req.httpMethod="POST"; req.timeoutInterval=180
        req.setValue("application/json",forHTTPHeaderField:"Content-Type")
        req.setValue("Bearer "+key,forHTTPHeaderField:"Authorization")
        var body:[String:Any] = ["model":cloudModel,"messages":payload["messages"] ?? [],"stream":false,"thinking":["type":"disabled"],"temperature":0.5,"max_tokens":900,"response_format":["type":"json_object"]]
        if provider == "gemini" { body.removeValue(forKey:"thinking"); body["max_tokens"]=2048; body["reasoning_effort"]="low" }
        req.httpBody=try? JSONSerialization.data(withJSONObject:body)
        let config=URLSessionConfiguration.ephemeral; config.httpShouldSetCookies=false
        let session=URLSession(configuration:config,delegate:NoRedirectDelegate(),delegateQueue:nil)
        session.dataTask(with:req) { data,response,error in
            defer { session.finishTasksAndInvalidate() }
            if let error=error { completion(.failure(error)); return }
            guard let response=response as? HTTPURLResponse else { completion(.failure(readerError(L("\(name) 没有返回有效响应", "\(name) returned no valid response.")))); return }
            guard (200...299).contains(response.statusCode) else { completion(.failure(readerError(L("\(name) 请求失败（HTTP \(response.statusCode)），请检查 Key、余额及模型权限", "\(name) request failed (HTTP \(response.statusCode)). Check your key, balance and model access.")))); return }
            guard let data=data, let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any], let choices=json["choices"] as? [[String:Any]], let message=choices.first?["message"] as? [String:Any] else { completion(.failure(readerError(L("\(name) 返回格式异常", "\(name) returned an invalid response format.")))); return }
            completion(.success(["message":message,"usage":json["usage"] ?? [:]]))
        }.resume()
    }
}
