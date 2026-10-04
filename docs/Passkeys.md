# Passkeys in Rise

WebKit handles website WebAuthn registration and authentication, including native
passkey selection. Rise keeps this flow in WebKit: it does not override
`navigator.credentials`, access private key material, or inject a credential bridge.

Arbitrary website passkeys require Apple's restricted
`com.apple.developer.web-browser.public-key-credential` entitlement, a matching
provisioning profile, and the person's macOS consent. The standard local build
does **not** enable the restricted capability. Adding it without a valid profile
can prevent the app from launching.

## Request Apple's approval

1. Sign in as the Account Holder of your **organization** Apple Developer account.
   Apple's current documentation specifies an organization account. If yours is
   an individual account or the form is unavailable, ask Apple Developer Support
   about eligibility before changing account enrollment.
2. Submit the [macOS Browsers Passkeys request](https://developer.apple.com/contact/request/macos-browsers-passkeys/).
   Use Rise's details below. The account holder submits this request; approval is
   Apple's decision.
3. Once approved, enable the managed browser passkey capability for Rise's explicit
   macOS App ID, `dev.bartosz.Rise`, in Certificates, Identifiers & Profiles.
4. Generate and download a macOS provisioning profile that includes the capability
   and the signing certificate you will use. Do not use another app's profile.
5. Build using that profile and certificate. Then verify on an HTTPS website that
   supports passkeys, approving the native macOS prompt yourself. Apple or the
   chosen credential provider handles subsequent user verification.

### Rise details for the request

- **Application:** Rise
- **Bundle identifier:** `dev.bartosz.Rise`
- **Platform:** macOS 14 and later
- **Browser engine:** WKWebView / WebKit
- **Purpose:** A general-purpose desktop web browser with arbitrary website navigation,
  multiple tabs, an address/search field, browsing history, and normal back/forward navigation.
- **HTTP/HTTPS:** Both schemes are declared in the app's Info.plist. Entered URLs
  render their expected destination directly in WebKit.
- **Requested functionality:** Website passkey registration and sign-in through
  native WebKit WebAuthn, with the operating system and supported credential
  providers handling credential selection and verification.
- **Distribution:** Currently a local macOS build. Provide your intended release
  distribution and any app/site links that the form requests; Rise is not yet a
  released Mac App Store application.

## Build after approval

```sh
security find-identity -v -p codesigning
RISE_SIGNING_IDENTITY='YOUR_CERTIFICATE_SHA1' \
RISE_PROVISIONING_PROFILE='/absolute/path/to/Rise.provisionprofile' \
./scripts/build.sh
```

The signing script rejects profiles without the capability, expired profiles,
profiles for another app, and certificates not included in the profile. It embeds
the approved profile and signs with the matching entitlement. Certificate hashes
and downloaded profiles stay local; do not commit profiles or signing credentials.

Without these environment variables, the standard build signs with a local Apple
Development identity (or ad-hoc when none is installed) and without the restricted
passkey entitlement. Approval cannot be replaced
by a WebKit preference or a JavaScript polyfill.

## References

- [Apple: Passkey use in web browsers](https://developer.apple.com/documentation/authenticationservices/passkey-use-in-web-browsers)
- [Apple: Browser public-key-credential entitlement and eligibility](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential)
- [Apple: Authenticating people by using passkeys in browser apps](https://developer.apple.com/documentation/authenticationservices/authenticating-people-by-using-passkeys-in-browser-apps)
