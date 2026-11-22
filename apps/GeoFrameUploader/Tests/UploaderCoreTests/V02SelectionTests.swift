import CoreGraphics
import Foundation
import XCTest
@testable import UploaderCore

final class V02SelectionTests: XCTestCase {
    private func makeItem(
        _ id: String,
        date: Date? = nil,
        lat: Double? = nil,
        lon: Double? = nil,
        acc: Double? = nil,
        w: Int = 4032,
        h: Int = 3024,
        burst: String? = nil,
        fav: Bool = false,
        uti: String = "public.heic",
        mod: Date? = nil
    ) -> PhotoItem {
        let loc = (lat != nil && lon != nil) ? PhotoLocation(lat: lat!, lon: lon!, horizontalAccuracy: acc) : nil
        return PhotoItem(
            localIdentifier: id,
            originalFilename: "\(id).HEIC",
            uti: uti,
            mediaKind: .image,
            creationDate: date,
            location: loc,
            pixelWidth: w,
            pixelHeight: h,
            burstIdentifier: burst,
            isFavorite: fav,
            modificationDate: mod
        )
    }

    // MARK: - PhotoSectioner

    func testSectionerTimeAndDistanceAndMissingGPS() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let a = makeItem("a", date: base, lat: 36.9000, lon: 139.1700)
        let b = makeItem("b", date: base.addingTimeInterval(300)) // GPS nil
        let c = makeItem("c", date: base.addingTimeInterval(600), lat: 36.9004, lon: 139.1700)
        let d = makeItem("d", date: base.addingTimeInterval(900), lat: 36.9055, lon: 139.1700)
        let e = makeItem("e", date: base.addingTimeInterval(3600), lat: 36.9056, lon: 139.1700)
        let f = makeItem("f", date: base.addingTimeInterval(6000)) // +40m after e, GPS nil, within 2h of e
        let undated = makeItem("z", date: nil)

        let sections = PhotoSectioner.section(items: [undated, f, d, a, c, b, e])
        XCTAssertEqual(sections.count, 5)
        XCTAssertEqual(sections[0].items.map(\.localIdentifier), ["a", "b", "c"])
        XCTAssertFalse(sections[0].isLocationBorrowed)
        XCTAssertEqual(sections[1].items.map(\.localIdentifier), ["d"])
        XCTAssertEqual(sections[2].items.map(\.localIdentifier), ["e"])
        XCTAssertEqual(sections[3].items.map(\.localIdentifier), ["f"])
        XCTAssertTrue(sections[3].isLocationBorrowed)
        XCTAssertEqual(sections[3].representativeLocation?.lat, e.location?.lat)
        XCTAssertNil(f.location, "元の PhotoItem の location は書き換えない")
        XCTAssertEqual(sections[4].id, "undated")
        XCTAssertEqual(sections[4].items.map(\.localIdentifier), ["z"])
    }

    func testSectionerAccuracyAndAntimeridian() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let a = makeItem("a", date: base, lat: 35.0, lon: 135.0, acc: 300)
        let b = makeItem("b", date: base.addingTimeInterval(60), lat: 35.0045, lon: 135.0, acc: 300)
        let secs = PhotoSectioner.section(items: [a, b], options: SectionOptions(distanceThresholdMeters: 300))
        XCTAssertEqual(secs.count, 1)

        let dCross = PhotoSectioner.haversineMeters(
            PhotoLocation(lat: 0, lon: 179.999),
            PhotoLocation(lat: 0, lon: -179.999)
        )
        XCTAssertNotNil(dCross)
        XCTAssertLessThan(dCross ?? .infinity, 300.0)
    }

    // MARK: - ImageQualityAnalyzer & QualityCache

    private func makeCheckerboardCGImage(width: Int = 64, height: Int = 64, block: Int = 4, inverted: Bool = false) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let isWhite = (((x / block) + (y / block)) % 2 == 0) != inverted
                pixels[y * width + x] = isWhite ? 230 : 25
            }
        }
        return makeGrayCGImage(pixels: pixels, width: width, height: height, space: space)
    }

    private func makeAsymmetricPatternCGImage(width: Int, height: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let leftDark = x < width / 2
                let topBright = y < height / 2
                pixels[y * width + x] = (leftDark ? 40 : 200) + (topBright ? 30 : 0)
            }
        }
        return makeGrayCGImage(pixels: pixels, width: width, height: height, space: space)
    }

    private func makeSolidCGImage(gray: UInt8, width: Int = 64, height: Int = 64) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        let pixels = [UInt8](repeating: gray, count: width * height)
        return makeGrayCGImage(pixels: pixels, width: width, height: height, space: space)
    }

    private func makeSoftGradientCGImage(size: Int = 64) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        var pixels = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                pixels[y * size + x] = UInt8(80 + (x * 90) / max(1, size - 1))
            }
        }
        return makeGrayCGImage(pixels: pixels, width: size, height: size, space: space)
    }

    private func makeGrayCGImage(pixels: [UInt8], width: Int, height: Int, space: CGColorSpace) -> CGImage {
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
    }

    func testImageQualityAnalyzerEdgeCasesAndPermissions() throws {
        let sharpImg = makeCheckerboardCGImage()
        let softImg = makeSoftGradientCGImage()
        let flatImg = makeSolidCGImage(gray: 128)
        let overImg = makeSolidCGImage(gray: 253)
        let portraitImg = makeAsymmetricPatternCGImage(width: 40, height: 120)
        let landscapeImg = makeAsymmetricPatternCGImage(width: 120, height: 40)
        let narrowImg = makeAsymmetricPatternCGImage(width: 2, height: 10)

        let mSharp = try XCTUnwrap(ImageQualityAnalyzer.analyze(sharpImg))
        let mSoft = try XCTUnwrap(ImageQualityAnalyzer.analyze(softImg))
        let mFlat = try XCTUnwrap(ImageQualityAnalyzer.analyze(flatImg))
        let mOver = try XCTUnwrap(ImageQualityAnalyzer.analyze(overImg))
        let mPortrait = try XCTUnwrap(ImageQualityAnalyzer.analyze(portraitImg))
        let mLandscape = try XCTUnwrap(ImageQualityAnalyzer.analyze(landscapeImg))
        let mNarrow = try XCTUnwrap(ImageQualityAnalyzer.analyze(narrowImg))

        XCTAssertTrue(mSharp.isValid)
        XCTAssertTrue(mPortrait.isValid)
        XCTAssertTrue(mLandscape.isValid)
        XCTAssertTrue(mNarrow.isValid)
        XCTAssertNotNil(mSharp.pHash)
        XCTAssertNotNil(mSoft.pHash)
        XCTAssertGreaterThan(mSharp.sharpness, mSoft.sharpness)

        // 既知ビットパターン検証（上下左右対比パターンと白黒反転でビットが大きく離れる）
        let patA = try XCTUnwrap(ImageQualityAnalyzer.analyze(makeAsymmetricPatternCGImage(width: 64, height: 64))?.pHash)
        let patAInv = try XCTUnwrap(ImageQualityAnalyzer.analyze(makeCheckerboardCGImage(width: 64, height: 64, block: 16, inverted: true))?.pHash)
        let patNormal = try XCTUnwrap(ImageQualityAnalyzer.analyze(makeCheckerboardCGImage(width: 64, height: 64, block: 16, inverted: false))?.pHash)
        XCTAssertNotEqual(patA, 0)
        XCTAssertGreaterThan((patAInv ^ patNormal).nonzeroBitCount, 20)

        // 単色画像は pHash = nil にして偽一致を防ぐ
        XCTAssertNil(mFlat.pHash)
        XCTAssertEqual(mFlat.sharpness, 0.0, accuracy: 1e-6)
        XCTAssertGreaterThan(mOver.whiteClip, 0.99)
        XCTAssertLessThan(mOver.exposureScore, mSharp.exposureScore)

        // NaN / Infinity の両方を拒否
        let nanMetrics = QualityMetrics(pHash: nil, sharpness: .nan, exposureScore: 50, contrast: 50,
                                        luminance: 128, blackClip: 0, whiteClip: 0)
        let infMetrics = QualityMetrics(pHash: nil, sharpness: 5, exposureScore: .infinity, contrast: 50,
                                        luminance: 128, blackClip: 0, whiteClip: 0)
        XCTAssertFalse(nanMetrics.isValid)
        XCTAssertFalse(infMetrics.isValid)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cacheURL = dir.appendingPathComponent("quality-cache.json")

        let mod1 = Date(timeIntervalSince1970: 1_700_000_000.100)
        let item1 = makeItem("img1", date: mod1, mod: mod1)
        let qc1 = QualityCache(fileURL: cacheURL)
        qc1.recordBatch([(item1, nanMetrics), (item1, infMetrics), (item1, mSharp)])

        // ファイル権限 0600 を確認
        let attrs = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let qc2 = QualityCache(fileURL: cacheURL)
        XCTAssertEqual(qc2.metrics(for: [item1])["img1"], mSharp)

        // 1 秒未満の編集（0.25秒差）でも確実にキャッシュ無効化されること
        let item1SubsecondEdited = makeItem("img1", date: mod1, mod: Date(timeIntervalSince1970: 1_700_000_000.350))
        XCTAssertNil(qc2.metrics(for: [item1SubsecondEdited])["img1"])
    }

    // MARK: - SimilarityGrouper & SelectionPlanner

    func testSimilarityGrouperUnsortedAndStandaloneFavoriteFloor() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let p1 = makeItem("p1", date: base, fav: false)
        let p2 = makeItem("p2", date: base.addingTimeInterval(10), fav: true)
        let p3 = makeItem("p3", date: base.addingTimeInterval(500), burst: "B1")
        let p4 = makeItem("p4", date: base.addingTimeInterval(501), burst: "B1")
        let p5 = makeItem("p5", date: base.addingTimeInterval(900))
        let p6 = makeItem("p6", date: base.addingTimeInterval(1000))
        // 単独のお気に入りでも強いぼけ（品質下限未満）なら自動推奨から外れる
        let p7 = makeItem("p7", date: base.addingTimeInterval(1100), fav: true)

        let goodMetrics = QualityMetrics(pHash: 0x0f0f0f0f0f0f0f0f, sharpness: 8.5, exposureScore: 85,
                                         contrast: 120, luminance: 128, blackClip: 0, whiteClip: 0)
        let weakMetrics = QualityMetrics(pHash: 0x0f0f0f0f0f0f0f0e, sharpness: 4.0, exposureScore: 60,
                                         contrast: 60, luminance: 128, blackClip: 0.05, whiteClip: 0.05)
        let blurMetrics = QualityMetrics(pHash: 0xffffffff00000000, sharpness: 1.2, exposureScore: 70,
                                         contrast: 60, luminance: 128, blackClip: 0, whiteClip: 0)

        let metrics: [String: QualityMetrics] = [
            "p1": goodMetrics,
            "p2": weakMetrics,
            "p3": weakMetrics,
            "p4": goodMetrics,
            "p5": goodMetrics,
            "p7": blurMetrics,
        ]

        // 逆順（未ソート）で渡しても内部ソートされて正しく束ねられる
        let unsorted = [p7, p6, p5, p4, p3, p2, p1]
        let grp = SimilarityGrouper.group(sectionId: "s1", sectionItems: unsorted, metricsById: metrics)
        XCTAssertEqual(grp.clusters.count, 2)
        XCTAssertEqual(grp.clusters[0].recommendedIds, ["p2"])
        XCTAssertEqual(grp.clusters[1].recommendedIds, ["p4"])
        XCTAssertEqual(grp.standaloneRecommendedIds, ["p5"]) // p6 未解析、p7 品質下限未満

        // 推奨 p4 が既に isDone なら 2 番手 p3 を繰り上げて選ばない
        let selected = SelectionPlanner.recommendedToSelect(items: unsorted, grouping: grp) { $0.localIdentifier == "p4" }
        XCTAssertEqual(selected, ["p2", "p5"])
    }

    func testInterleavedClusterDisplayOrderAndShiftRangeEdgeCases() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 時系列 [A, B, C] で A と C が類似束のとき、描画順は [A, C, B] になる
        let a = makeItem("A", date: base)
        let b = makeItem("B", date: base.addingTimeInterval(20))
        let c = makeItem("C", date: base.addingTimeInterval(40))
        let d = makeItem("D", date: base.addingTimeInterval(400))

        let hashAC: UInt64 = 0x1111_2222_3333_4444
        let hashB: UInt64 = 0xffff_0000_ffff_0000
        let hashD: UInt64 = 0x0000_ffff_0000_ffff

        let metrics: [String: QualityMetrics] = [
            "A": QualityMetrics(pHash: hashAC, sharpness: 8, exposureScore: 80, contrast: 80, luminance: 128, blackClip: 0, whiteClip: 0),
            "B": QualityMetrics(pHash: hashB, sharpness: 8, exposureScore: 80, contrast: 80, luminance: 128, blackClip: 0, whiteClip: 0),
            "C": QualityMetrics(pHash: hashAC ^ 0x1, sharpness: 7, exposureScore: 80, contrast: 80, luminance: 128, blackClip: 0, whiteClip: 0),
            "D": QualityMetrics(pHash: hashD, sharpness: 8, exposureScore: 80, contrast: 80, luminance: 128, blackClip: 0, whiteClip: 0),
        ]

        let items = [a, b, c, d]
        let grp = SimilarityGrouper.group(sectionId: "s1", sectionItems: items, metricsById: metrics)
        let chunks = SelectionPlanner.displayChunks(items: items, grouping: grp, bundleSimilar: true)
        let ordered = SelectionPlanner.orderedSelectableIds(from: chunks) { $0.eligibility.isEligible }
        XCTAssertEqual(ordered, ["A", "C", "B", "D"])

        // 描画順 [A, C, B, D] で A -> C を Shift 選択しても B は含まれない
        let afterShift = SelectionPlanner.shiftRange(
            orderedSelectableIds: ordered,
            anchorId: "A",
            targetId: "C",
            anchorTargetState: true,
            currentSelection: ["A"]
        )
        XCTAssertEqual(afterShift, ["A", "C"])

        // アンカーが非表示・折りたたみで見えなくなった場合は単一トグル
        let collapsedAnchorShift = SelectionPlanner.shiftRange(
            orderedSelectableIds: ["B", "D"],
            anchorId: "A",
            targetId: "D",
            anchorTargetState: true,
            currentSelection: []
        )
        XCTAssertEqual(collapsedAnchorShift, ["D"])

        // ターゲット自体が表示順リストに無ければ選択を変更しない
        let hiddenTargetShift = SelectionPlanner.shiftRange(
            orderedSelectableIds: ["B", "D"],
            anchorId: "B",
            targetId: "hidden",
            anchorTargetState: true,
            currentSelection: ["B"]
        )
        XCTAssertEqual(hiddenTargetShift, ["B"])
    }

    // MARK: - PlaceNameResolver（直列性・丸め座標送信・空キュー後間隔・キャンセル遅延応答）

    private actor ControllableGeocoder: GeocodingBackend {
        struct Call: Equatable {
            let lat: Double
            let lon: Double
        }

        private(set) var calls: [Call] = []
        private(set) var callTimes: [ContinuousClock.Instant] = []
        private(set) var maxConcurrent = 0
        private var currentConcurrent = 0
        private var gate: CheckedContinuation<Void, Never>?
        private var resultToReturn: GeocodingResult = .resolved("尾瀬ヶ原")
        private var waitForGate = false

        func setResult(_ r: GeocodingResult) { resultToReturn = r }
        func setWaitForGate(_ v: Bool) { waitForGate = v }

        func releaseGate() {
            gate?.resume()
            gate = nil
        }

        func reverseGeocode(lat: Double, lon: Double) async -> GeocodingResult {
            calls.append(Call(lat: lat, lon: lon))
            callTimes.append(.now)
            currentConcurrent += 1
            maxConcurrent = max(maxConcurrent, currentConcurrent)
            defer { currentConcurrent -= 1 }

            if waitForGate {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    gate = cont
                }
            }
            return resultToReturn
        }

        func cancel() async {
            gate?.resume()
            gate = nil
        }
    }

    func testPlaceNameResolverNormalizedCoordsSpacingAndLateCancellation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-ctrl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cacheURL = dir.appendingPathComponent("place-cache.json")

        let backend = ControllableGeocoder()
        let spacingNs: UInt64 = 50_000_000 // 50ms
        let resolver = PlaceNameResolver(fileURL: cacheURL, backend: backend, spacingNanoseconds: spacingNs)

        // 1. 生座標 (36.90349, 139.17349) ではなく丸め座標 (36.903, 139.173) が送られること
        let r1 = await resolver.resolveOutcome(location: PhotoLocation(lat: 36.90349, lon: 139.17349))
        XCTAssertEqual(r1, .resolved("尾瀬ヶ原"))

        // 2. 一度キューが空になった後の次のリクエストでも spacing が維持されること
        let r2 = await resolver.resolveOutcome(location: PhotoLocation(lat: 36.9101, lon: 139.1801))
        XCTAssertEqual(r2, .resolved("尾瀬ヶ原"))

        let calls = await backend.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].lat, 36.903, accuracy: 1e-6)
        XCTAssertEqual(calls[0].lon, 139.173, accuracy: 1e-6)
        let times = await backend.callTimes
        let gap = times[0].duration(to: times[1])
        XCTAssertGreaterThanOrEqual(gap, .milliseconds(45))

        // 3. キャンセル後にバックエンドが遅延応答してもキャッシュされないこと
        await backend.setWaitForGate(true)
        await backend.setResult(.resolved("遅れて返った地名"))
        let cancelTask = Task {
            await resolver.resolveOutcome(location: PhotoLocation(lat: 37.000, lon: 140.000))
        }
        try await Task.sleep(for: .milliseconds(70))
        await resolver.cancelAll()
        let cancelledOutcome = await cancelTask.value
        XCTAssertEqual(cancelledOutcome, .cancelled)

        // 遅延キャッシュ汚染がないこと + 新規リクエストが正常に直列実行されること
        let shouldBeNil = await resolver.cachedName(for: PhotoLocation(lat: 37.000, lon: 140.000))
        XCTAssertNil(shouldBeNil)

        await backend.setWaitForGate(false)
        await backend.setResult(.resolved("正しい新地名"))
        let r3 = await resolver.resolveOutcome(location: PhotoLocation(lat: 37.000, lon: 140.000))
        XCTAssertEqual(r3, .resolved("正しい新地名"))

        let maxC = await backend.maxConcurrent
        XCTAssertEqual(maxC, 1)

        // 4. place-cache.json の 0600 権限確認
        await resolver.cancelAll()
        let attrs = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
