import XCTest
@testable import UploaderCore

final class EligibilityTests: XCTestCase {
    func testAcceptedFormats() {
        for (uti, mime) in [("public.jpeg", "image/jpeg"), ("public.png", "image/png"), ("public.heic", "image/heic"),
                            ("public.heif", "image/heif"), ("public.tiff", "image/tiff")] {
            XCTAssertEqual(EligibilityClassifier.classify(mediaKind: .image, photoResourceUTI: uti), .eligible, uti)
            XCTAssertEqual(EligibilityClassifier.mimeType(forUTI: uti), mime, uti)
        }
    }

    func testRejectedFormats() {
        XCTAssertEqual(EligibilityClassifier.classify(mediaKind: .image, photoResourceUTI: "com.adobe.raw-image"),
                       .ineligible(reason: "DNG（geoframe 非対応）"))
        XCTAssertFalse(EligibilityClassifier.classify(mediaKind: .image, photoResourceUTI: "public.camera-raw-image").isEligible)
        // Canon CR2 等の RAW（camera-raw-image 準拠）
        XCTAssertFalse(EligibilityClassifier.classify(mediaKind: .image, photoResourceUTI: "com.canon.cr2-raw-image").isEligible)
        XCTAssertNil(EligibilityClassifier.mimeType(forUTI: "com.adobe.raw-image"))
        XCTAssertEqual(EligibilityClassifier.classify(mediaKind: .image, photoResourceUTI: "com.compuserve.gif"),
                       .ineligible(reason: "形式 com.compuserve.gif 非対応"))
        XCTAssertEqual(EligibilityClassifier.classify(mediaKind: .video, photoResourceUTI: "com.apple.quicktime-movie"),
                       .ineligible(reason: "動画"))
        XCTAssertFalse(EligibilityClassifier.classify(mediaKind: .image, photoResourceUTI: nil).isEligible)
        XCTAssertFalse(EligibilityClassifier.classify(mediaKind: .image, photoResourceUTI: "public.data").isEligible)
    }

    func testPhotoItemDerivesEligibility() {
        let item = PhotoItem(localIdentifier: "A", originalFilename: "IMG_1.HEIC", uti: "public.heic", mediaKind: .image, creationDate: nil)
        XCTAssertTrue(item.eligibility.isEligible)
        XCTAssertEqual(item.mimeType, "image/heic")
    }
}

final class PlannerTests: XCTestCase {
    func testDecisions() {
        let remote = RemoteIndex(files: [DriveFile(id: "F1", name: "IMG_1.HEIC", md5Checksum: "AAAA")])
        let inputs = [
            PlanInput(localIdentifier: "L1", eligibility: .eligible, md5: "aaaa"),          // remote dup (case-insensitive)
            PlanInput(localIdentifier: "L2", eligibility: .eligible, md5: "bbbb"),          // upload
            PlanInput(localIdentifier: "L3", eligibility: .eligible, md5: "BBBB"),          // in-batch dup of L2
            PlanInput(localIdentifier: "L4", eligibility: .ineligible(reason: "動画"), md5: nil),
            PlanInput(localIdentifier: "L5", eligibility: .eligible, md5: nil),
            PlanInput(localIdentifier: "L6", eligibility: .eligible, md5: "cccc"),
        ]
        XCTAssertEqual(UploadPlanner.plan(inputs, remote: remote), [
            .duplicateRemote(fileId: "F1", name: "IMG_1.HEIC"),
            .toUpload,
            .duplicateInBatch(ofLocalIdentifier: "L2"),
            .ineligible(reason: "動画"),
            .notHashed,
            .toUpload,
        ])
    }

    func testRemoteMD5FileFormats() throws {
        let a = try RemoteMD5File.parse(json(["abc", "DEF"]))
        XCTAssertNotNil(a.lookup("def"))
        let rclone = try RemoteMD5File.parse(json([
            ["Path": "IMG_1.HEIC", "Name": "IMG_1.HEIC", "ID": "X1", "Hashes": ["md5": "1234"]],
            ["Path": "noHash", "Name": "noHash"],
        ]))
        XCTAssertEqual(rclone.count, 1)
        XCTAssertEqual(rclone.lookup("1234")?.id, "X1")
        let drive = try RemoteMD5File.parse(json(["files": [["id": "Z", "name": "n", "md5Checksum": "ffff"]]]))
        XCTAssertEqual(drive.lookup("FFFF")?.id, "Z")
    }
}

final class LocalTimeTests: XCTestCase {
    func testDayRangeSingleDayAndDST() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let r = LocalTime.dayRange(fromDay: "2026-04-19", toDay: nil, calendar: cal)!
        XCTAssertEqual(r.end.timeIntervalSince(r.start), 86400)
        XCTAssertEqual(LocalTime.iso8601(r.start, timeZone: cal.timeZone), "2026-04-19T00:00:00+09:00")

        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-03-08 は DST 開始で 23 時間
        let d = LocalTime.dayRange(fromDay: "2026-03-08", toDay: "2026-03-08", calendar: ny)!
        XCTAssertEqual(d.end.timeIntervalSince(d.start), 23 * 3600)
        let multi = LocalTime.dayRange(fromDay: "2026-04-01", toDay: "2026-04-03", calendar: cal)!
        XCTAssertEqual(multi.end.timeIntervalSince(multi.start), 3 * 86400)
        XCTAssertNil(LocalTime.dayRange(fromDay: "2026-02-30", toDay: nil, calendar: cal))
        XCTAssertNil(LocalTime.dayRange(fromDay: "x", toDay: nil, calendar: cal))
    }
}

final class ConfigTests: XCTestCase {
    func testParseOAuthClient() throws {
        let c = try OAuthClientConfig.parse(json(["installed": [
            "client_id": "id.apps.googleusercontent.com", "client_secret": "s",
            "auth_uri": "https://accounts.google.com/o/oauth2/auth", "token_uri": "https://oauth2.googleapis.com/token",
            "redirect_uris": ["http://localhost"]]]))
        XCTAssertEqual(c.clientId, "id.apps.googleusercontent.com")
        XCTAssertEqual(c.tokenURI.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertThrowsError(try OAuthClientConfig.parse(json(["web": ["client_id": "x"]])))
    }

    func testAppConfigRoundTripAndPerms() throws {
        let dir = makeTempDir().appendingPathComponent("support")
        let paths = AppPaths(baseDir: dir)
        try paths.ensureBaseDir()
        let perms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o700)
        XCTAssertEqual(try AppConfig.load(from: paths.configFile), AppConfig())
        try AppConfig(folderId: "FID").save(to: paths.configFile)
        XCTAssertEqual(try AppConfig.load(from: paths.configFile).folderId, "FID")
    }

    func testRedactor() {
        let s = Redactor.redact(#"{"access_token": "ya29.abc-DEF", "refresh_token":"1//0gXYZ"} Bearer ya29.q code=4/0Aabc&state=s upload_id=ABCD"#)
        XCTAssertFalse(s.contains("abc-DEF"))
        XCTAssertFalse(s.contains("0gXYZ"))
        XCTAssertFalse(s.contains("4/0Aabc"))
        XCTAssertFalse(s.contains("ABCD"))
        XCTAssertTrue(s.contains("state=s"))
    }
}
