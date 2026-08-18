import Foundation
import GRDB

/// アダプタの載せ先（14.11節①）。CHECK 制約と綴りが一致している。
enum AdapterKind: String, Sendable, Codable, Equatable, CaseIterable,
                  DatabaseValueConvertible {

    /// **翻訳役（0.5B〜1.5B）。まずここへ焼く**（14.11節①）。
    ///
    /// 4つの理由: ① その人を知っている必要があるのは読む側だけである
    /// ② 16GB で回る見込みが高い ③ 再学習が安い ④ 本体が汎用のまま残る。
    case translator

    /// **本体（8B）。** 14.11節①が「恒久的には本体側の LoRA が本筋」とし、
    /// 14.16節⑩が理由を書いている ── **出力側の様式は翻訳役では担えない。書くのは本体だから。**
    ///
    /// 2026-08-18 の実測（14.13a節）で **16GB でも 8B の LoRA が回ることは分かった**
    /// （16層で山 7,069 MB、100周13.7分）ので、資源の制約としては閉じていない。
    /// **【未確認】実際に本体へ焼くかは決まっていない。**
    /// 綴りを先に置いてあるのは、値を後から足すと CHECK 制約を打ち直すことになるため。
    case base
}

/// `adapter_generations` テーブルの1行。
///
/// ## 14.14節には無い表である。足した理由
///
/// 14.14節が持っているのは `user_traits.adapter_gen`（整数1本）だけで、
/// **「どのアダプタに、いつ焼いたか」に答えられない。**
/// 14.15節が設定画面へ出すと決めている
/// 「**直近の学習: いつ / 何件で / どれだけかかったか / どの世代を使っているか / 戻す操作**」も、
/// 整数1本では出せない。
///
/// ## 重みそのものは入れない
///
/// > **アダプタ側はファイルで持つ**（14.11節③）。DB に重みを入れない ──
/// > **DB は原本、アダプタは複製**という関係を崩さないため。
///
/// この表が持つのはファイルの**在り処と素性**だけである。
///
/// ## `fuse` を呼ばないこと（14.11節④）
///
/// `ModelAdapter.fuse(with:)` は基底の重みへ恒久的に焼き込む。**戻れない。**
/// 焼き込んだ瞬間、「なぜそう解釈したか」を外から見る手段も、外す手段も同時に失う。
/// **この表が世代を並べて持っているのは、`load` / `unload` で戻れる前提だからである。**
struct AdapterGenerationRecord: Codable, Sendable, Equatable, Identifiable,
                                FetchableRecord, PersistableRecord {

    static let databaseTableName = "adapter_generations"

    var id: String

    /// 翻訳役か本体か。
    var adapter: AdapterKind

    /// 1 から始まる世代番号（14.11節③の `v1` / `v2` …）。
    /// `(adapter, generation)` に UNIQUE 制約がある。
    var generation: Int

    /// **どのモデルに対して学習したか。** 例 `mlx-community/Qwen3-8B-4bit`。
    ///
    /// ⚠ **14.14節にも 14.11節にも無い列で、こちらの判断で足した。**
    /// アダプタは基底モデルの層に差し込むものなので、
    /// **8B 用のアダプタを 0.6B の翻訳役へ読ませることはできない。**
    /// 世代がファイルとして並んでいる以上（14.11節③）、
    /// **どのモデル用かがファイルの外から分からないと、取り違えが起こりうる。**
    ///
    /// `conversations.model_id` と同じく **`models` への外部キーにしていない。**
    /// モデルを消しても、過去に何へ焼いたかの記録は残るほうがよい（第8章と同じ判断）。
    var modelID: String

    /// `Application Support` 配下の**相対**パス。例 `adapters/translator/v1`。
    ///
    /// `models.directory` と同じ規則。**絶対パスを入れないこと**
    /// ── サンドボックスのコンテナは移動しうる。
    var directory: String

    /// 何件の学習データで焼いたか（14.15節が設定画面へ出すと決めている）。
    ///
    /// ## 【未解決】必要な件数は分かっていない
    ///
    /// **10.5節は「数千件」、第14章の前提は「数十〜数百件」で、食い違っている**
    /// （14.10節 / 14.16節⑦）。**どちらが正しいかは測っていない。**
    ///
    /// **したがってこの層は件数に上限も下限も置いていない。**
    /// 1件でも記録できるし、何万件でも記録できる。
    /// `CHECK (sample_count >= 0)` があるだけで、これは
    /// 「負の件数は測定の誤りである」という以上の意味を持たない。
    /// **決着したときに、この列に貯まった実測が答え合わせに使える。**
    var sampleCount: Int

    /// 学習が終わった時刻。
    var trainedAt: Date

    /// 学習に要した時間。**nil を許す。**
    ///
    /// 14.11節②が「**中断できる**」を決めごとにしている
    /// （`Parameters.saveEvery` で途中保存、`progress` の戻り値で停止）。
    /// **中断された学習では所要時間が「かかった時間」を意味しない。**
    /// 0 や見積り値で埋めると、測っていない値が測った値の顔をして出てくる ──
    /// `MessageRecord.recordedStats` が同じ理由で nil を返している。
    var durationMs: Int?

    /// **いま適用されているか。**
    ///
    /// 同じアダプタで同時に有効な世代は1つだけである。
    /// これは部分 UNIQUE 索引（`WHERE is_active = 1`）で DB が守っており、
    /// **アプリ側の書き忘れでは破れない。**
    /// 14.16節⑪が警告している「アダプタはモデルに1つである」に対応する構造でもある。
    var isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case adapter
        case generation
        case modelID = "model_id"
        case directory
        case sampleCount = "sample_count"
        case trainedAt = "trained_at"
        case durationMs = "duration_ms"
        case isActive = "is_active"
    }

    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .millisecondsSince1970
    }

    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .millisecondsSince1970
    }

    init(
        id: String = UUID().uuidString,
        adapter: AdapterKind = .translator,
        generation: Int,
        modelID: String,
        directory: String,
        sampleCount: Int,
        trainedAt: Date = Date(),
        durationMs: Int? = nil,
        isActive: Bool = false
    ) {
        self.id = id
        self.adapter = adapter
        self.generation = generation
        self.modelID = modelID
        self.directory = directory
        self.sampleCount = sampleCount
        self.trainedAt = trainedAt
        self.durationMs = durationMs
        self.isActive = isActive
    }
}

/// `user_trait_bakes` テーブルの1行。**追記専用。どの像がどの世代に入ったか。**
///
/// ## 14.14節には無い表である。足した理由
///
/// `user_traits.adapter_gen` は整数1本なので、**最新の1件しか覚えていられない。**
/// ところが 14.11節④の回復手順の第1段は「**前の世代のアダプタに戻す**」であり、
/// **戻した先の世代に何が入っていたかを言えなければ、
/// 戻したあとに「いま何が効いているか」を答えられない。**
///
/// 14.14節自身が `adapter_gen` の意義をそこに置いている ──
/// 「**世代を戻したときに『いま何が効いているか』が言える**」。
/// **整数1本ではそれが言えないので、対応表を別に持った。**
///
/// ## `revision` を持っているのが要点である
///
/// 焼いたのは**その時点の文**であって、いまの `user_traits.statement` ではない。
/// 焼いた後に訂正されると、**重みの中身と DB の最新の文がずれる。**
/// この列があると「v1 の重みに入っているのは第1版の文である」と言える ──
/// **NFR-12（何を根拠にしたか辿れる）は、この列が無いと焼いた瞬間に嘘になる。**
///
/// 主キーが `(trait_id, adapter_generation_id)` の複合なので `Identifiable` にはしていない
/// （`ModelFileRecord` と同じ）。
struct UserTraitBakeRecord: Codable, Sendable, Equatable,
                            FetchableRecord, PersistableRecord {

    static let databaseTableName = "user_trait_bakes"

    var traitID: String

    var adapterGenerationID: String

    /// **焼いた時点の `user_trait_revisions.revision`。**
    ///
    /// ⚠ ここに入るのは「記録した時点で最新だった版」である。
    /// **学習に渡した文が、記録するまでの間に訂正されていないことは呼び出し側の責任**
    /// である（この層は学習そのものを知らない）。
    var revision: Int

    var bakedAt: Date

    enum CodingKeys: String, CodingKey {
        case traitID = "trait_id"
        case adapterGenerationID = "adapter_generation_id"
        case revision
        case bakedAt = "baked_at"
    }

    static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .millisecondsSince1970
    }

    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .millisecondsSince1970
    }

    init(traitID: String, adapterGenerationID: String, revision: Int, bakedAt: Date = Date()) {
        self.traitID = traitID
        self.adapterGenerationID = adapterGenerationID
        self.revision = revision
        self.bakedAt = bakedAt
    }
}

/// 利用者像を消したときの結果（FR-28 / NFR-01）。
///
/// ## なぜ `Void` ではなくこの型を返すのか
///
/// **DB の行を消しても、重みからは消えないからである。**
///
/// > **重みは記録ではなく、複製である**（14.11節④）。
///
/// FR-28 は「削除したものは**完全に**消える」と書いている。
/// 焼いた後に DB だけ消して `Void` を返すと、
/// **アプリは「消えました」と言い、翻訳役は消したはずの像で読み続ける。**
/// これは 14.16節⑤（誤った利用者像は誤読を強化する）が
/// 最も悪い形で現れる経路であり、しかも**利用者からは見えない。**
///
/// `ReadOutcome`（16.3節）が「全部読んだとモデルが誤解するのが一番危ない」ために
/// 型で欠落を持ち回っているのと同じ手である。
/// **呼び出し側は `isFullyErased` を見て、必要ならアダプタを外すところまで行うこと**
/// （14.11節④の第2段 `unload`、第3段 翻訳層ごと切る）。
struct TraitErasureOutcome: Sendable, Equatable {

    /// DB から実際に消えた `user_traits` の件数。
    var deletedTraitCount: Int

    /// **消した像を焼き込んでいるアダプタ世代。** 空でなければ、まだ効いている。
    ///
    /// 有効な世代（`isActive`）だけでなく**過去の世代も入れてある。**
    /// 無効な世代のファイルはディスクに残っており、
    /// 14.11節④の第1段（前の世代へ戻す）で**いつでも復活しうる。**
    /// 「もう使っていないから安全」ではない。
    var generationsStillCarryingErasedTraits: [AdapterGenerationRecord]

    /// **本当に消えたか。** false なら、まだアダプタの中にいる。
    var isFullyErased: Bool { generationsStillCarryingErasedTraits.isEmpty }

    /// いま適用中の世代のうち、消した像を含むもの。**最も緊急に外すべき対象。**
    var activeGenerationsStillCarryingErasedTraits: [AdapterGenerationRecord] {
        generationsStillCarryingErasedTraits.filter(\.isActive)
    }
}
