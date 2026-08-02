import XCTest

@testable import GridServer

// Config-parsing tests for GridTypes.
//
// Written to close a mutation-testing gap: a 200-mutant campaign scored
// GridTypes at 0% (24/24 survived), meaning every parser here could be
// silently broken without a single test failing. These are the parsers behind
// ~/.config/thegrid/config.yaml, so a regression shows up as a layout that
// quietly ignores the user's config rather than as a crash.
//
// Each test below names the specific mutant it kills.
final class GridTypesParsingTests: XCTestCase {

    // MARK: - GridTrackSize.parse

    // Kills GridTypes.swift:42 `s == "auto"` -> `!=`.
    // Under that mutant "auto" falls through to the throw and "2fr" returns
    // .auto, so both directions are asserted.
    func test_parse_auto() throws {
        XCTAssertEqual(try GridTrackSize.parse("auto"), GridTrackSize(type: .auto))
        XCTAssertEqual(try GridTrackSize.parse("  auto  "), GridTrackSize(type: .auto))

        let fr = try GridTrackSize.parse("2fr")
        XCTAssertEqual(fr.type, .fr, "non-auto input must not be classified as auto")
    }

    func test_parse_fr() throws {
        XCTAssertEqual(try GridTrackSize.parse("2fr"), GridTrackSize(type: .fr, value: 2))
        XCTAssertEqual(try GridTrackSize.parse("0.5fr"), GridTrackSize(type: .fr, value: 0.5))
        XCTAssertEqual(try GridTrackSize.parse(" 3 fr "), GridTrackSize(type: .fr, value: 3))
    }

    func test_parse_px() throws {
        XCTAssertEqual(try GridTrackSize.parse("100px"), GridTrackSize(type: .px, value: 100))
        XCTAssertEqual(try GridTrackSize.parse(" 250 px "), GridTrackSize(type: .px, value: 250))
    }

    // Kills GridTypes.swift:81 `parts.count == 2` -> `!=`.
    // Under that mutant a well-formed two-part minmax() throws.
    func test_parse_minmax_wellFormed() throws {
        let parsed = try GridTrackSize.parse("minmax(100px, 2fr)")
        XCTAssertEqual(parsed, GridTrackSize(type: .minmax, min: 100, max: 2))

        let spaced = try GridTrackSize.parse("minmax( 80px , 1.5fr )")
        XCTAssertEqual(spaced, GridTrackSize(type: .minmax, min: 80, max: 1.5))
    }

    // The arity guard must reject both too few and too many parts.
    func test_parse_minmax_wrongArity_throws() {
        XCTAssertThrowsError(try GridTrackSize.parse("minmax(100px)"))
        XCTAssertThrowsError(try GridTrackSize.parse("minmax(100px, 2fr, 3fr)"))
    }

    // minmax() is checked before the px suffix; a malformed inner part must
    // throw rather than fall through to some other branch.
    func test_parse_minmax_malformedParts_throw() {
        XCTAssertThrowsError(try GridTrackSize.parse("minmax(100, 2fr)"), "min must carry px")
        XCTAssertThrowsError(try GridTrackSize.parse("minmax(100px, 2)"), "max must carry fr")
        XCTAssertThrowsError(try GridTrackSize.parse("minmax(abcpx, 2fr)"))
        XCTAssertThrowsError(try GridTrackSize.parse("minmax 100px, 2fr"), "missing parens")
    }

    func test_parse_invalid_throws() {
        XCTAssertThrowsError(try GridTrackSize.parse(""))
        XCTAssertThrowsError(try GridTrackSize.parse("100"))
        XCTAssertThrowsError(try GridTrackSize.parse("abcfr"))
        XCTAssertThrowsError(try GridTrackSize.parse("abcpx"))
        XCTAssertThrowsError(try GridTrackSize.parse("fr"))
    }

    // MARK: - GridTrackSize.description

    // Kills GridTypes.swift:109 and :114 `value == Double(Int(value))` -> `!=`.
    // That mutant swaps the integral and fractional formats, rendering
    // "2fr" as "2.00fr" and "0.50fr" as "0fr".
    func test_description_integralVsFractional() {
        XCTAssertEqual(GridTrackSize(type: .fr, value: 2).description, "2fr")
        XCTAssertEqual(GridTrackSize(type: .fr, value: 0.5).description, "0.50fr")
        XCTAssertEqual(GridTrackSize(type: .px, value: 100).description, "100px")
        XCTAssertEqual(GridTrackSize(type: .px, value: 12.5).description, "12.50px")
        XCTAssertEqual(GridTrackSize(type: .auto).description, "auto")
        XCTAssertEqual(
            GridTrackSize(type: .minmax, min: 100, max: 2).description,
            "minmax(100px, 2fr)"
        )
    }

    // MARK: - GridPaddingValue.parse

    func test_paddingValue_numericForms() throws {
        XCTAssertEqual(try GridPaddingValue.parse(12), GridPaddingValue(pixels: 12))
        XCTAssertEqual(try GridPaddingValue.parse(12.5), GridPaddingValue(pixels: 12.5))
        XCTAssertEqual(try GridPaddingValue.parse("16"), GridPaddingValue(pixels: 16))
    }

    // Kills GridTypes.swift:150 `hasSuffix("x") && !hasSuffix("px")` -> `||`.
    // "10px" satisfies the left operand, so under `||` it takes the
    // base-relative branch, drops one character, and throws on "10p".
    // The px and base-relative forms must stay distinct.
    func test_paddingValue_pxIsNotBaseRelative() throws {
        XCTAssertEqual(
            try GridPaddingValue.parse("10px"),
            GridPaddingValue(pixels: 10),
            "10px must parse as absolute pixels, not a base multiple"
        )

        XCTAssertEqual(
            try GridPaddingValue.parse("2x"),
            GridPaddingValue(baseMultiple: 2, isRelative: true),
            "2x must parse as a base-spacing multiple"
        )

        XCTAssertEqual(
            try GridPaddingValue.parse("0.5x"),
            GridPaddingValue(baseMultiple: 0.5, isRelative: true)
        )
    }

    func test_paddingValue_invalid_throws() {
        XCTAssertThrowsError(try GridPaddingValue.parse("abc"))
        XCTAssertThrowsError(try GridPaddingValue.parse("abcx"))
        XCTAssertThrowsError(try GridPaddingValue.parse("abcpx"))
        XCTAssertThrowsError(try GridPaddingValue.parse(true as Any))
    }

    // resolve() is what actually reaches layout maths: relative values scale
    // with baseSpacing, absolute ones ignore it.
    func test_paddingValue_resolve() {
        let absolute = GridPaddingValue(pixels: 10)
        XCTAssertEqual(absolute.resolve(baseSpacing: 8), 10)
        XCTAssertEqual(absolute.resolve(baseSpacing: 99), 10)

        let relative = GridPaddingValue(baseMultiple: 2, isRelative: true)
        XCTAssertEqual(relative.resolve(baseSpacing: 8), 16)
        XCTAssertEqual(relative.resolve(baseSpacing: 12), 24)
    }

    // MARK: - GridPadding.isZero

    // Kills the eq->ne mutants on GridTypes.swift:191-194: under any of them a
    // genuinely zero padding reports non-zero.
    func test_isZero_trueForZeroPadding() {
        let zero = GridPadding(
            top: GridPaddingValue(),
            right: GridPaddingValue(),
            bottom: GridPaddingValue(),
            left: GridPaddingValue()
        )
        XCTAssertTrue(zero.isZero)
    }

    // Kills the and->or mutants on GridTypes.swift:191-194. `&&` binds tighter
    // than `||`, so flipping the conjunction on any line lets that line's first
    // clause short-circuit the whole expression to true. Each side is perturbed
    // independently so every line is covered.
    func test_isZero_falseWhenAnySideIsNonZero() {
        let pv = GridPaddingValue(pixels: 10)

        func padding(top: Bool = false, right: Bool = false,
                     bottom: Bool = false, left: Bool = false) -> GridPadding {
            GridPadding(
                top: top ? pv : GridPaddingValue(),
                right: right ? pv : GridPaddingValue(),
                bottom: bottom ? pv : GridPaddingValue(),
                left: left ? pv : GridPaddingValue()
            )
        }

        XCTAssertFalse(padding(top: true).isZero, "non-zero top must not read as zero")
        XCTAssertFalse(padding(right: true).isZero, "non-zero right must not read as zero")
        XCTAssertFalse(padding(bottom: true).isZero, "non-zero bottom must not read as zero")
        XCTAssertFalse(padding(left: true).isZero, "non-zero left must not read as zero")
    }

    // isZero must also account for the base-relative representation, where the
    // magnitude lives in baseMultiple/isRelative rather than pixels.
    func test_isZero_falseForRelativePadding() {
        let relative = GridPaddingValue(baseMultiple: 1, isRelative: true)
        let padding = GridPadding(
            top: relative,
            right: GridPaddingValue(),
            bottom: GridPaddingValue(),
            left: GridPaddingValue()
        )
        XCTAssertFalse(padding.isZero, "a 1x relative padding is not zero padding")
    }

    // MARK: - GridPadding.parse

    func test_padding_parse_scalarAppliesToAllSides() throws {
        let fromInt = try XCTUnwrap(try GridPadding.parse(8))
        XCTAssertEqual(fromInt.top, GridPaddingValue(pixels: 8))
        XCTAssertEqual(fromInt.right, GridPaddingValue(pixels: 8))
        XCTAssertEqual(fromInt.bottom, GridPaddingValue(pixels: 8))
        XCTAssertEqual(fromInt.left, GridPaddingValue(pixels: 8))

        let fromString = try XCTUnwrap(try GridPadding.parse("2x"))
        XCTAssertEqual(fromString.top, GridPaddingValue(baseMultiple: 2, isRelative: true))
        XCTAssertEqual(fromString.left, GridPaddingValue(baseMultiple: 2, isRelative: true))
    }

    func test_padding_parse_nilPassesThrough() throws {
        XCTAssertNil(try GridPadding.parse(nil))
    }

    // The 2-element form is [vertical, horizontal]; the 4-element form is
    // [top, right, bottom, left]. Getting these transposed silently shifts
    // every window in the layout.
    func test_padding_parse_arrayForms() throws {
        let two = try XCTUnwrap(try GridPadding.parse([10, 20]))
        XCTAssertEqual(two.top, GridPaddingValue(pixels: 10))
        XCTAssertEqual(two.bottom, GridPaddingValue(pixels: 10))
        XCTAssertEqual(two.right, GridPaddingValue(pixels: 20))
        XCTAssertEqual(two.left, GridPaddingValue(pixels: 20))

        let four = try XCTUnwrap(try GridPadding.parse([1, 2, 3, 4]))
        XCTAssertEqual(four.top, GridPaddingValue(pixels: 1))
        XCTAssertEqual(four.right, GridPaddingValue(pixels: 2))
        XCTAssertEqual(four.bottom, GridPaddingValue(pixels: 3))
        XCTAssertEqual(four.left, GridPaddingValue(pixels: 4))
    }

    func test_padding_parse_arrayWrongArity_throws() {
        XCTAssertThrowsError(try GridPadding.parse([1]))
        XCTAssertThrowsError(try GridPadding.parse([1, 2, 3]))
        XCTAssertThrowsError(try GridPadding.parse([Int]()))
    }

    // Unspecified keys stay at zero rather than inheriting another side.
    func test_padding_parse_dictionaryForm() throws {
        let partial = try XCTUnwrap(try GridPadding.parse(["top": 10, "left": "2x"]))
        XCTAssertEqual(partial.top, GridPaddingValue(pixels: 10))
        XCTAssertEqual(partial.left, GridPaddingValue(baseMultiple: 2, isRelative: true))
        XCTAssertEqual(partial.right, GridPaddingValue(), "unspecified side must stay zero")
        XCTAssertEqual(partial.bottom, GridPaddingValue(), "unspecified side must stay zero")
    }
}
