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

The build should print `Touch ID passkeys: True`. On a Mac whose builds sign with an **Apple Development**
certificate instead, a Developer ID profile is passed over; build there with
`RISE_SIGNING_IDENTITY='Developer ID Application: Bartosz Bak (7CAU3XFRLQ)'` to use it, or make a macOS
development profile the same way (it covers the same keychain group).

## 5. Try it

Open [webauthn.io](https://webauthn.io), register, and choose **This Mac** / Touch ID in the passkey
dialog. The passkey stays on this Mac. Never commit the profile to the repository.
