import Foundation

// =============================================================================
// HtmlCoder round-trip tests (iOS)
// =============================================================================
//
// Exercises the parse → serialize contract documented in the README against
// the REAL coder compiled out of resources/ios/WysiwygEditorFunctions.swift.
// Run with tests/native/ios/run.sh; exits non-zero on the first failure so it
// can gate a release.
//
// The coder is pure Foundation by design (no UIKit), which is what makes it
// testable off-device — and what keeps it byte-identical to the Kotlin side.
// =============================================================================

var failures = 0

/// Assert the normalised HTML produced for `input`.
func check(_ label: String, _ input: String, _ expected: String) {
    let out = HtmlCoder.emit(HtmlCoder.parse(input)).html
    if out == expected {
        print("  ✓ \(label)")
    } else {
        failures += 1
        print("  ✗ \(label)")
        print("      in:  \(input.debugDescription)")
        print("      got: \(out.debugDescription)")
        print("      exp: \(expected.debugDescription)")
    }
}

/// Assert the plain-text rendition produced for `input`.
func checkText(_ label: String, _ input: String, _ expected: String) {
    let out = HtmlCoder.emit(HtmlCoder.parse(input)).text
    if out == expected {
        print("  ✓ text: \(label)")
    } else {
        failures += 1
        print("  ✗ text: \(label)")
        print("      got: \(out.debugDescription)")
        print("      exp: \(expected.debugDescription)")
    }
}

print("Normalised documents survive unchanged")
check("inline marks", "<p>Hello <strong>wor</strong>ld</p>", "<p>Hello <strong>wor</strong>ld</p>")
check("blocks and lists", "<h1>Title</h1><p><br></p><ul><li>one</li><li><em>two</em></li></ul>",
      "<h1>Title</h1><p><br></p><ul><li>one</li><li><em>two</em></li></ul>")
check("link nesting", "<p><a href=\"https://x.io\"><strong>go</strong></a> now</p>",
      "<p><a href=\"https://x.io\"><strong>go</strong></a> now</p>")
check("blockquote", "<blockquote>Quoted.</blockquote>", "<blockquote>Quoted.</blockquote>")
check("ordered list", "<ol><li>first</li><li>second</li></ol>", "<ol><li>first</li><li>second</li></ol>")
check("adjacent lists of different types stay separate",
      "<ul><li>a</li></ul><ol><li>b</li></ol>", "<ul><li>a</li></ul><ol><li>b</li></ol>")
check("text color", "<p><span style=\"color:#EF4444\">red</span></p>",
      "<p><span style=\"color:#EF4444\">red</span></p>")
check("highlight", "<p><mark style=\"background-color:#FDE68A\">hi</mark></p>",
      "<p><mark style=\"background-color:#FDE68A\">hi</mark></p>")
check("inline code", "<p><code>x = 1</code></p>", "<p><code>x = 1</code></p>")
check("full mark stack in contract order",
      "<p><a href=\"https://x.io\"><span style=\"color:#EF4444\"><strong><em><u><s><code>deep</code></s></u></em></strong></span></a></p>",
      "<p><a href=\"https://x.io\"><span style=\"color:#EF4444\"><strong><em><u><s><code>deep</code></s></u></em></strong></span></a></p>")

print("The empty document")
check("empty input", "", "")
check("a lone empty paragraph is the empty document", "<p><br></p>", "")

print("Parser tolerance normalises input")
check("b and i aliases", "<p><b>bold</b> <i>it</i></p>", "<p><strong>bold</strong> <em>it</em></p>")
check("del and strike aliases", "<p><del>a</del><strike>b</strike></p>", "<p><s>ab</s></p>")
check("div becomes p", "<div>text</div>", "<p>text</p>")
check("h4 clamps to h3", "<h4>Deep</h4>", "<h3>Deep</h3>")
check("br splits a block", "<p>one<br>two</p>", "<p>one</p><p>two</p>")
check("trailing br does not add an empty block", "<p>x<br></p>", "<p>x</p>")
check("unknown tags drop but keep their text", "<p>a <foo>b</foo> c</p>", "<p>a b c</p>")
check("script contents are skipped", "<p>safe</p><script>alert(1)</script>", "<p>safe</p>")
check("style contents are skipped", "<p>safe</p><style>p{color:red}</style>", "<p>safe</p>")
check("javascript: links are dropped, text kept",
      "<p><a href=\"javascript:alert(1)\">click</a></p>", "<p>click</p>")
check("mailto links are kept", "<p><a href=\"mailto:a@b.io\">mail</a></p>",
      "<p><a href=\"mailto:a@b.io\">mail</a></p>")
check("tel links are kept", "<p><a href=\"tel:+123\">call</a></p>", "<p><a href=\"tel:+123\">call</a></p>")
check("entities decode and re-escape", "<p>a &amp; b &lt; c &gt; d &quot;q&quot;</p>",
      "<p>a &amp; b &lt; c &gt; d \"q\"</p>")
check("nbsp becomes a raw U+00A0", "<p>a&nbsp;b</p>", "<p>a\u{00A0}b</p>")
check("whitespace between blocks is ignored", "<p>a</p>\n  <p>b</p>", "<p>a</p><p>b</p>")
check("adjacent identical runs merge", "<p><strong>a</strong><strong>b</strong></p>",
      "<p><strong>ab</strong></p>")
check("mark without a style gets the default highlight", "<p><mark>hi</mark></p>",
      "<p><mark style=\"background-color:#FDE68A\">hi</mark></p>")
check("loose text opens an implicit paragraph", "loose text", "<p>loose text</p>")

print("Plain-text rendition")
checkText("one line per block with list markers",
          "<h1>Title</h1><p>Body</p><ul><li>one</li><li>two</li></ul><ol><li>a</li><li>b</li></ol>",
          "Title\nBody\n- one\n- two\n1. a\n2. b")
checkText("marks are stripped", "<p>Hello <strong>wor</strong>ld</p>", "Hello world")
checkText("empty document", "", "")

print("Idempotence — a second round-trip changes nothing")
let samples = [
    "<h1>T</h1><p>a <strong>b</strong> c</p><ul><li>x</li></ul><blockquote>q</blockquote>",
    "<p><a href=\"https://x.io\">l</a></p><ol><li>1</li><li>2</li></ol><p><br></p><p>end</p>",
    "<p><span style=\"color:#3B82F6\"><mark style=\"background-color:#BFDBFE\">both</mark></span></p>",
]
for (index, sample) in samples.enumerated() {
    let once = HtmlCoder.emit(HtmlCoder.parse(sample)).html
    let twice = HtmlCoder.emit(HtmlCoder.parse(once)).html
    if once == twice {
        print("  ✓ sample \(index + 1)")
    } else {
        failures += 1
        print("  ✗ sample \(index + 1)")
        print("      1st: \(once.debugDescription)")
        print("      2nd: \(twice.debugDescription)")
    }
}

print("")
if failures == 0 {
    print("All HtmlCoder tests passed.")
} else {
    print("\(failures) HtmlCoder test(s) failed.")
    exit(1)
}
