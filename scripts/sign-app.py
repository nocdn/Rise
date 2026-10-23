"""Sign local builds normally; with a provisioning profile for Rise, also claim what it allows:
the keychain group for the engine's Touch ID passkeys, CloudKit, and Apple-approved passkeys."""
import datetime
import fnmatch
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

PASSKEY = "com.apple.developer.web-browser.public-key-credential"
CLOUD_CONTAINER = "iCloud.dev.bartosz.Rise"
# The keychain group the engine keeps Touch ID passkeys in, after the app's own identifier.
WEBAUTHN_GROUP = ".webauthn"
# What Chrome's own app claims under the hardened runtime, so websites keep the camera, microphone,
# location and photos, and security keys and phones keep USB and Bluetooth, once a profile signs Rise.
CHROME_DEVICES = {
    "com.apple.security.device.audio-input": True,
    "com.apple.security.device.bluetooth": True,
    "com.apple.security.device.camera": True,
    "com.apple.security.device.print": True,
    "com.apple.security.device.usb": True,
    "com.apple.security.personal-information.location": True,
    "com.apple.security.personal-information.photos-library": True,
}
# Where profiles are looked for, Rise's own folder first.
PROFILE_FOLDERS = [
    Path.home() / "Library/Application Support/Rise/Signing",
    Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
    Path.home() / "Library/MobileDevice/Provisioning Profiles",
]


def profile_identity(profile, bundle_id, certificate_hash, now=None):
    if "OSX" not in profile.get("Platform", []):
        raise ValueError("A macOS provisioning profile is required.")
    entitlements = profile.get("Entitlements", {})
    expiration = profile.get("ExpirationDate")
    now = now or datetime.datetime.now(datetime.timezone.utc)
    if expiration is None or expiration.replace(tzinfo=datetime.timezone.utc) <= now:
        raise ValueError("The provisioning profile is missing its expiration date or has expired.")
    app_key = "com.apple.application-identifier" if "com.apple.application-identifier" in entitlements else "application-identifier"
    app_id = entitlements.get(app_key, "")
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    if not any(app_id == prefix + "." + bundle_id for prefix in prefixes):
        raise ValueError("The provisioning profile must explicitly authorize " + bundle_id + ".")
    certificates = {hashlib.sha1(cert).hexdigest().upper() for cert in profile.get("DeveloperCertificates", [])}
    if certificate_hash.upper() not in certificates:
        raise ValueError("The signing certificate is not authorized by this provisioning profile.")
    result = {app_key: app_id}
    team = entitlements.get("com.apple.developer.team-identifier")
    if team:
        result["com.apple.developer.team-identifier"] = team
    return result


def cloudkit_entitlements(profile, bundle_id, certificate_hash, now=None):
    result = profile_identity(profile, bundle_id, certificate_hash, now)
    granted = profile.get("Entitlements", {})
    if CLOUD_CONTAINER not in granted.get("com.apple.developer.icloud-container-identifiers", []):
        raise ValueError("The profile does not authorize Rise's shared CloudKit container.")
    services = granted.get("com.apple.developer.icloud-services", [])
    if services != "*" and "CloudKit" not in services:
        raise ValueError("The profile does not authorize CloudKit.")
    environments = granted.get("com.apple.developer.icloud-container-environment", [])
    if isinstance(environments, str):
        environments = [environments]
    # Development profiles keep local Mac/iOS installs on their existing data. Developer ID
    # profiles authorize Production only; do not silently turn off sync when signing with one.
    environment = next((value for value in ("Development", "Production") if value in environments), None)
    if environment is None:
        raise ValueError("The profile does not authorize a CloudKit environment.")
    result.update({
        "com.apple.developer.icloud-container-identifiers": [CLOUD_CONTAINER],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.icloud-container-environment": environment,
    })
    push_environment = granted.get("com.apple.developer.aps-environment")
    if push_environment == environment.lower():
        result["com.apple.developer.aps-environment"] = push_environment
    return result


def profile_entitlements(profile, bundle_id, certificate_hash, now=None):
    """Everything a profile for this app and certificate allows Rise: its identity, the engine's Touch
    ID passkey group where the profile's keychain groups cover it, Apple-approved passkeys and CloudKit
    where granted, and Chrome's device access for the hardened runtime that profile signing uses."""
    result = profile_identity(profile, bundle_id, certificate_hash, now)
    granted = profile.get("Entitlements", {})
    app_id = result.get("com.apple.application-identifier") or result.get("application-identifier")
    group = app_id + WEBAUTHN_GROUP
    if any(fnmatch.fnmatchcase(group, pattern) for pattern in granted.get("keychain-access-groups", [])):
        result["keychain-access-groups"] = [group]
    if granted.get(PASSKEY) is True:
        result[PASSKEY] = True
    try:
        result.update(cloudkit_entitlements(profile, bundle_id, certificate_hash, now))
    except ValueError:
        pass
    result.update(CHROME_DEVICES)
    return result


def read_profile(path):
    return plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(path)], stderr=subprocess.PIPE))


def found_profile(bundle_id, certificate_hash):
    """The first profile in `PROFILE_FOLDERS` made for this app and certificate."""
    for folder in PROFILE_FOLDERS:
        for path in sorted(folder.glob("*.provisionprofile")) + sorted(folder.glob("*.mobileprovision")):
            try:
                return path, profile_entitlements(read_profile(path), bundle_id, certificate_hash)
            except (ValueError, subprocess.CalledProcessError, plistlib.InvalidFileException):
                continue
    return None, None


def signing_certificate(identity):
    listing = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
    identities = re.findall(r'([A-Fa-f0-9]{40})\s+"([^"]+)"', listing)
    matches = [sha for sha, name in identities if sha.lower() == identity.lower() or name == identity]
    if len(matches) != 1:
        raise ValueError("Set RISE_SIGNING_IDENTITY to the SHA-1 of one valid signing certificate from security find-identity -v -p codesigning.")
    return matches[0]


def local_identity(listing):
    """An Apple Development identity for everyday builds, else a Developer ID one, or
    ad-hoc ("-") without either.

    macOS keys privacy grants (such as Downloads folder access) and Keychain "Always
    Allow" (Chromium Safe Storage) to the signature's designated requirement. Ad-hoc
    signatures pin each build's hash, so every rebuild asks again; a certificate keeps
    the requirement stable across builds. Identities sharing a name produce the same
    requirement, so any match will do.
    """
    identities = re.findall(r'([A-Fa-f0-9]{40})\s+"([^"]+)"', listing)
    for kind in ("Apple Development:", "Developer ID Application:"):
        matches = sorted(sha for sha, name in identities if name.startswith(kind))
        if matches:
            return matches[0]
    return "-"


def configuration(info):
    identity = os.environ.get("RISE_SIGNING_IDENTITY")
    profile_path = os.environ.get("RISE_PROVISIONING_PROFILE")
    if not identity:
        listing = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
        # A profile deliberately installed in Rise's signing folder chooses its matching
        # certificate. In particular, 1Password accepts Developer ID signed custom browsers,
        # while an Apple Development build can be rejected as UnknownBrowser even when trusted.
        # Explicit environment overrides still win. Macs without a dedicated profile retain
        # their existing stable development identity and Development iCloud environment.
        if profile_path:
            return configuration_for_profile(Path(profile_path).expanduser(), info["CFBundleIdentifier"], listing)
        for path in sorted(PROFILE_FOLDERS[0].glob("*.provisionprofile")) + sorted(PROFILE_FOLDERS[0].glob("*.mobileprovision")):
            try:
                return configuration_for_profile(path, info["CFBundleIdentifier"], listing)
            except (ValueError, subprocess.CalledProcessError, plistlib.InvalidFileException):
                continue
        identity = local_identity(listing)
    if profile_path:
        if identity == "-":
            raise ValueError("A provisioning profile needs an Apple signing identity, not ad-hoc signing.")
        profile_file = Path(profile_path).expanduser()
        return identity, profile_file, profile_entitlements(read_profile(profile_file), info["CFBundleIdentifier"], signing_certificate(identity))
    if identity != "-":
        profile_file, entitlements = found_profile(info["CFBundleIdentifier"], signing_certificate(identity))
        return identity, profile_file, entitlements
    return identity, None, None


def configuration_for_profile(path, bundle_id, listing):
    """Select an installed private-key identity actually authorized by this profile."""
    profile = read_profile(path)
    identities = re.findall(r'([A-Fa-f0-9]{40})\s+"([^"]+)"', listing)
    for certificate_hash, _ in identities:
        try:
            return certificate_hash, path, profile_entitlements(profile, bundle_id, certificate_hash)
        except ValueError:
            continue
    raise ValueError("The profile must be valid for " + bundle_id + " and authorize an installed signing identity: " + str(path))


def main():
    if sys.argv[1] == "--check":
        configuration(plistlib.loads(Path(__file__).with_name("Info.plist").read_bytes()))
        return
    app = Path(sys.argv[1])
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    identity, profile_file, entitlements = configuration(info)
    info["RiseCloudKitEnabled"] = bool(entitlements and "com.apple.developer.icloud-services" in entitlements)
    info_path.write_bytes(plistlib.dumps(info))
    embedded = app / "Contents/embedded.provisionprofile"
    command = ["codesign", "--force", "--sign", identity]
    # The engine's framework, with its helper apps, signed as the app is: under the hardened runtime,
    # the app only loads a framework signed by its own team.
    for framework in (app / "Contents/Frameworks").glob("*.framework"):
        subprocess.run([*command, "--deep", str(framework)], check=True, stderr=subprocess.DEVNULL)
    if profile_file:
        if profile_file.resolve() != embedded.resolve():
            shutil.copyfile(profile_file, embedded)
        with tempfile.NamedTemporaryFile(suffix=".entitlements") as temporary:
            plistlib.dump(entitlements, temporary); temporary.flush()
            # Local development can stay certificate-signed when Apple's timestamp service is offline.
            timestamp = "--timestamp=none" if os.environ.get("RISE_SIGNING_TIMESTAMP") == "none" else "--timestamp"
            subprocess.run([*command, "--options", "runtime", timestamp, "--entitlements", temporary.name, str(app)], check=True)
        print("Signed with the provisioning profile " + profile_file.name + ". Touch ID passkeys: " + str("keychain-access-groups" in entitlements)
              + "; iCloud Keychain passkeys: " + str(PASSKEY in entitlements) + "; CloudKit: " + str(info["RiseCloudKitEnabled"])
              + " (" + entitlements.get("com.apple.developer.icloud-container-environment", "none") + ")")
    else:
        # An ad-hoc app claiming this restricted entitlement can fail to launch.
        # Also remove a profile left by a previous approved build of this bundle.
        embedded.unlink(missing_ok=True)
        subprocess.run([*command, str(app)], check=True)
        print("Local build" + (" (ad-hoc)" if identity == "-" else "") + ": Touch ID passkeys need a provisioning profile for Rise (docs/Passkeys.md).")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        raise SystemExit(str(error))
