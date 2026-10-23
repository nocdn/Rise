# Passkeys in Rise

Rise's pages are Chromium's, and so is their WebAuthn: the engine finds security keys, asks
password manager extensions, shows a phone's QR code and keeps its own Touch ID passkeys, with
Chrome's own dialog. Rise doesn't override `navigator.credentials` or touch key material.

| Where the passkey is | What Rise needs |
|---|---|
| A security key, such as a YubiKey, over USB | Nothing. The engine talks to the key itself (`device/fido/hid`), not through Apple's passkey API. |
| A password manager extension, such as 1Password or Bitwarden | The extension, from the Chrome Web Store. Its desktop app connects as below. |
| A phone, by QR code | Bluetooth, which macOS asks for the first time; the engine handles the rest (`device/fido/cable`). |
| This Mac, with Touch ID | A provisioning profile for Rise, which any developer account makes without review (below). |
| iCloud Keychain / Apple Passwords | Apple's approval of the browser entitlement (below). Without it the engine leaves that option out. |

## Touch ID passkeys

The engine keeps these in the Secure Enclave, in the keychain group `<team>.dev.bartosz.Rise.webauthn`
(patch `0017` makes the group follow the identity Rise is signed with). Claiming a keychain group is a
restricted entitlement on macOS, so it has to come with a provisioning profile, but the profile is
self-serve: no request, no review. Passkeys made this way stay on this Mac. Step by step, for doing it
on another Mac: [TouchIDPasskeyProfile.md](TouchIDPasskeyProfile.md).

1. At [developer.apple.com/account/resources](https://developer.apple.com/account/resources/identifiers/list),
   under **Identifiers**, add an **App ID** for macOS with the explicit bundle ID `dev.bartosz.Rise`
   if there isn't one. It needs no capabilities ticked.
2. Under **Profiles**, add a **Developer ID** profile (in Distribution) for that App ID, with the
   **Developer ID Application** certificate Rise is signed with, and download it.
3. Put it in `~/Library/Application Support/Rise/Signing/`. `./scripts/build.sh` finds it there (or in
   Xcode's profile folders, or at `RISE_PROVISIONING_PROFILE`) and signs Rise with the passkey keychain
   group, under the hardened runtime with Chrome's own device entitlements (camera, microphone,
   location, photos, printing, USB and Bluetooth).

The build says `Touch ID passkeys: True` when signing authorizes the group; verify the authenticator
and a real registration separately. A profile installed in Rise's `Signing` folder selects its matching
certificate automatically, including Developer ID on a Mac that also has development certificates.
The signing script only uses a profile made for
`dev.bartosz.Rise`, with the certificate it's signing with and not yet expired, and claims only what that
profile allows, so a wrong profile is passed over rather than stopping Rise from launching. Keep profiles
out of the repository.

## Password manager extensions

Password managers can offer passkeys through page integration. Rise's native messaging connects the
extension to its desktop app. The 1Password page-integration route was tested end to end below; this
does not establish compatibility with every password manager or with every `webAuthenticationProxy`
integration.

Their desktop apps register *native messaging hosts* with the browsers they know, never Rise. At launch
Rise links the hosts registered for Chrome and Chromium into its own `NativeMessagingHosts` folder
(`NativeMessagingHosts.swift`), so an extension reaches its app as it does in Chrome. 1Password's app
also checks which browser is asking: add Rise in 1Password ▸ Settings ▸ Browser ▸ **Add Browser**. It
only lists code-signed apps in the Applications folder.

Use **Developer ID Application** signing for 1Password's desktop connection. On this Mac, 1Password
8.12.40 rejected the Apple Development signature as `UnknownBrowser` even with Rise in the trusted
list; the Developer ID signature connected successfully, sharing the unlocked account with extension
8.12.42.36. The extension was installed from the Web Store, and a disposable webauthn.io registration
and sign-in succeeded with the site identifying its provider as 1Password. No Apple browser-passkey
entitlement was claimed. This is the extension route, not Apple Passwords AutoFill.

The live transport check exercises a registered native host and its extension allowlist:
`python3 scripts/test-chromium-live.py extensions`. It also checks tab APIs, content scripts,
popups, pinning, shortcuts and extension-initiated `chrome.action.openPopup()`, including rejection
of a duplicate request without replacing the visible popup. Patch `0019` routes that API to Rise;
without it Chromium required Chrome's toolbar and returned `Browser window has no toolbar`.
`python3 scripts/test-chromium-live.py passkeys` uses a genuinely
provisioned app to check platform authenticator availability, relying-party isolation and cancellation.
It intentionally creates no credential and is not an end-to-end Touch ID sign-in test. Both Apple
Development and Developer ID signed runs passed on this Mac on 23 October 2026.

The interactive local test also passed: `rise-touchid-test-20261023` registered using Chromium's
"This passkey will only be saved on this device" dialog and the owner's Touch ID, then signed in.
webauthn.io identified it as a **device-bound passkey**, transport `internal`, provider **Chromium
Browser** (AAGUID `b5397666-4885-aa6b-cebf-e52262a439a2`). The 1Password test was separately identified
as a **synced passkey**, provider **1Password** (AAGUID `bada5566-a7aa-401f-bd96-45619a55120d`). The
owner completed credential creation and physical Touch ID; no virtual authenticator stood in for it.

Developer ID signing uses the profile's **Production** CloudKit database and push environment;
development signing keeps **Development**. The databases are separate and signing does not migrate
their data. See [TouchIDPasskeyProfile.md](TouchIDPasskeyProfile.md).

## iCloud Keychain passkeys

These go through Apple's `ASAuthorization` browser API, which needs the restricted
`com.apple.developer.web-browser.public-key-credential` entitlement. The Account Holder of an organization
developer account requests it with the
[macOS Browsers Passkeys form](https://developer.apple.com/contact/request/macos-browsers-passkeys/);
once Apple approves, the capability shows on Rise's App ID, and a profile made after that carries it,
which `sign-app.py` then claims too. Until then, the same passkeys work from an iPhone by QR code.

For the form: Rise is a general-purpose macOS 14+ browser (`dev.bartosz.Rise`) on its own Chromium fork,
declaring HTTP and HTTPS, with an address and search field, tabs, history and back and forward, opening
each URL at its own address.

## References

- [Apple: The browser public-key-credential entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential)
- [Apple: TN3125, provisioning profiles and restricted entitlements](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- [1Password: Connect additional browsers](https://support.1password.com/additional-browsers/)
