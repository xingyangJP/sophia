import Foundation

/// モデルが書いてきた引数1つ。
///
/// **「型付きの値」であって「信用できる値」ではない。**
/// JSON として妥当でも、中身は `../../etc/passwd` かもしれない
/// （検証は `FolderContainment`。この型は何も判定しない）。
enum ToolArgumentValue: Sendable, Equatable, Decodable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case null
    /// 配列・入れ子の物体など、この層が扱わない形。**捨てずに「扱えない」として持つ** ──
    /// 捨てると「鍵が無い」と区別が付かず、モデルへの返答が変わる。
    case unsupported

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            // **Bool を Int より先に試すこと。** 逆にすると true が 1 になる処理系がありうる。
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .unsupported
        }
    }
}

/// モデルが書いてきた引数の袋。
///
/// ## なぜ緩く読むのか
///
/// 4bit 量子化された 8B が相手である。**形式の遵守は量子化が最初に壊すところ**（15.2節）で、
/// 実測では守れていたが（16.9節の実測記録）、**守れなかったときに往復を1回で
/// 打ち切らないのが 16.8節の要求**である。
///
/// `{"offset": "10"}` を「型が違う」と突き返すのは、**アプリの都合をモデルに払わせている。**
/// 数として読めるなら読む。**緩くしてよいのは形式だけで、パスの検証は1文字も緩めない** ──
/// あちらは封じ込め（16.5節）の仕事で、この型は触らない。
struct ToolArguments: Sendable, Equatable, Decodable {

    var values: [String: ToolArgumentValue]

    init(_ values: [String: ToolArgumentValue] = [:]) {
        self.values = values
    }

    // MARK: - JSON から

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) {
            self.intValue = intValue
            self.stringValue = String(intValue)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        var parsed: [String: ToolArgumentValue] = [:]
        for key in container.allKeys {
            parsed[key.stringValue] = try container.decode(ToolArgumentValue.self, forKey: key)
        }
        self.init(parsed)
    }

    /// **推論側との橋。** `MLXLMCommon` の `ToolCall.function.arguments`
    /// （`[String: JSONValue]`）は `Codable` なので、符号化して渡してもらえばここで読める。
    ///
    /// この経路にしてあるのは、**この層に MLX を import させないため**である
    /// （`FolderToolCatalog` の但し書きと同じ理由）。
    ///
    /// 読めなかったら**空として扱う。** そのあと「path が要る」という
    /// モデル向けの返答に落ちる（16.8節: 往復を1回で打ち切らない）。
    /// **throw して往復を落とすほうが、この場面では損である。**
    static func lenient(json data: Data) -> ToolArguments {
        (try? JSONDecoder().decode(ToolArguments.self, from: data)) ?? ToolArguments()
    }

    // MARK: - 取り出す

    /// 文字列として取り出す。**数や真偽値は文字列にしない。**
    /// `{"path": 5}` を `"5"` と読むと、**モデルの誤りが「5 というファイルが無い」に化ける。**
    func string(_ key: String) -> String? {
        if case .string(let value) = values[key] { return value }
        return nil
    }

    /// 最初に見つかった別名の文字列。
    func string(anyOf keys: [String]) -> String? {
        for key in keys {
            if let value = string(key) { return value }
        }
        return nil
    }

    /// 整数として取り出す。**文字列の "10" と小数の 10.0 も受ける。**
    ///
    /// 受けるのは「モデルが数のつもりで書いたもの」だけである。
    /// `true` や配列は数のつもりではないので nil を返す。
    func integer(_ key: String) -> Int? {
        switch values[key] {
        case .integer(let value):
            return value
        case .number(let value):
            guard value.isFinite, value.magnitude < 1e15 else { return nil }
            return Int(value.rounded())
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let value = Int(trimmed) { return value }
            guard let value = Double(trimmed), value.isFinite, value.magnitude < 1e15 else {
                return nil
            }
            return Int(value.rounded())
        default:
            return nil
        }
    }
}

/// **モデルが呼んだツール1回ぶん。**
///
/// 名前も引数も**モデルが書いた文字列そのまま**である。妥当性は何も保証されていない ──
/// 名前が3つのどれでもないこともある（16.8節「ツール名が一致しない」）。
/// 判定は `FolderToolExecution` が行い、どの失敗もモデルへの返答になる。
struct ToolCallRequest: Sendable, Equatable {

    /// モデルが書いたツール名。**正規化しないこと** ──
    /// 直して受けると「名前を間違えた」ことがモデルにも人間にも見えなくなる。
    var name: String

    var arguments: ToolArguments

    init(name: String, arguments: ToolArguments = ToolArguments()) {
        self.name = name
        self.arguments = arguments
    }

    /// 推論側からの橋（`ToolArguments.lenient(json:)` の説明を読むこと）。
    init(name: String, jsonArguments: Data) {
        self.init(name: name, arguments: .lenient(json: jsonArguments))
    }
}
