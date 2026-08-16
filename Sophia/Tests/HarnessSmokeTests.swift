import XCTest
@testable import Sophia

/// テスト基盤そのものが動くことだけを確かめる最小のテスト。
///
/// ここが落ちたら、失敗しているのは Store ではなく **ターゲット構成のほう**である
/// （TEST_HOST の解決、テストバンドルの署名、`@testable import` の可否）。
/// 切り分けのために、意図的に何にも依存しないテストを1つ残してある。
final class HarnessSmokeTests: XCTestCase {

    /// ホストアプリのシンボルがテストバンドルから見えているか。
    func testCanSeeHostAppSymbols() {
        XCTAssertEqual(AppInfo.name, "Sophia")
    }
}
