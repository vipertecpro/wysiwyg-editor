import kotlin.system.exitProcess

// =============================================================================
// HtmlCoder round-trip tests (Android)
// =============================================================================
//
// The EXACT same case list as tests/native/ios/HtmlCoderTests.swift, run
// against the REAL coder sliced out of
// resources/android/WysiwygEditorFunctions.kt. If a case passes here and fails
// there (or vice versa), the two platforms have drifted apart and the plugin's
// central promise — same document, same HTML, either platform — is broken.
//
// The coder is pure Kotlin by design (no Android framework imports), which is
// what makes it testable off-device. Run with tests/native/android/run.sh.
// =============================================================================

private var failures = 0

/** Assert the normalised HTML produced for [input]. */
private fun check(label: String, input: String, expected: String) {
    val out = HtmlCoder.serialize(HtmlCoder.parse(input)).first
    if (out == expected) {
        println("  ✓ $label")
    } else {
        failures++
        println("  ✗ $label")
        println("      in:  ${input.show()}")
        println("      got: ${out.show()}")
        println("      exp: ${expected.show()}")
    }
}

/** Assert the plain-text rendition produced for [input]. */
private fun checkText(label: String, input: String, expected: String) {
    val out = HtmlCoder.serialize(HtmlCoder.parse(input)).second
    if (out == expected) {
        println("  ✓ text: $label")
    } else {
        failures++
        println("  ✗ text: $label")
        println("      got: ${out.show()}")
        println("      exp: ${expected.show()}")
    }
}

private fun String.show(): String =
    "\"" + replace("\n", "\\n").replace("\u00A0", "\\u00A0") + "\""

fun main() {
    println("Normalised documents survive unchanged")
    check("inline marks", "<p>Hello <strong>wor</strong>ld</p>", "<p>Hello <strong>wor</strong>ld</p>")
    check(
        "blocks and lists", "<h1>Title</h1><p><br></p><ul><li>one</li><li><em>two</em></li></ul>",
        "<h1>Title</h1><p><br></p><ul><li>one</li><li><em>two</em></li></ul>",
    )
    check(
        "link nesting", "<p><a href=\"https://x.io\"><strong>go</strong></a> now</p>",
        "<p><a href=\"https://x.io\"><strong>go</strong></a> now</p>",
    )
    check("blockquote", "<blockquote>Quoted.</blockquote>", "<blockquote>Quoted.</blockquote>")
    check("ordered list", "<ol><li>first</li><li>second</li></ol>", "<ol><li>first</li><li>second</li></ol>")
    check(
        "adjacent lists of different types stay separate",
        "<ul><li>a</li></ul><ol><li>b</li></ol>", "<ul><li>a</li></ul><ol><li>b</li></ol>",
    )
    check(
        "text color", "<p><span style=\"color:#EF4444\">red</span></p>",
        "<p><span style=\"color:#EF4444\">red</span></p>",
    )
    check(
        "highlight", "<p><mark style=\"background-color:#FDE68A\">hi</mark></p>",
        "<p><mark style=\"background-color:#FDE68A\">hi</mark></p>",
    )
    check("inline code", "<p><code>x = 1</code></p>", "<p><code>x = 1</code></p>")
    check(
        "full mark stack in contract order",
        "<p><a href=\"https://x.io\"><span style=\"color:#EF4444\"><strong><em><u><s><code>deep</code></s></u></em></strong></span></a></p>",
        "<p><a href=\"https://x.io\"><span style=\"color:#EF4444\"><strong><em><u><s><code>deep</code></s></u></em></strong></span></a></p>",
    )

    println("The empty document")
    check("empty input", "", "")
    check("a lone empty paragraph is the empty document", "<p><br></p>", "")

    println("Parser tolerance normalises input")
    check("b and i aliases", "<p><b>bold</b> <i>it</i></p>", "<p><strong>bold</strong> <em>it</em></p>")
    check("del and strike aliases", "<p><del>a</del><strike>b</strike></p>", "<p><s>ab</s></p>")
    check("div becomes p", "<div>text</div>", "<p>text</p>")
    check("h4 clamps to h3", "<h4>Deep</h4>", "<h3>Deep</h3>")
    check("br splits a block", "<p>one<br>two</p>", "<p>one</p><p>two</p>")
    check("trailing br does not add an empty block", "<p>x<br></p>", "<p>x</p>")
    check("unknown tags drop but keep their text", "<p>a <foo>b</foo> c</p>", "<p>a b c</p>")
    check("script contents are skipped", "<p>safe</p><script>alert(1)</script>", "<p>safe</p>")
    check("style contents are skipped", "<p>safe</p><style>p{color:red}</style>", "<p>safe</p>")
    check(
        "javascript: links are dropped, text kept",
        "<p><a href=\"javascript:alert(1)\">click</a></p>", "<p>click</p>",
    )
    check(
        "mailto links are kept", "<p><a href=\"mailto:a@b.io\">mail</a></p>",
        "<p><a href=\"mailto:a@b.io\">mail</a></p>",
    )
    check("tel links are kept", "<p><a href=\"tel:+123\">call</a></p>", "<p><a href=\"tel:+123\">call</a></p>")
    check(
        "entities decode and re-escape", "<p>a &amp; b &lt; c &gt; d &quot;q&quot;</p>",
        "<p>a &amp; b &lt; c &gt; d \"q\"</p>",
    )
    check("nbsp becomes a raw U+00A0", "<p>a&nbsp;b</p>", "<p>a\u00A0b</p>")
    check("whitespace between blocks is ignored", "<p>a</p>\n  <p>b</p>", "<p>a</p><p>b</p>")
    check(
        "adjacent identical runs merge", "<p><strong>a</strong><strong>b</strong></p>",
        "<p><strong>ab</strong></p>",
    )
    check(
        "mark without a style gets the default highlight", "<p><mark>hi</mark></p>",
        "<p><mark style=\"background-color:#FDE68A\">hi</mark></p>",
    )
    check("loose text opens an implicit paragraph", "loose text", "<p>loose text</p>")

    println("Plain-text rendition")
    checkText(
        "one line per block with list markers",
        "<h1>Title</h1><p>Body</p><ul><li>one</li><li>two</li></ul><ol><li>a</li><li>b</li></ol>",
        "Title\nBody\n- one\n- two\n1. a\n2. b",
    )
    checkText("marks are stripped", "<p>Hello <strong>wor</strong>ld</p>", "Hello world")
    checkText("empty document", "", "")

    println("Idempotence — a second round-trip changes nothing")
    val samples = listOf(
        "<h1>T</h1><p>a <strong>b</strong> c</p><ul><li>x</li></ul><blockquote>q</blockquote>",
        "<p><a href=\"https://x.io\">l</a></p><ol><li>1</li><li>2</li></ol><p><br></p><p>end</p>",
        "<p><span style=\"color:#3B82F6\"><mark style=\"background-color:#BFDBFE\">both</mark></span></p>",
    )
    samples.forEachIndexed { index, sample ->
        val once = HtmlCoder.serialize(HtmlCoder.parse(sample)).first
        val twice = HtmlCoder.serialize(HtmlCoder.parse(once)).first
        if (once == twice) {
            println("  ✓ sample ${index + 1}")
        } else {
            failures++
            println("  ✗ sample ${index + 1}")
            println("      1st: ${once.show()}")
            println("      2nd: ${twice.show()}")
        }
    }

    println("JSON — the fidelity format")
    run {
        val doc = mutableListOf(
            WysiwygBlock("p", id = "b1").apply {
                runs.add(WysiwygRun("Hi ", MarkSet()))
                runs.add(WysiwygRun("there", MarkSet(bold = true)))
            },
            WysiwygBlock("image", id = "b2").apply {
                attrs["src"] = "a.jpg"
                attrs["alt"] = "A photo"
            },
        )
        val expected = """{"version":2,"blocks":[""" +
            """{"id":"b1","type":"p","runs":[{"text":"Hi ","marks":{}},""" +
            """{"text":"there","marks":{"bold":true}}]},""" +
            """{"id":"b2","type":"image","src":"a.jpg","alt":"A photo"}]}"""
        val actual = JsonCoder.encode(doc)
        if (actual == expected) {
            println("  ✓ encodes text + media blocks with fixed key order")
        } else {
            failures++
            println("  ✗ encodes text + media blocks with fixed key order")
            println("      got: $actual")
            println("      exp: $expected")
        }
    }

    run {
        val json = """{"version":2,"blocks":[""" +
            """{"id":"p1","type":"h2","runs":[{"text":"T","marks":{"italic":true,"link":"https://x.io"}}]},""" +
            """{"id":"p2","type":"poll","question":"Best?","multiple":"false",""" +
            """"options":[{"id":"o1","label":"One"},{"id":"o2","label":"Two"}]}]}"""
        val decoded = JsonCoder.decode(json)
        val ok = decoded.size == 2 &&
            decoded[0].type == "h2" && decoded[0].id == "p1" &&
            decoded[0].runs.single().marks.italic &&
            decoded[0].runs.single().marks.link == "https://x.io" &&
            decoded[1].type == "poll" && decoded[1].attrs["question"] == "Best?" &&
            decoded[1].options.map { it.label } == listOf("One", "Two")
        if (ok) println("  ✓ decodes marks, media attrs and poll options")
        else { failures++; println("  ✗ decodes marks, media attrs and poll options -> $decoded") }
    }

    run {
        // encode -> decode -> encode must be a fixed point.
        val json = """{"version":2,"blocks":[""" +
            """{"id":"a","type":"ul","runs":[{"text":"x","marks":{"code":true}}]},""" +
            """{"id":"b","type":"divider"},""" +
            """{"id":"c","type":"embed","url":"https://v.io/1","provider":"vimeo"}]}"""
        val once = JsonCoder.encode(JsonCoder.decode(json))
        val twice = JsonCoder.encode(JsonCoder.decode(once))
        if (once == json && twice == once) {
            println("  ✓ JSON round-trips unchanged")
        } else {
            failures++
            println("  ✗ JSON round-trips unchanged")
            println("      1st: $once")
            println("      exp: $json")
        }
    }

    run {
        val decoded = JsonCoder.decode("not json at all")
        if (decoded.isEmpty()) println("  ✓ malformed JSON yields an empty document")
        else { failures++; println("  ✗ malformed JSON yields an empty document") }
    }

    run {
        // Escaping: quotes, backslashes and newlines must survive.
        val doc = mutableListOf(
            WysiwygBlock("p", id = "e").apply {
                runs.add(WysiwygRun("a \"q\" \\ b\nc", MarkSet()))
            },
        )
        val text = JsonCoder.decode(JsonCoder.encode(doc)).single().runs.single().text
        if (text == "a \"q\" \\ b\nc") println("  ✓ escapes and unescapes strings")
        else { failures++; println("  ✗ escapes and unescapes strings -> ${text.show()}") }
    }

    println("Media blocks in HTML")
    check(
        "image with caption",
        """<figure><img src="a.jpg" alt="A"><figcaption>Cap</figcaption></figure>""",
        """<figure><img src="a.jpg" alt="A"><figcaption>Cap</figcaption></figure>""",
    )
    check(
        "image without a caption",
        """<figure><img src="a.jpg" alt=""></figure>""",
        """<figure><img src="a.jpg" alt=""></figure>""",
    )
    check(
        "bare img outside a figure becomes a block",
        """<img src="a.jpg" alt="A">""",
        """<figure><img src="a.jpg" alt="A"></figure>""",
    )
    check(
        "video with poster",
        """<figure><video src="v.mp4" poster="p.jpg" controls></video></figure>""",
        """<figure><video src="v.mp4" poster="p.jpg" controls></video></figure>""",
    )
    check("divider", "<hr>", "<hr>")
    check(
        "embed with provider",
        """<figure data-embed="https://v.io/1" data-provider="vimeo"></figure>""",
        """<figure data-embed="https://v.io/1" data-provider="vimeo"></figure>""",
    )
    check(
        "media mixes with text blocks",
        """<p>Before</p><hr><p>After</p>""",
        """<p>Before</p><hr><p>After</p>""",
    )

    run {
        // A block still uploading exports with data-pending and NO src, so the
        // host can find it — rather than leaking a device path.
        val block = WysiwygBlock("image", id = "u1").apply {
            attrs["localPath"] = "/data/user/0/tmp/x.jpg"
            attrs["uploadId"] = "up-7"
            attrs["alt"] = "Pending"
        }
        val html = HtmlCoder.serialize(listOf(block)).first
        val expected = """<figure data-pending="up-7"><img alt="Pending"></figure>"""
        if (html == expected && !html.contains("/data/user")) {
            println("  ✓ a pending upload exports data-pending and never a device path")
        } else {
            failures++
            println("  ✗ a pending upload exports data-pending and never a device path")
            println("      got: ${html.show()}")
        }
    }

    run {
        // Polls survive an HTML round-trip via their escaped JSON payload.
        val poll = WysiwygBlock("poll", id = "pl").apply {
            attrs["question"] = "Best?"
            options.add(PollOption("o1", "One"))
            options.add(PollOption("o2", "Two"))
        }
        val html = HtmlCoder.serialize(listOf(poll)).first
        val back = HtmlCoder.parse(html).single()
        if (back.type == "poll" && back.attrs["question"] == "Best?" &&
            back.options.map { it.label } == listOf("One", "Two")
        ) {
            println("  ✓ poll options survive an HTML round-trip")
        } else {
            failures++
            println("  ✗ poll options survive an HTML round-trip -> ${html.show()}")
        }
    }

    checkText(
        "media contributes its caption / label to the plain text",
        """<p>A</p><figure><img src="a.jpg" alt="Alt"><figcaption>Cap</figcaption></figure><hr>""",
        "A\nCap\n---",
    )

    println("v1 compatibility — text-only documents are unchanged")
    run {
        val v1 = "<h1>T</h1><p>a <strong>b</strong></p><ul><li>x</li><li>y</li></ul>"
        val out = HtmlCoder.serialize(HtmlCoder.parse(v1)).first
        if (out == v1) println("  ✓ text-only HTML is byte-identical to v1")
        else { failures++; println("  ✗ text-only HTML changed: ${out.show()}") }
    }

    println("Segments — how a document lays out for editing")
    run {
        val blocks = HtmlCoder.parse("""<h1>T</h1><p>a</p><hr><p>b</p><figure><img src="x.jpg" alt=""></figure>""")
        val segments = segmentsOf(blocks)
        val shape = segments.map { seg ->
            when (seg) {
                is Segment.Text -> "text(${seg.blocks.size})"
                is Segment.Media -> "media(${seg.block.type})"
            }
        }
        if (shape == listOf("text(2)", "media(divider)", "text(1)", "media(image)")) {
            println("  ✓ consecutive text blocks collapse into one editor")
        } else {
            failures++
            println("  ✗ consecutive text blocks collapse into one editor -> $shape")
        }

        // Round-tripping through segments must not disturb the document.
        val back = HtmlCoder.serialize(blocksOf(segments)).first
        val expected = HtmlCoder.serialize(blocks).first
        if (back == expected) println("  ✓ segments flatten back to the same document")
        else { failures++; println("  ✗ segments flatten back -> ${back.show()}") }
    }

    // Backspacing at the start of a text segment deletes the media card above
    // it. Whether the two text runs either side then become ONE editor is
    // decided by re-segmenting, so that is what is asserted here.
    run {
        val blocks = HtmlCoder.parse("""<p>a</p><figure><img src="x.jpg" alt=""></figure><p>b</p>""")
        val before = segmentsOf(blocks).size
        val after = segmentsOf(blocks.filterIndexed { i, _ -> i != 1 })
        val merged = after.size == 1 && (after[0] as? Segment.Text)?.blocks?.size == 2
        if (before == 3 && merged) {
            println("  \u2713 deleting a card between two text runs leaves one editor")
        } else {
            failures++
            println("  \u2717 deleting a card between two text runs -> ${after.size} segment(s)")
        }
    }

    run {
        val blocks = HtmlCoder.parse("""<figure><img src="x.jpg" alt=""></figure><p>b</p>""")
        val after = segmentsOf(blocks.drop(1))
        if (after.size == 1) println("  \u2713 deleting the first card leaves the text below intact")
        else { failures++; println("  \u2717 deleting the first card -> ${after.size} segment(s)") }
    }

    run {
        val first = segmentsOf(emptyList()).first()
        val ok = first is Segment.Text && first.blocks.size == 1 && first.blocks[0].type == "p"
        if (ok) println("  ✓ an empty document still offers somewhere to type")
        else { failures++; println("  ✗ an empty document still offers somewhere to type") }
    }

    println("Embeds — provider recognised from the URL alone, with no network")
    run {
        val got = embedProvider("https://www.youtube.com/watch?v=abc")
        if (got == "YouTube") println("  \u2713 https://www.youtube.com/watch?v=abc -> YouTube")
        else { failures++; println("  \u2717 https://www.youtube.com/watch?v=abc -> YouTube -> $got") }
    }
    run {
        val got = embedProvider("https://youtu.be/abc")
        if (got == "YouTube") println("  \u2713 https://youtu.be/abc -> YouTube")
        else { failures++; println("  \u2717 https://youtu.be/abc -> YouTube -> $got") }
    }
    run {
        val got = embedProvider("http://m.youtube.com/watch?v=abc")
        if (got == "YouTube") println("  \u2713 http://m.youtube.com/watch?v=abc -> YouTube")
        else { failures++; println("  \u2717 http://m.youtube.com/watch?v=abc -> YouTube -> $got") }
    }
    run {
        val got = embedProvider("https://player.vimeo.com/video/1")
        if (got == "Vimeo") println("  \u2713 https://player.vimeo.com/video/1 -> Vimeo")
        else { failures++; println("  \u2717 https://player.vimeo.com/video/1 -> Vimeo -> $got") }
    }
    run {
        val got = embedProvider("https://x.com/anthropic/status/1")
        if (got == "X") println("  \u2713 https://x.com/anthropic/status/1 -> X")
        else { failures++; println("  \u2717 https://x.com/anthropic/status/1 -> X -> $got") }
    }
    run {
        val got = embedProvider("https://open.spotify.com/track/1")
        if (got == "Spotify") println("  \u2713 https://open.spotify.com/track/1 -> Spotify")
        else { failures++; println("  \u2717 https://open.spotify.com/track/1 -> Spotify -> $got") }
    }
    run {
        val got = embedProvider("https://example.com/youtube.com/fake")
        if (got == "") println("  \u2713 https://example.com/youtube.com/fake -> unknown")
        else { failures++; println("  \u2717 https://example.com/youtube.com/fake -> unknown -> $got") }
    }
    run {
        val got = embedProvider("https://notaservice.io/x")
        if (got == "") println("  \u2713 https://notaservice.io/x -> unknown")
        else { failures++; println("  \u2717 https://notaservice.io/x -> unknown -> $got") }
    }
    run {
        val got = embedProvider("")
        if (got == "") println("  \u2713 (empty) -> unknown")
        else { failures++; println("  \u2717 (empty) -> unknown -> $got") }
    }

    println("Validation — checked natively before a save is allowed")
    run {
        val doc = HtmlCoder.parse("<p>one two three</p>")
        val checks = listOf(
            Triple("no rules always passes", emptyMap<String, Any>(), true),
            Triple("minWords blocks a short document", mapOf<String, Any>("minWords" to 10), false),
            Triple("minWords passes when met", mapOf<String, Any>("minWords" to 3), true),
            Triple("maxWords blocks a long document", mapOf<String, Any>("maxWords" to 2), false),
            Triple(
                "requiredBlocks blocks a missing type",
                mapOf<String, Any>("requiredBlocks" to listOf("image")), false,
            ),
        )
        for ((label, rules, shouldPass) in checks) {
            val problem = validateDocument(doc, rules)
            if ((problem == null) == shouldPass) println("  ✓ $label")
            else { failures++; println("  ✗ $label -> $problem") }
        }

        val image = WysiwygBlock("image").apply { attrs["src"] = "a.jpg" }
        val withImage = doc + image
        if (validateDocument(withImage, mapOf("requiredBlocks" to listOf("image"))) == null &&
            validateDocument(withImage + image, mapOf("maxImages" to 1)) != null
        ) {
            println("  ✓ image rules count image blocks")
        } else {
            failures++
            println("  ✗ image rules count image blocks")
        }
    }

    println("Localization — host translations with placeholders")
    run {
        val es = mapOf(
            "ruleMinWords" to "Se necesitan {max} palabras — tienes {n}.",
            "save" to "Guardar",
        )
        val checks = listOf(
            Triple("falls back to English when untranslated",
                localized(emptyMap(), "save", "Save"), "Save"),
            Triple("uses the host translation",
                localized(es, "save", "Save"), "Guardar"),
            Triple("substitutes placeholders in the translation's own word order",
                localized(es, "ruleMinWords", "At least {max} words needed — you have {n}.", n = 12, max = 50),
                "Se necesitan 50 palabras — tienes 12."),
        )
        for ((label, actual, expected) in checks) {
            if (actual == expected) println("  ✓ $label")
            else { failures++; println("  ✗ $label -> $actual") }
        }

        val doc = HtmlCoder.parse("<p>one two</p>")
        val message = validateDocument(doc, mapOf("minWords" to 50), es)
        if (message == "Se necesitan 50 palabras — tienes 2.") {
            println("  ✓ validation messages are translated")
        } else {
            failures++
            println("  ✗ validation messages are translated -> $message")
        }
    }

    println("")
    if (failures == 0) {
        println("All HtmlCoder tests passed.")
    } else {
        println("$failures HtmlCoder test(s) failed.")
        exitProcess(1)
    }
}
