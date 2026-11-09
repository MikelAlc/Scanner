import SwiftUI
import GoogleSignIn

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL{GIDSignIn.sharedInstance.handle($0)}
        }
    }
}
