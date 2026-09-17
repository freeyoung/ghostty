@testable import Ghostty
import Testing

struct SurfaceViewAppKitTests {
    @Test(arguments: [
        ("\u{0008}", true),
        ("\u{001F}", true),
        ("\u{007F}", false),
        (" ", false),
        ("h", false),
        ("", false),
        ("\u{0009}x", false),
        ("\u{0009}\u{0009}", false),
    ])
    func suppressesOnlySingleC0ControlTextWhileComposing(
        text: String,
        expected: Bool
    ) {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                text,
                composing: true
            ) == expected
        )
    }

    @Test func doesNotSuppressControlTextWhenNotComposing() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                "\u{0008}",
                composing: false
            ) == false
        )
    }

    @Test func doesNotSuppressMissingText() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                nil,
                composing: true
            ) == false
        )
    }

    // MARK: Title

    @Test(arguments: [
        // The spinner and the space after it go.
        ("\u{25D0} a task", "a task"),
        ("\u{25D3}  a task", "a task"),
        // Every frame of it, and more than 1 of them.
        ("\u{25D0} x", "x"),
        ("\u{25D1} x", "x"),
        ("\u{25D2} x", "x"),
        ("\u{25D3} x", "x"),
        ("\u{25D0} \u{25D1} x", "x"),
        // Everything else stays, the star of an idle session above all.
        ("\u{2733} a task", "\u{2733} a task"),
        ("a task", "a task"),
        (" a task", " a task"),
        ("~/code \u{25D0}", "~/code \u{25D0}"),
        ("", ""),
        // A title that is nothing but a spinner keeps it.
        ("\u{25D0}", "\u{25D0}"),
        ("\u{25D0} ", "\u{25D0} "),
    ])
    func dropsOnlyTheSpinnerClaudeLeadsATitleWith(title: String, expected: String) {
        #expect(Ghostty.SurfaceView.titleWithoutSpinner(title) == expected)
    }
}
