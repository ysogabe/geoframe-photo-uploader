import AppKit
import SwiftUI

/// `--cli` があれば CLI モード（NSApplication accessory ループ内で実行）、無ければ SwiftUI アプリ。
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--cli") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            Task.detached(priority: .userInitiated) {
                var cli = CLI(arguments: args)
                let code = await cli.run()
                exit(code)
            }
            app.run()
        } else {
            UploaderApp.main()
        }
    }
}
