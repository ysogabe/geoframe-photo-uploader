import Foundation

/// 強制終了などで消し損ねた原本の一時ディレクトリ（`$TMPDIR/GeoFrameUploader-<UUID>`）を起動時に掃除する。
/// 対象は `root` 直下の、接頭辞 + UUID の名前で、自分が所有する実ディレクトリ（シンボリックリンクは辿らず触らない）で、
/// 更新から `olderThan` 秒以上経ったものだけ。
public enum TempSweeper {
    public static let defaultMaxAge: TimeInterval = 60 * 60

    /// 削除したディレクトリを返す。失敗は無視する（ベストエフォート）。
    @discardableResult
    public static func sweepStale(root: URL = FileManager.default.temporaryDirectory,
                                  prefix: String = OriginalExporter.tempDirPrefix,
                                  olderThan maxAge: TimeInterval = defaultMaxAge,
                                  now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        let uid = getuid()
        var removed: [URL] = []
        for name in names {
            guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else { continue }
            let url = root.appendingPathComponent(name, isDirectory: true)
            var st = stat()
            // lstat: シンボリックリンクは辿らない（リンク自体も消さない）
            guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == uid else { continue }
            let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                             + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
            guard now.timeIntervalSince(mtime) >= maxAge else { continue }
            // removeItem は中のシンボリックリンクをリンクとして消す（リンク先は辿らない）
            if (try? fm.removeItem(at: url)) != nil { removed.append(url) }
        }
        return removed
    }
}
