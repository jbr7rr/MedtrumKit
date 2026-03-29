import LocalAuthentication

enum AuthorizeBiometrics {
    static func authenticate(success authSuccess: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?

        // check whether authentication is possible
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            // it's possible, so go ahead and use it
            let reason = "We need to unlock your data."

            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                authSuccess(success)
            }
        } else {
            // no auth, automatically allow
            authSuccess(true)
        }
    }
}
