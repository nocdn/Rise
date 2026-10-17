"""Sign local builds normally; enable WebKit passkeys only with Apple's profile."""
import datetime
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


def passkey_entitlements(profile, bundle_id, certificate_hash, now=None):
    entitlements = profile.get("Entitlements", {})
    if entitlements.get(PASSKEY) is not True:
        raise ValueError("The provisioning profile does not authorize browser passkeys. Apple approval is required.")
    return {PASSKEY: True, **profile_identity(profile, bundle_id, certificate_hash, now)}


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
    if "Development" not in environments:
        raise ValueError("Local builds require the Development CloudKit environment.")
    result.update({
        "com.apple.developer.icloud-container-identifiers": [CLOUD_CONTAINER],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.icloud-container-environment": "Development",
    })
    if granted.get("com.apple.developer.aps-environment") == "development":
        result["com.apple.developer.aps-environment"] = "development"
    return result


def cloudkit_profile(bundle_id, certificate_hash):
    directory = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
    for path in sorted(directory.glob("*.provisionprofile")) + sorted(directory.glob("*.mobileprovision")):
        try:
            profile = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(path)], stderr=subprocess.PIPE))
            return path, cloudkit_entitlements(profile, bundle_id, certificate_hash)
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
    """An Apple Development identity for everyday builds, or ad-hoc ("-") without one.

    macOS keys privacy grants (such as Downloads folder access) to the signature's
    designated requirement. Ad-hoc signatures pin each build's hash, so every rebuild
    asks again; a development certificate keeps the requirement stable across builds.
    Identities sharing a name produce the same requirement, so any match will do.
    """
    matches = sorted(sha for sha, name in re.findall(r'([A-Fa-f0-9]{40})\s+"([^"]+)"', listing)
                     if name.startswith("Apple Development:"))
    return matches[0] if matches else "-"


def configuration(info):
    identity = os.environ.get("RISE_SIGNING_IDENTITY")
    if not identity:
        identity = local_identity(subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True))
    profile_path = os.environ.get("RISE_PROVISIONING_PROFILE")
    if profile_path:
        if identity == "-":
            raise ValueError("Browser passkeys require an Apple signing identity, not ad-hoc signing.")
        profile_file = Path(profile_path).expanduser()
        profile = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(profile_file)], stderr=subprocess.PIPE))
        entitlements = passkey_entitlements(profile, info["CFBundleIdentifier"], signing_certificate(identity))
        declared = plistlib.loads(Path(__file__).with_name("Rise-passkeys.entitlements").read_bytes())
        if declared.get(PASSKEY) is not True:
            raise ValueError("The passkey entitlements template is missing the browser capability.")
        try:
            entitlements.update(cloudkit_entitlements(profile, info["CFBundleIdentifier"], signing_certificate(identity)))
        except ValueError:
            pass
        return identity, profile_file, entitlements
    if identity != "-":
        profile_file, entitlements = cloudkit_profile(info["CFBundleIdentifier"], signing_certificate(identity))
        return identity, profile_file, entitlements
    return identity, None, None


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
            subprocess.run([*command, "--options", "runtime", "--timestamp", "--entitlements", temporary.name, str(app)], check=True)
        print("Signed with Apple's provisioning profile. CloudKit: " + str(info["RiseCloudKitEnabled"]) + "; browser passkeys: " + str(PASSKEY in entitlements))
    else:
        # An ad-hoc app claiming this restricted entitlement can fail to launch.
        # Also remove a profile left by a previous approved build of this bundle.
        embedded.unlink(missing_ok=True)
        subprocess.run([*command, str(app)], check=True)
        print("Local build" + (" (ad-hoc)" if identity == "-" else "") + ": browser passkeys need an Apple-approved provisioning profile.")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        raise SystemExit(str(error))
