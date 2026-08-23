import SwiftUI

struct ToolApprovalView: View {
    let request: ToolApprovalRequest
    let approve: () -> Void
    let reject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SophiaMetrics.space3) {
            HStack(spacing: SophiaMetrics.space2) {
                Image(systemName: iconName)
                    .foregroundStyle(SophiaColor.accent)
                Text("変更の承認")
                    .font(SophiaFont.title2)
                Spacer()
            }

            Text(request.summary)
                .font(SophiaFont.body)
                .foregroundStyle(SophiaColor.ink)

            VStack(alignment: .leading, spacing: SophiaMetrics.space1) {
                Text("操作")
                    .font(SophiaFont.subhead)
                    .foregroundStyle(SophiaColor.ink3)
                Text(request.operation)
                    .font(SophiaFont.body)

                Text("対象")
                    .font(SophiaFont.subhead)
                    .foregroundStyle(SophiaColor.ink3)
                    .padding(.top, SophiaMetrics.space1)
                ForEach(request.resolvedPaths, id: \.self) { path in
                    Text(path)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            if let preview = request.preview, !preview.isEmpty {
                ScrollView {
                    Text(preview)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(SophiaMetrics.space2)
                }
                .frame(minHeight: 100, maxHeight: 260)
                .background(SophiaColor.background)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(SophiaColor.separator, lineWidth: SophiaMetrics.hairline)
                )
            }

            HStack {
                Spacer()
                Button("拒否", role: .cancel, action: reject)
                    .keyboardShortcut(.cancelAction)
                Button("この変更を実行", action: approve)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(SophiaMetrics.space4)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 320)
    }

    private var iconName: String {
        switch request.risk {
        case .changesFile: "doc.badge.gearshape"
        case .deletesItem: "trash"
        case .changesGitBranch: "arrow.triangle.branch"
        }
    }
}
