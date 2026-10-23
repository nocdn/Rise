# Making Rise's Touch ID passkey profile

Rise's own Touch ID passkeys need a **Developer ID provisioning profile** for `dev.bartosz.Rise`.
It's self-serve: no request to Apple and no review. This can be done on any Mac signed in to the
developer account (or in any browser), then copied to the Mac that builds Rise. See
[Passkeys.md](Passkeys.md) for why.

## 1. Check the certificate

The profile has to name the certificate Rise is signed with. On the Mac that builds Rise:

```sh
security find-identity -v -p codesigning
```

Note the line with **Developer ID Application: Bartosz Bak (7CAU3XFRLQ)**. If there isn't one, make it in
the portal under **Certificates** first (it needs the Account Holder) and install it on that Mac.

## 2. The App ID (once)

1. Open [developer.apple.com/account/resources/identifiers](https://developer.apple.com/account/resources/identifiers/list)
   and sign in.
2. If `dev.bartosz.Rise` is already listed for macOS, go to step 3.
3. Otherwise **+** › **App IDs** › **Continue** › type **App** › **Continue**.
4. Platform **macOS**, description `Rise`, **Explicit** bundle ID `dev.bartosz.Rise`.
5. Leave every capability unticked. **Continue** › **Register**.

## 3. The profile

1. Open [Profiles](https://developer.apple.com/account/resources/profiles/list) › **+**.
2. Under **Distribution**, choose **Developer ID** › **Continue**.
3. Profile type **Mac**, App ID **`7CAU3XFRLQ.dev.bartosz.Rise`** › **Continue**.
4. Tick the **Developer ID Application** certificate from step 1 › **Continue**.
5. Name it `Rise Developer ID` › **Generate** › **Download**. It's a `.provisionprofile` file.

## 4. Put it where Rise's build finds it

On the Mac that builds Rise (AirDrop the file over if it was made elsewhere):

```sh
mkdir -p ~/Library/Application\ Support/Rise/Signing
mv ~/Downloads/Rise_Developer_ID.provisionprofile ~/Library/Application\ Support/Rise/Signing/
./scripts/restart.sh
```

The build should print `Touch ID passkeys: True`. A profile deliberately installed in Rise's
`Signing` folder selects its matching installed certificate automatically, so this setup survives
rebuilds without shell environment variables. `RISE_SIGNING_IDENTITY` and `RISE_PROVISIONING_PROFILE`
still override automatic selection. Without a dedicated profile, the existing Apple Development
identity remains the default; a matching macOS development profile can enable Touch ID too.

**1Password's desktop connection needs Developer ID signing in the tested setup.** The Apple
Development build was rejected as `UnknownBrowser` even after it was added to trusted browsers.
The same app signed with the Developer ID certificate connected immediately. Put the actual app in
`/Applications` and launch that copy before adding it in 1Password's Browser settings. On the
Mac configured on 23 October 2026, `build/Rise.app` is a local symlink to `/Applications/Rise.app`,
so normal rebuilds update and relaunch that same trusted app. The symlink is in the ignored build
folder, not a repository setting for other developers.

Developer ID profiles authorize **Production** CloudKit and push notifications. Development profiles
continue using **Development**. These are separate iCloud databases: changing signing modes does not
migrate data, and a locally installed iOS development build remains on Development. The build prints
its selected environment; both modes retain iCloud sync and the same Touch ID keychain group.

## 5. Try it

Open [webauthn.io](https://webauthn.io), register, and choose **This Mac** / Touch ID in the passkey
dialog. The passkey stays on this Mac. Never commit the profile to the repository.
