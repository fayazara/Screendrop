//
//  ScrollingCaptureStitcher.swift
//  Screendrop
//

import CoreGraphics
import Foundation

/// Stitches the frames of a scrolling capture into one tall image.
///
/// Every frame is the same screen region, captured while the user scrolls.
/// A new frame is lined up against the last accepted one by hashing its pixel
/// rows: the scroll distance is the row offset at which most rows match, and
/// only the rows that scrolled into view are kept. Rows that stay put between
/// frames - a sticky header or footer - are found on the first scroll and left
/// out of the matching, so a sticky footer isn't repeated after every scroll.
///
/// Works on exact pixel matches. Content that re-renders while it scrolls
/// (animations, video) costs matching rows, but the 70% bar tolerates some.
actor ScrollingCaptureStitcher {
    enum Update: Sendable {
        /// Lined up, but nothing new: the content hasn't moved, or moved back
        /// up while still overlapping the last accepted frame.
        case unchanged
        /// New rows scrolled into view and were added.
        case appended
        /// The frame couldn't be lined up, or would leave a gap: scrolled too
        /// far between frames, the content repeats too evenly to tell how far
        /// it moved, or it changed in place.
        case noMatch
    }

    /// Fewer distinct matching rows than this is treated as a coincidence.
    private static let minimumMatchedRows = 8
    /// Rows are matched as side-by-side strips, so a narrow column that
    /// changes between frames - an editor's gutter separator, a hover
    /// highlight - costs one strip of each row rather than the whole row.
    private static let stripsPerRow = 8
    /// Half-width strips for a second try, isolating small spots that redraw
    /// a little differently every frame, like Finder's icons. Not the first
    /// try: narrower strips hold less, so dense data repeats too often in
    /// them to place.
    private static let fineStripsPerRow = 16
    /// A strip found more often than this in a frame (the plain edge of a
    /// card on every row) says nothing about position, so it doesn't vote.
    private static let maximumStripRepeats = 32
    /// Chrome lines are narrow: a separator or window edge is a couple of
    /// pixels. A wider run of line-like columns is two-tone content - a dense
    /// grid, say - and holds the very positions matching needs.
    private static let maximumChromeWidth = 6
    /// The bottom quarter of the band is held back rather than appended, so a
    /// floating button or chat bubble that sits there - covering the content
    /// scrolling under it - isn't copied into every slice. That content is
    /// taken from higher up the frame once it has scrolled clear, and the held
    /// rows are added once, from the last frame, at the end.
    private static let heldBackFraction = 4
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
        | CGBitmapInfo.byteOrder32Little.rawValue

    private let width: Int
    private let height: Int
    private let colorSpace: CGColorSpace
    /// Leading columns that go into row hashes. The trailing ones are left
    /// out so the overlay scroll bar that appears while scrolling doesn't
    /// break otherwise identical rows.
    private let hashedWidth: Int
    private let first: [UInt8]
    private var last: [UInt8]
    private var lastColumns: ColumnProfile
    private var appended: [UInt8] = []
    /// Unmoving rows at the top and bottom, fixed on the first scroll.
    private var fixedEdges: (top: Int, bottom: Int)?

    /// Height of the stitched image so far, in pixels.
    private(set) var stitchedHeight: Int

    init?(firstFrame: CGImage, ignoredTrailingColumns: Int) {
        let width = firstFrame.width
        let height = firstFrame.height
        let colorSpace = firstFrame.colorSpace.flatMap { space in
            space.model == .rgb && space.supportsOutput ? space : nil
        } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard width > 0, height > 0,
              let pixels = Self.pixels(of: firstFrame, colorSpace: colorSpace) else {
            return nil
        }

        self.width = width
        self.height = height
        self.colorSpace = colorSpace
        hashedWidth = max(1, width - min(max(ignoredTrailingColumns, 0), width / 4))
        first = pixels
        last = pixels
        lastColumns = Self.columnProfile(of: pixels, width: width, height: height, hashedWidth: hashedWidth)
        stitchedHeight = height
    }

    func add(_ frame: CGImage) -> Update {
        guard frame.width == width, frame.height == height,
              let pixels = Self.pixels(of: frame, colorSpace: colorSpace) else {
            return .noMatch
        }
        let isIdentical = pixels.withUnsafeBytes { new in
            last.withUnsafeBytes { old in memcmp(new.baseAddress!, old.baseAddress!, new.count) == 0 }
        }
        if isIdentical {
            return .unchanged
        }

        // Columns drawn as lines rather than content - one color, or a dotted
        // two-tone pattern, nearly all the way down - in both frames are
        // chrome, unless they're the same solid color in each (those match
        // anyway). A gutter separator or window edge that flips as the view
        // redraws would otherwise make every row differ while the content
        // lines up exactly, so the frames are first lined up without chrome.
        // Chrome is only ever left out of matching, never out of the image.
        let columns = Self.columnProfile(of: pixels, width: width, height: height, hashedWidth: hashedWidth)
        var isChrome = (0..<hashedWidth).map { x in
            let wasLine = lastColumns.solidColor[x] != nil || lastColumns.isTwoTone[x]
            let isLine = columns.solidColor[x] != nil || columns.isTwoTone[x]
            let isSameSolid = lastColumns.solidColor[x] != nil && lastColumns.solidColor[x] == columns.solidColor[x]
            return wasLine && isLine && !isSameSolid
        }
        var runStart = 0
        for x in 0...hashedWidth where x == hashedWidth || !isChrome[x] {
            if x - runStart > Self.maximumChromeWidth {
                for wide in runStart..<x {
                    isChrome[wide] = false
                }
            }
            runStart = x + 1
        }

        // When the frames don't line up that way, they're tried again before
        // giving up, under the same rules, so a later try is no easier to
        // fool: with every column, since looking like a line doesn't prove a
        // column is chrome (a dense grid of thin data cells looks the same),
        // then in half-width strips.
        var attempts = [(skipping: isChrome, strips: Self.stripsPerRow)]
        if isChrome.contains(true) {
            attempts.append(([Bool](repeating: false, count: hashedWidth), Self.stripsPerRow))
        }
        attempts.append((isChrome, Self.fineStripsPerRow))
        var match = LineUp.unmatched
        for (index, attempt) in attempts.enumerated() {
            let result = lineUp(pixels, skipping: attempt.skipping, stripsPerRow: attempt.strips)
            if index == 0 {
                match = result
            }
            if case .shifted = result {
                match = result
                break
            }
        }
        let edges: (top: Int, bottom: Int)
        let shift: Int
        switch match {
        case .identical:
            return .unchanged
        case .unmatched:
            return .noMatch
        case .shifted(let lineUpEdges, let lineUpShift):
            edges = lineUpEdges
            shift = lineUpShift
        }
        let band = edges.top..<(height - edges.bottom)
        // Still in place (a caret blinked), or scrolled back up but still
        // overlapping: nothing new below the last accepted frame yet.
        guard shift > 0 else { return .unchanged }

        // The rows that just scrolled up past the cut. Everything above them
        // was already appended from earlier frames. A scroll past the whole
        // band above the cut leaves a gap only the held-back rows of the last
        // frame could fill - where an overlay may have covered them - so it's
        // treated like any other lost frame: scrolling back picks it up again.
        let cut = Self.cut(in: band)
        let start = cut - shift
        guard start >= band.lowerBound else { return .noMatch }
        let bytesPerRow = width * 4
        fixedEdges = edges
        appended.append(contentsOf: pixels[(start * bytesPerRow)..<(cut * bytesPerRow)])
        last = pixels
        lastColumns = columns
        stitchedHeight += shift
        return .appended
    }

    /// The first frame down to the cut, every row appended since, then the
    /// held-back rows and the footer as they look in the last accepted frame.
    func makeImage() -> CGImage? {
        let bytesPerRow = width * 4
        let cutStart = (fixedEdges.map { Self.cut(in: $0.top..<(height - $0.bottom)) } ?? height) * bytesPerRow
        var data = Data(capacity: stitchedHeight * bytesPerRow)
        data.append(contentsOf: first[0..<cutStart])
        data.append(contentsOf: appended)
        data.append(contentsOf: last[cutStart...])

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: stitchedHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: Self.bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// The row the band is appended up to; the rows below it are held back.
    private static func cut(in band: Range<Int>) -> Int {
        band.upperBound - band.count / heldBackFraction
    }

    // MARK: - Matching

    private enum LineUp {
        /// The matched columns are the same in both frames.
        case identical
        case shifted(edges: (top: Int, bottom: Int), by: Int)
        case unmatched
    }

    private func lineUp(_ pixels: [UInt8], skipping isSkipped: [Bool], stripsPerRow: Int) -> LineUp {
        let strips = Self.stripColumns(hashedWidth: hashedWidth, skipping: isSkipped, count: stripsPerRow)
        let lastRows = Self.rows(of: last, width: width, height: height, strips: strips)
        let rows = Self.rows(of: pixels, width: width, height: height, strips: strips)
        guard rows != lastRows else { return .identical }
        let edges = fixedEdges ?? unmovedEdges(from: lastRows, to: rows)
        let band = edges.top..<(height - edges.bottom)
        guard band.count > Self.minimumMatchedRows,
              let shift = bestShift(from: lastRows, to: rows, in: band) else {
            return .unmatched
        }
        return .shifted(edges: edges, by: shift)
    }

    private struct Strip: Hashable {
        /// Includes the strip's position in the row, so equal pixels in
        /// different columns never match. A blank strip keeps its color here.
        let hash: Int
        /// A single solid color. Blank strips match each other anywhere, so
        /// they say nothing about how far the content moved.
        let isBlank: Bool
    }

    private struct Row: Hashable {
        let strips: [Strip]
    }

    /// Runs of rows at the top and bottom that are identical in both frames.
    /// Capped at a third of the frame each, so a mostly blank page can't
    /// shrink the band that scrolling is matched in. Overcounting is harmless:
    /// the content passing through those rows is still kept, just later.
    private func unmovedEdges(from old: [Row], to new: [Row]) -> (top: Int, bottom: Int) {
        let limit = height / 3
        var top = 0
        while top < limit, old[top] == new[top] {
            top += 1
        }
        var bottom = 0
        while bottom < limit, old[height - 1 - bottom] == new[height - 1 - bottom] {
            bottom += 1
        }
        return (top, bottom)
    }

    /// How far the content moved up - zero when it didn't move, negative when
    /// it moved down - from votes: every strip of the new frame votes for
    /// each offset at which the old frame has the same strip in the same
    /// column.
    ///
    /// Evidence is counted in distinct rows. A run of identical rows (the
    /// plain middle of a card) votes for every offset it overlaps, but says
    /// no more than one row would, so an offset needs enough different rows
    /// behind it to be plausible, and at least 70% of the strips it compares
    /// must agree. The best one wins unless a plausible rival is contradicted
    /// by about as few strips. Evenly repeating content (an empty grid) lines
    /// up at every period with nothing contradicting any of them, so it is
    /// reported as no match rather than guessed - a wrong guess would stitch
    /// the wrong rows without any sign of it.
    ///
    /// ponytail: a repeat with fewer than `minimumMatchedRows` rows of
    /// overlap left (a period nearly the region's height) is too little to
    /// tell from coincidence, and isn't caught.
    private func bestShift(from old: [Row], to new: [Row], in band: Range<Int>) -> Int? {
        var oldPositions: [Int: [Int]] = [:]
        for y in band {
            for strip in old[y].strips where !strip.isBlank {
                oldPositions[strip.hash, default: []].append(y)
            }
        }
        var newRepeats: [Int: Int] = [:]
        for y in band {
            for strip in new[y].strips where !strip.isBlank {
                newRepeats[strip.hash, default: 0] += 1
            }
        }
        func isEvidence(_ strip: Strip) -> Bool {
            !strip.isBlank && newRepeats[strip.hash, default: 0] <= Self.maximumStripRepeats
        }

        // Grouped by whole-row content, so identical rows count as one
        // distinct piece of evidence however many strips they match on.
        var rowsByContent: [Row: [Int]] = [:]
        for y in band {
            rowsByContent[new[y], default: []].append(y)
        }

        // Offsets run from -maxShift to maxShift, stored from index 0.
        let maxShift = band.count - 1
        var votes = [Int](repeating: 0, count: maxShift * 2 + 1)
        var distinctVotes = votes
        var lastVotingContent = [Int](repeating: -1, count: votes.count)
        for (contentIndex, (row, ys)) in rowsByContent.enumerated() {
            for strip in row.strips where isEvidence(strip) {
                guard let oldYs = oldPositions[strip.hash] else { continue }
                for y in ys {
                    for oldY in oldYs {
                        let index = oldY - y + maxShift
                        votes[index] += 1
                        if lastVotingContent[index] != contentIndex {
                            lastVotingContent[index] = contentIndex
                            distinctVotes[index] += 1
                        }
                    }
                }
            }
        }

        // comparedStrips[k]: voting strips among the first k rows of the
        // band. Offset s compares the band's first `band.count - s` rows when
        // positive, and all but its first `-s` when negative.
        var comparedStrips = [0]
        comparedStrips.reserveCapacity(band.count + 1)
        for y in band {
            comparedStrips.append(comparedStrips[comparedStrips.count - 1] + new[y].strips.count(where: isEvidence))
        }

        // Plausible offsets, with how many compared strips contradict each.
        var plausible: [(shift: Int, votes: Int, misses: Int)] = []
        for shift in -maxShift...maxShift {
            let index = shift + maxShift
            let compared = shift >= 0
                ? comparedStrips[band.count - shift]
                : comparedStrips[band.count] - comparedStrips[-shift]
            guard distinctVotes[index] >= Self.minimumMatchedRows,
                  votes[index] * 10 >= compared * 7 else { continue }
            plausible.append((shift, votes[index], compared - votes[index]))
        }
        // Strips contradicting an offset count heavily against it: on flat
        // UI, a near miss gathers almost as many votes as the real offset,
        // and only its contradicted strips tell them apart.
        func score(_ offset: (shift: Int, votes: Int, misses: Int)) -> Int {
            offset.votes - 4 * offset.misses
        }
        guard let best = plausible.max(by: { score($0) < score($1) }) else { return nil }

        let isAmbiguous = plausible.contains { other in
            other.shift != best.shift && other.misses < best.misses + Self.minimumMatchedRows
        }
        return isAmbiguous ? nil : best.shift
    }

    // MARK: - Pixels

    /// Redraws the frame as tightly packed BGRA in the stitch's color space,
    /// so rows can be hashed and copied byte for byte.
    private static func pixels(of image: CGImage, colorSpace: CGColorSpace) -> [UInt8]? {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return didDraw ? pixels : nil
    }

    /// Per column, from 32 rows spread down the frame: a column of chrome
    /// looks the same at nearly every height, so a sample finds it, and a full
    /// pass would cost every frame a few hundred ms in Debug.
    private struct ColumnProfile {
        /// The column's color when one color fills 29 of the 32 rows.
        let solidColor: [UInt32?]
        /// Two colors fill 29 of the 32 rows, each at least a quarter of
        /// them: a dotted or striped line. Sparse text doesn't qualify - it's
        /// nearly all background.
        let isTwoTone: [Bool]
    }

    private static func columnProfile(of pixels: [UInt8], width: Int, height: Int, hashedWidth: Int) -> ColumnProfile {
        let sampleCount = min(32, height)
        let samples = (0..<sampleCount).map { $0 * (height - 1) / max(1, sampleCount - 1) }
        let needed = sampleCount * 29 / 32
        let quarter = max(1, sampleCount / 4)
        // Two colors filling `needed` samples leave room for only a few
        // others, so a column with more distinct colors is content.
        let maximumColors = sampleCount - needed + 2
        var solidColor = [UInt32?](repeating: nil, count: hashedWidth)
        var isTwoTone = [Bool](repeating: false, count: hashedWidth)
        var colors: [UInt32] = []
        var counts: [Int] = []
        colors.reserveCapacity(maximumColors + 1)
        counts.reserveCapacity(maximumColors + 1)
        pixels.withUnsafeBytes { bytes in
            bytes.withMemoryRebound(to: UInt32.self) { words in
                for x in 0..<hashedWidth {
                    colors.removeAll(keepingCapacity: true)
                    counts.removeAll(keepingCapacity: true)
                    for y in samples {
                        let pixel = words[y * width + x]
                        if let index = colors.firstIndex(of: pixel) {
                            counts[index] += 1
                        } else {
                            colors.append(pixel)
                            counts.append(1)
                            if colors.count > maximumColors { break }
                        }
                    }
                    guard colors.count <= maximumColors else { continue }
                    // The two most frequent colors, whatever order the samples
                    // met them in, so a stray pixel can't take a line's place.
                    var top = 0
                    for index in counts.indices where counts[index] > counts[top] {
                        top = index
                    }
                    var second: Int?
                    for index in counts.indices where index != top && counts[index] > (second.map { counts[$0] } ?? 0) {
                        second = index
                    }
                    let secondCount = second.map { counts[$0] } ?? 0
                    if counts[top] >= needed {
                        solidColor[x] = colors[top]
                    } else {
                        isTwoTone[x] = counts[top] >= quarter && secondCount >= quarter
                            && counts[top] + secondCount >= needed
                    }
                }
            }
        }
        return ColumnProfile(solidColor: solidColor, isTwoTone: isTwoTone)
    }

    /// The matched columns in order, split into `count` side-by-side strips,
    /// each kept as runs of adjacent columns so it hashes in spans.
    private static func stripColumns(hashedWidth: Int, skipping isChrome: [Bool], count: Int) -> [[Range<Int>]] {
        let columns = (0..<hashedWidth).filter { !isChrome[$0] }
        return (0..<count).map { index in
            var runs: [Range<Int>] = []
            for x in columns[(index * columns.count / count)..<((index + 1) * columns.count / count)] {
                if let run = runs.last, run.upperBound == x {
                    runs[runs.count - 1] = run.lowerBound..<(x + 1)
                } else {
                    runs.append(x..<(x + 1))
                }
            }
            return runs
        }
    }

    private static func rows(of pixels: [UInt8], width: Int, height: Int, strips: [[Range<Int>]]) -> [Row] {
        pixels.withUnsafeBytes { buffer in
            (0..<height).map { y in
                let rowStart = y * width * 4
                return Row(strips: strips.enumerated().map { index, runs in
                    var hasher = Hasher()
                    hasher.combine(index)
                    var firstPixel: UInt32?
                    var isBlank = true
                    for run in runs {
                        let span = UnsafeRawBufferPointer(rebasing: buffer[(rowStart + run.lowerBound * 4)..<(rowStart + run.upperBound * 4)])
                        let pixel = span.loadUnaligned(as: UInt32.self)
                        // Every pixel equals its right-hand neighbour exactly
                        // when the span equals itself shifted by one pixel.
                        if isBlank, pixel != (firstPixel ?? pixel)
                            || memcmp(span.baseAddress!, span.baseAddress! + 4, span.count - 4) != 0 {
                            isBlank = false
                        }
                        firstPixel = firstPixel ?? pixel
                        hasher.combine(bytes: span)
                    }
                    guard isBlank else { return Strip(hash: hasher.finalize(), isBlank: false) }
                    var blankHasher = Hasher()
                    blankHasher.combine(index)
                    blankHasher.combine(firstPixel ?? 0)
                    return Strip(hash: blankHasher.finalize(), isBlank: true)
                })
            }
        }
    }
}
