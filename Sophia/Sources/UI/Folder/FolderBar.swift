import SwiftUI

/// **会話の上部に出る、フォルダの結び付き**（FR-19 / DESIGN.md 第16.7節）。
///
/// > | 出すもの | 場所 | 根拠 |
/// > |---|---|---|
/// > | 結び付いたフォルダ（外せる） | 会話の上部にチップ1つ | FR-19。**`armed` かどうかが一目で分かること** |
/// > | そのターンでツール定義に払ったトークン数 | 既存の統計行 | **FR-21 が守られているかを利用者が見張れる** |
///
/// ---
///
/// # 費用をチップに書いてある理由
///
/// **`armed` の間、モデルは毎ターン 322トークン ── 入力予算 1,000 の 32% ── を
/// ツール定義に払っている。** 利用者は1文字も打っていないのに、である。
///
/// > 無駄が痛みとして見えないと誰も減らさない（VISION の測定原則）
///
/// 16.2節は「**見えないと FR-21 は形骸化する**」と書いている。
/// 形骸化とは「結び付けっぱなしにする」ことで、それは Open WebUI が
/// 32個・4,550トークンを毎ターン注入して「こんにちは」への応答を34秒にしていたのと
/// **同じ構造**である。だから外す操作の真横に額を置く ──
/// **外せば 0 に戻る**ことが、額と ✕ が並んでいれば一目で分かる。
///
/// # `idle` でも何か出す
///
/// 何も出さないと、機能があること自体に気づけない。
/// ただし**主張しない** ── `ink3` の小さなボタン1つで、地に沈めてある。
struct FolderBar: View {

    @Bindable var model: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: SophiaMetrics.space1) {
            if let notice = model.folder.notice {
                noticeRow(notice)
            }
            if model.folder.isArmed {
                armedChip
            } else {
                idleButton
            }
        }
        .frame(maxWidth: SophiaLayout.columnMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SophiaMetrics.space5)
        .padding(.top, SophiaMetrics.space3)
    }

    // MARK: - idle（既定）

    /// **既定はこちらである。** 注入は 0 で、ツールの system ブロックは1文字も出ていない。
    private var idleButton: some View {
        Button {
            Task { await model.chooseFolder() }
        } label: {
            HStack(spacing: SophiaMetrics.space2) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 11))
                Text("フォルダを結び付ける")
                    .font(SophiaFont.subhead)
            }
            .foregroundStyle(SophiaColor.ink3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.folder.isChoosing)
        .help(
            "選んだフォルダの中のファイルを、Sophia が読めるようになります。"
            + "結び付けている間は毎ターン約 \(SophiaDefaults.toolDefinitionTokens) トークンを"
            + "ツールの説明に使います（入力の目安 \(SophiaDefaults.inputTokenBudget) の"
            + "\(model.folder.toolDefinitionBudgetPercent)%）。読み取りだけで、書き込みはしません")
    }

    // MARK: - armed

    private var armedChip: some View {
        HStack(spacing: SophiaMetrics.space2) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(SophiaColor.accentVivid)

            // 名前を押すと選び直せる。**外して選び直す2手を1手にするためだけの経路**で、
            // 通るのは `FolderPicker` の同じ1関数である（16.5節「ここが権限の唯一の入口」）。
            // 入口を増やしていないので、16.6節 約束1 は保たれている。
            Button {
                Task { await model.chooseFolder() }
            } label: {
                Text(model.folder.displayName ?? "")
                    .font(SophiaFont.subhead)
                    .foregroundStyle(SophiaColor.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // **解決後の絶対パスを出す**（16.6節の但し書き）。
            // 選んだつもりの場所と実際に読む場所が違うなら、見えているべきは後者。
            .help("\(model.folder.displayPath ?? "")\n押すと別のフォルダに選び直せます")

            Rectangle()
                .fill(SophiaColor.separator)
                .frame(width: SophiaMetrics.hairline, height: 12)

            costLabel

            Button {
                Task { await model.forgetFolder() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SophiaColor.ink3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("結び付けを外します。次のターンからツールの説明は送られなくなります（0 トークン）")
        }
        .padding(.horizontal, SophiaMetrics.space3)
        .padding(.vertical, SophiaMetrics.space1)
        .background(SophiaColor.surface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(SophiaColor.separator, lineWidth: SophiaMetrics.hairline))
    }

    /// **払っている額。** 文字色は `ink3` に留める ── 警告ではなく事実である。
    /// 予算の半分を超えたら `accent` に上げる（`accentVivid` は文字に使えない）。
    private var costLabel: some View {
        let tokens = model.folder.toolDefinitionTokens
        let percent = model.folder.toolDefinitionBudgetPercent
        let isHeavy = tokens * 2 > SophiaDefaults.inputTokenBudget
        return Text("ツール定義 \(tokens) トークン/ターン")
            .font(SophiaFont.footnote)   // `footnote` は既に monospacedDigit
            .foregroundStyle(isHeavy ? SophiaColor.accent : SophiaColor.ink3)
            .help(
                "この会話にフォルダが結び付いている間、送信のたびに"
                + "ツールの説明ぶん \(tokens) トークンを先頭に付けています"
                + "（入力の目安 \(SophiaDefaults.inputTokenBudget) の \(percent)%）。"
                + "結び付けを外すと 0 になります。実測値です（2026-08-18）")
    }

    // MARK: - 知らせ（16.8節）

    /// **自動で外したことを、外した理由と一緒に出す。**
    ///
    /// `TurnView.errorRow`（生成の失敗）とは見た目を変えてある ──
    /// これは失敗の報告ではなく**状態が変わったことの報告**で、
    /// 会話そのものは続いている（16.8節「会話は続行する」）。
    private func noticeRow(_ notice: ConversationFolder.Notice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SophiaMetrics.space2) {
            Image(systemName: notice.kind == .accessDenied ? "lock.slash" : "folder.badge.questionmark")
                .font(.system(size: 11))
                .foregroundStyle(SophiaColor.accentVivid)

            VStack(alignment: .leading, spacing: 2) {
                Text(notice.message)
                    .font(SophiaFont.body)
                    .foregroundStyle(SophiaColor.ink)
                if let hint = notice.hint {
                    Text(hint)
                        .font(SophiaFont.footnote)
                        .foregroundStyle(SophiaColor.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: SophiaMetrics.space2)

            // **次の行動をその場で取れるようにする**（16.8節「選び直しを促す」）。
            if notice.didDetach {
                Button("選び直す") {
                    Task { await model.chooseFolder() }
                }
                .controlSize(.small)
            }

            Button {
                model.folder.dismissNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SophiaColor.ink3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("この知らせを閉じます")
        }
        .padding(SophiaMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SophiaColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: SophiaMetrics.controlRadius))
        .overlay(
            RoundedRectangle(cornerRadius: SophiaMetrics.controlRadius)
                .stroke(SophiaColor.accentVivid.opacity(0.5), lineWidth: SophiaMetrics.hairline)
        )
    }
}
