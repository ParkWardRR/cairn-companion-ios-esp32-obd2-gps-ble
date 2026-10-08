import SwiftUI

#if os(iOS)
import WebKit

/// The dashboard inside the app, already signed in: the passkey session cookie the app got is handed
/// to the web view before it loads, so there is nothing to sign in to a second time.
struct DashboardWebView: UIViewRepresentable {
    let url: URL
    let cookies: [HTTPCookie]

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.allowsBackForwardNavigationGestures = true
        Task { @MainActor in
            let store = view.configuration.websiteDataStore.httpCookieStore
            for cookie in cookies { await store.setCookie(cookie) }
            view.load(URLRequest(url: url))
        }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct DashboardSheet: View {
    let url: URL
    let cookies: [HTTPCookie]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DashboardWebView(url: url, cookies: cookies)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Dashboard")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}
#endif
