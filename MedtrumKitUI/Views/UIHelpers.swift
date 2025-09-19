import SwiftUI

struct KeepAwakeModifier: ViewModifier {
    @State private var isVisible = false
    let isBusy: Bool
    let alsoWhenVisible: Bool

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                applyIdleTimerPolicy()
            }
            .onDisappear {
                isVisible = false
                applyIdleTimerPolicy()
            }
            .onChange(of: isBusy) { _ in
                applyIdleTimerPolicy()
            }
    }

    private func applyIdleTimerPolicy() {
        let shouldKeepAwake = (alsoWhenVisible && isVisible) || isBusy
        if Thread.isMainThread {
            UIApplication.shared.isIdleTimerDisabled = shouldKeepAwake
        } else {
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = shouldKeepAwake
            }
        }
    }
}

extension View {
    func keepScreenAwake(whenBusy isBusy: Bool, alsoWhenVisible: Bool = true) -> some View {
        modifier(KeepAwakeModifier(isBusy: isBusy, alsoWhenVisible: alsoWhenVisible))
    }
}
