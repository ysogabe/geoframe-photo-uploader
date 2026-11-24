import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest
@testable import UploaderCore

private final class GPSFakeExporter: OriginalExporting, @unchecked Sendable {
    let dir: URL
    let payloads: [String: (data: Data, exifGPS: PhotoLocation?)]

    init(dir: URL, payloads: [String: (data: Data, exifGPS: PhotoLocation?)]) {
        self.dir = dir
        self.payloads = payloads
    }

    func export(localIdentifier: String) async throws -> ExportedOriginal {
        guard let p = payloads[localIdentifier] else { throw ExportError.assetNotFound(localIdentifier) }
        let u = dir.appendingPathComponent(UUID().uuidString)
        try p.data.write(to: u)
        let h = try OriginalExporter.hashFile(at: u)
        return ExportedOriginal(
            fileURL: u,
            byteCount: h.bytes,
            md5Hex: h.md5,
            sha256Hex: h.sha256,
            dataSource: .local,
            exif: ExifDates(dateTimeOriginal: "2026:11:24 10:00:00", offsetTimeOriginal: "+09:00"),
            exifGPS: p.exifGPS
        )
    }
}

final class LocationSupplementTests: XCTestCase {
    var dir: URL!

    override func setUp() { dir = makeTempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func item(
        _ id: String,
        date: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        location: PhotoLocation? = nil,
        uti: String = "public.heic",
        name: String? = nil
    ) -> PhotoItem {
        PhotoItem(
            localIdentifier: id,
            originalFilename: name ?? "\(id).HEIC",
            uti: uti,
            mediaKind: .image,
            creationDate: date,
            location: location
        )
    }

    private func writeTestImage(uti: String, ext: String, gps: [CFString: Any]?, exif: [CFString: Any]? = nil) throws -> URL {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 16 * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(red: 0.25, green: 0.55, blue: 0.85, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let cgImg = ctx.makeImage()!

        let url = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil))
        var props: [CFString: Any] = [:]
        if let gps { props[kCGImagePropertyGPSDictionary] = gps }
        if let exif { props[kCGImagePropertyExifDictionary] = exif }
        CGImageDestinationAddImage(dest, cgImg, props.isEmpty ? nil : (props as CFDictionary))
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    // MARK: - OriginalExporter EXIF GPS

    func testReadExifMetadataReadsGPSAndDatesAcrossFormats() throws {
        let jpgNE = try writeTestImage(
            uti: "public.jpeg",
            ext: "jpg",
            gps: [
                kCGImagePropertyGPSLatitude: 35.681236,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 139.767125,
                kCGImagePropertyGPSLongitudeRef: "E",
                kCGImagePropertyGPSAltitude: 42.5,
                kCGImagePropertyGPSAltitudeRef: 0,
            ],
            exif: [
                kCGImagePropertyExifDateTimeOriginal: "2026:11:24 12:34:56",
                kCGImagePropertyExifOffsetTimeOriginal: "+09:00",
            ]
        )
        let metaNE = OriginalExporter.readExifMetadata(url: jpgNE)
        XCTAssertEqual(metaNE.dates, ExifDates(dateTimeOriginal: "2026:11:24 12:34:56", offsetTimeOriginal: "+09:00"))
        let gpsNE = try XCTUnwrap(metaNE.gps)
        XCTAssertEqual(gpsNE.lat, 35.681236, accuracy: 1e-4)
        XCTAssertEqual(gpsNE.lon, 139.767125, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(gpsNE.altitude), 42.5, accuracy: 1e-2)

        let pngSW = try writeTestImage(
            uti: "public.png",
            ext: "png",
            gps: [
                kCGImagePropertyGPSLatitude: 33.86882,
                kCGImagePropertyGPSLatitudeRef: "S",
                kCGImagePropertyGPSLongitude: 151.20929,
                kCGImagePropertyGPSLongitudeRef: "W",
                kCGImagePropertyGPSAltitude: 12.0,
                kCGImagePropertyGPSAltitudeRef: 1,
            ]
        )
        let gpsSW = try XCTUnwrap(OriginalExporter.readExifGPS(url: pngSW))
        XCTAssertEqual(gpsSW.lat, -33.86882, accuracy: 1e-4)
        XCTAssertEqual(gpsSW.lon, -151.20929, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(gpsSW.altitude), -12.0, accuracy: 1e-2)

        let jpgNoGPS = try writeTestImage(
            uti: "public.jpeg",
            ext: "jpg",
            gps: nil,
            exif: [kCGImagePropertyExifDateTimeOriginal: "2026:11:24 12:00:00"]
        )
        let metaNoGPS = OriginalExporter.readExifMetadata(url: jpgNoGPS)
        XCTAssertEqual(metaNoGPS.dates?.dateTimeOriginal, "2026:11:24 12:00:00")
        XCTAssertNil(metaNoGPS.gps)
    }

    // MARK: - DriveLocationProperties & Coordinate Parsing

    func testResolveForUploadNeverOverwritesExistingLocations() throws {
        let ov = LocationOverrideEntry(
            lat: 35.0, lon: 135.0, source: .uploaderManual,
            originalFilename: "A.HEIC", uti: "public.heic"
        )
        let assetLoc = PhotoLocation(lat: 36.0, lon: 136.0)
        let exifGPS = PhotoLocation(lat: 37.0, lon: 137.0)

        // 1. 原本 EXIF に GPS がある場合は常に nil（既存位置を上書きしない）
        let withAssetAndExif = item("A", location: assetLoc)
        XCTAssertNil(DriveLocationProperties.resolveForUpload(item: withAssetAndExif, exifGPS: exifGPS, override: ov))

        // 2. 原本 EXIF に GPS が無く PHAsset.location がある場合は photos_asset（override より優先）
        let rAsset = DriveLocationProperties.resolveForUpload(item: withAssetAndExif, exifGPS: nil, override: ov)
        XCTAssertEqual(rAsset, ResolvedUploadLocation(location: assetLoc, source: .photosAsset))

        // 3. 両方無い場合のみ override を使う
        let noLoc = item("A", location: nil)
        let rOv = DriveLocationProperties.resolveForUpload(item: noLoc, exifGPS: nil, override: ov)
        XCTAssertEqual(rOv, ResolvedUploadLocation(location: PhotoLocation(lat: 35.0, lon: 135.0), source: .uploaderManual))

        // 4. ファイル名または UTI が不一致の override は使わない
        let renamed = item("A", location: nil, name: "OTHER.HEIC")
        XCTAssertNil(DriveLocationProperties.resolveForUpload(item: renamed, exifGPS: nil, override: ov))

        // 5. 不正座標（NaN / 範囲外）は拒否される
        XCTAssertNil(DriveLocationProperties.makeProperties(for: ResolvedUploadLocation(
            location: PhotoLocation(lat: 91.0, lon: 139.0), source: .uploaderManual
        )))
        XCTAssertNil(DriveLocationProperties.makeProperties(for: ResolvedUploadLocation(
            location: PhotoLocation(lat: .nan, lon: 139.0), source: .uploaderManual
        )))

        // 6. フォーマット・-0.000000 正規化・Drive properties 124B 制限内
        XCTAssertEqual(DriveLocationProperties.formatCoordinate(-0.0000001), "0.000000")
        let props = try XCTUnwrap(DriveLocationProperties.makeProperties(for: ResolvedUploadLocation(
            location: PhotoLocation(lat: -89.1234567, lon: -179.9876543), source: .uploaderBorrowed
        )))
        XCTAssertEqual(props["geoframe.lat"], "-89.123457")
        XCTAssertEqual(props["geoframe.lon"], "-179.987654")
        XCTAssertEqual(props["geoframe.loc_source"], "uploader_borrowed")
        for (k, v) in props {
            XCTAssertLessThanOrEqual(k.utf8.count + v.utf8.count, 124)
        }
    }

    func testParseCoordinateStringVariants() throws {
        let p1 = try XCTUnwrap(DriveLocationProperties.parseCoordinateString("35.681236, 139.767125"))
        XCTAssertEqual(p1.lat, 35.681236, accuracy: 1e-6)
        XCTAssertEqual(p1.lon, 139.767125, accuracy: 1e-6)

        let p2 = try XCTUnwrap(DriveLocationProperties.parseCoordinateString("35.681236 139.767125"))
        XCTAssertEqual(p2, p1)

        let p3 = try XCTUnwrap(DriveLocationProperties.parseCoordinateString("(-33.8688, 151.2093)"))
        XCTAssertEqual(p3.lat, -33.8688, accuracy: 1e-6)
        XCTAssertEqual(p3.lon, 151.2093, accuracy: 1e-6)

        let p4 = try XCTUnwrap(DriveLocationProperties.parseCoordinateString("３５．６８１２３６，　−１３９．７６７１２５"))
        XCTAssertEqual(p4.lat, 35.681236, accuracy: 1e-6)
        XCTAssertEqual(p4.lon, -139.767125, accuracy: 1e-6)

        let p5 = try XCTUnwrap(DriveLocationProperties.parseCoordinateString("35.681236、139.767125"))
        XCTAssertEqual(p5, p1)

        let p6 = try XCTUnwrap(DriveLocationProperties.parseCoordinateString("https://www.google.com/maps/@35.681236,139.767125,15z"))
        XCTAssertEqual(p6, p1)

        XCTAssertNil(DriveLocationProperties.parseCoordinateString("91.0, 139.0"))
        XCTAssertNil(DriveLocationProperties.parseCoordinateString("35.0, 181.0"))
        XCTAssertNil(DriveLocationProperties.parseCoordinateString("35.0, 139.0, 10.0"))
        XCTAssertNil(DriveLocationProperties.parseCoordinateString("東京駅"))
    }

    // MARK: - LocationOverrideStore

    func testLocationOverrideStorePersistenceNonOverwriteAndTombstones() throws {
        let url = dir.appendingPathComponent("location-overrides.json")
        let t1 = Date(timeIntervalSince1970: 1_700_000_100)
        let t2 = Date(timeIntervalSince1970: 1_700_000_200)
        let t3 = Date(timeIntervalSince1970: 1_700_000_300)

        let existingLoc = PhotoLocation(lat: 34.0, lon: 134.0)
        let missingA = item("A", location: nil)
        let hasLocB = item("B", location: existingLoc)
        let missingC = item("C", location: nil)

        let store1 = LocationOverrideStore(fileURL: url)
        let saved = store1.set(
            items: [missingA, hasLocB, missingC],
            location: PhotoLocation(lat: 35.5, lon: 139.5),
            source: .uploaderManual,
            placeName: "東京都渋谷区",
            at: t1
        )
        XCTAssertEqual(saved, 2)
        XCTAssertNil(store1.entry(for: hasLocB))
        XCTAssertEqual(store1.entry(for: missingA)?.placeName, "東京都渋谷区")

        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)

        // 別インスタンスで再読み込み & 既存位置が後から付いた場合は entry(for:) が nil を返す
        let store2 = LocationOverrideStore(fileURL: url)
        XCTAssertEqual(store2.entries(for: [missingA, hasLocB, missingC]).count, 2)
        let aNowHasLoc = item("A", location: existingLoc)
        XCTAssertNil(store2.entry(for: aNowHasLoc))

        // クロスプロセス: store2 が C を削除したあと store1 が refresh/set しても C は復活しない
        store2.remove(localIdentifiers: ["C"], at: t2)
        store1.refresh()
        XCTAssertNil(store1.entry(for: missingC))
        XCTAssertEqual(store1.entry(for: missingA)?.lat, 35.5)

        // より新しい時刻で再設定すれば復活する
        XCTAssertEqual(store1.set(items: [missingC], location: PhotoLocation(lat: 36.1, lon: 140.1), source: .uploaderBorrowed, at: t3), 1)
        store2.refresh()
        XCTAssertEqual(store2.entry(for: missingC)?.lat, 36.1)
    }

    // MARK: - DriveClient properties & UploadCoordinator / RecordStore

    func testDriveClientIncludesPropertiesOnlyWhenProvided() async throws {
        let data = Data("hello-image".utf8)
        let fileURL = dir.appendingPathComponent("img.jpg")
        try data.write(to: fileURL)
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()

        let fake = FakeDrive(files: [])
        StubProtocol.setHandler(fake.handle)
        let drive = DriveClient(session: StubProtocol.session(), tokens: FakeTokens(), sleeper: noSleep)

        _ = try await drive.uploadResumable(
            fileURL: fileURL, name: "WITH.JPG", mimeType: "image/jpeg", folderId: "FOLDER",
            byteCount: Int64(data.count), expectedMD5: md5,
            properties: ["geoframe.lat": "35.681236", "geoframe.lon": "139.767125", "geoframe.loc_source": "photos_asset"]
        )
        let postWith = try XCTUnwrap(StubProtocol.recorded.first { $0.method == "POST" })
        let metaWith = try XCTUnwrap(try JSONSerialization.jsonObject(with: postWith.body) as? [String: Any])
        let props = try XCTUnwrap(metaWith["properties"] as? [String: String])
        XCTAssertEqual(props["geoframe.lat"], "35.681236")
        XCTAssertEqual(props["geoframe.lon"], "139.767125")
        XCTAssertEqual(props["geoframe.loc_source"], "photos_asset")

        StubProtocol.setHandler(fake.handle)
        _ = try await drive.uploadResumable(
            fileURL: fileURL, name: "WITHOUT.JPG", mimeType: "image/jpeg", folderId: "FOLDER",
            byteCount: Int64(data.count), expectedMD5: md5, properties: nil
        )
        let postWithout = try XCTUnwrap(StubProtocol.recorded.first { $0.method == "POST" })
        let metaWithout = try XCTUnwrap(try JSONSerialization.jsonObject(with: postWithout.body) as? [String: Any])
        XCTAssertNil(metaWithout["properties"])
    }

    func testCoordinatorAndRecordStoreEndToEndLocationProperties() async throws {
        let overridesURL = dir.appendingPathComponent("location-overrides.json")
        let recordsURL = dir.appendingPathComponent("records.jsonl")
        let overrideStore = LocationOverrideStore(fileURL: overridesURL)
        let records = RecordStore(fileURL: recordsURL)

        let pExif = item("P_EXIF", location: PhotoLocation(lat: 35.0, lon: 135.0), uti: "public.jpeg", name: "P_EXIF.JPG")
        let pAsset = item("P_ASSET", location: PhotoLocation(lat: 35.681236, lon: 139.767125), uti: "public.heic", name: "P_ASSET.HEIC")
        let pManual = item("P_MANUAL", location: nil, uti: "public.heic", name: "P_MANUAL.HEIC")
        let pNone = item("P_NONE", location: nil, uti: "public.heic", name: "P_NONE.HEIC")

        overrideStore.set(items: [pManual], location: PhotoLocation(lat: 36.25, lon: 138.125), source: .uploaderManual, placeName: "松本")

        let exporter = GPSFakeExporter(dir: dir, payloads: [
            "P_EXIF": (Data("exif-bytes".utf8), PhotoLocation(lat: 35.0001, lon: 135.0001)),
            "P_ASSET": (Data("asset-bytes".utf8), nil),
            "P_MANUAL": (Data("manual-bytes".utf8), nil),
            "P_NONE": (Data("none-bytes".utf8), nil),
        ])

        let fake = FakeDrive(files: [])
        StubProtocol.setHandler(fake.handle)
        let drive = DriveClient(session: StubProtocol.session(), tokens: FakeTokens(), sleeper: noSleep)
        let coord = UploadCoordinator(
            drive: drive, exporter: exporter, records: records, cache: nil,
            locationOverrides: overrideStore,
            options: .init(verifyAttempts: 2, verifyDelay: 0), sleeper: noSleep
        )

        let summary = try await coord.run(items: [pExif, pAsset, pManual, pNone], folderId: "FOLDER", maxItemsPerRun: 4)
        XCTAssertEqual(summary.sentCount, 4)
        XCTAssertNil(summary.results[0].locationSupplementSource)
        XCTAssertEqual(summary.results[1].locationSupplementSource, .photosAsset)
        XCTAssertEqual(summary.results[2].locationSupplementSource, .uploaderManual)
        XCTAssertNil(summary.results[3].locationSupplementSource)

        let posts = StubProtocol.recorded.filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 4)
        let metas = try posts.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0.body) as? [String: Any]) }
        XCTAssertNil(metas[0]["properties"])
        XCTAssertEqual((metas[1]["properties"] as? [String: String])?["geoframe.loc_source"], "photos_asset")
        XCTAssertEqual((metas[1]["properties"] as? [String: String])?["geoframe.lat"], "35.681236")
        XCTAssertEqual((metas[2]["properties"] as? [String: String])?["geoframe.loc_source"], "uploader_manual")
        XCTAssertEqual((metas[2]["properties"] as? [String: String])?["geoframe.lat"], "36.250000")
        XCTAssertNil(metas[3]["properties"])

        let recList = try records.readAll()
        XCTAssertEqual(recList.count, 4)
        XCTAssertEqual(recList[0].exifHasGPS, true)
        XCTAssertNil(recList[0].uploadedLocation)
        XCTAssertEqual(recList[1].exifHasGPS, false)
        XCTAssertEqual(recList[1].uploadedLocationSource, .photosAsset)
        XCTAssertEqual(recList[1].uploadedLocation, PhotoLocation(lat: 35.681236, lon: 139.767125))
        XCTAssertEqual(recList[2].exifHasGPS, false)
        XCTAssertEqual(recList[2].uploadedLocationSource, .uploaderManual)
        XCTAssertEqual(recList[2].uploadedLocation, PhotoLocation(lat: 36.25, lon: 138.125))
        XCTAssertEqual(recList[3].exifHasGPS, false)
        XCTAssertNil(recList[3].uploadedLocation)

        // 旧形式レコード（新フィールド欠損）の後方互換デコード
        let legacyLine = #"{"burstIdentifier":null,"creationDate":null,"creationTimeZone":"Asia/Tokyo","driveFileId":"F1","driveMd5Checksum":"m","error":null,"exifDateTimeOriginal":null,"exifOffsetTimeOriginal":null,"folderId":"F","hasAdjustments":false,"isFavorite":false,"isLivePhoto":false,"localIdentifier":"LEGACY","location":null,"md5":"m","originalFilename":"LEGACY.JPG","pixelHeight":100,"pixelWidth":100,"recordedAt":"2026-01-01T00:00:00+09:00","result":"sent","runId":"R","sha256":"s","byteCount":10,"uti":"public.jpeg","verified":true}"#
        let decodedLegacy = try JSONDecoder().decode(UploadRecord.self, from: Data(legacyLine.utf8))
        XCTAssertNil(decodedLegacy.exifHasGPS)
        XCTAssertNil(decodedLegacy.uploadedLocation)
        XCTAssertNil(decodedLegacy.uploadedLocationSource)
    }

    // MARK: - PhotoSectioner with overrides

    func testPhotoSectionerUsesOverridesWithoutMutatingItemsOrOverridingRealGPS() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let realA = item("A", date: base, location: PhotoLocation(lat: 35.0, lon: 135.0))
        let missingB = item("B", date: base.addingTimeInterval(60), location: nil)
        let missingC = item("C", date: base.addingTimeInterval(120), location: nil)

        // realA の既存位置に対する override は無視され、missingC は距離閾値超過で別セクションになる
        let overrides: [String: PhotoLocation] = [
            "A": PhotoLocation(lat: 40.0, lon: 140.0),
            "C": PhotoLocation(lat: 35.01, lon: 135.0),
        ]
        let sections = PhotoSectioner.section(
            items: [realA, missingB, missingC],
            options: SectionOptions(timeGapSeconds: 1800, distanceThresholdMeters: 300),
            locationOverrides: overrides
        )
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].items.map(\.localIdentifier), ["A", "B"])
        XCTAssertEqual(sections[0].representativeLocation, PhotoLocation(lat: 35.0, lon: 135.0))
        XCTAssertEqual(sections[1].items.map(\.localIdentifier), ["C"])
        XCTAssertEqual(sections[1].representativeLocation, PhotoLocation(lat: 35.01, lon: 135.0))
        XCTAssertFalse(sections[1].isLocationBorrowed)
        XCTAssertNil(missingC.location)
    }
}
