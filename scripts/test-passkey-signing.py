"""Validate signing eligibility without claiming to exercise a real passkey."""
import copy
import datetime
import hashlib
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("rise_signing", Path(__file__).with_name("sign-app.py"))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class PasskeySigningTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime.datetime(2026, 10, 4, tzinfo=datetime.timezone.utc)
        self.cert = b"test-only certificate fixture"
        self.sha = hashlib.sha1(self.cert).hexdigest()
        self.profile = {
            "Platform": ["OSX"],
            "ExpirationDate": datetime.datetime(2027, 10, 4),
            "ApplicationIdentifierPrefix": ["TESTTEAM"],
            "DeveloperCertificates": [self.cert],
            "Entitlements": {
                signing.PASSKEY: True,
                "com.apple.application-identifier": "TESTTEAM.dev.bartosz.Rise",
                "com.apple.developer.team-identifier": "TESTTEAM",
                "com.apple.security.get-task-allow": True,
            },
        }

    def testAProfileForRiseGivesTheTouchIdGroupAndChromesDevicesButApprovalOnlyWhenGranted(self):
        self.profile["Entitlements"][signing.PASSKEY] = False
        self.profile["Entitlements"]["keychain-access-groups"] = ["TESTTEAM.*"]
        result = signing.profile_entitlements(self.profile, "dev.bartosz.Rise", self.sha, self.now)
        self.assertEqual(result["keychain-access-groups"], ["TESTTEAM.dev.bartosz.Rise.webauthn"])
        self.assertEqual(result["com.apple.application-identifier"], "TESTTEAM.dev.bartosz.Rise")
        self.assertTrue(result["com.apple.security.device.camera"] and result["com.apple.security.device.usb"])
        self.assertNotIn(signing.PASSKEY, result, "iCloud Keychain passkeys only with Apple's approval")
        self.assertNotIn("com.apple.security.get-task-allow", result)
        self.profile["Entitlements"][signing.PASSKEY] = True
        self.assertTrue(signing.profile_entitlements(self.profile, "dev.bartosz.Rise", self.sha, self.now)[signing.PASSKEY])
        # A profile whose keychain groups don't cover it claims none.
        self.profile["Entitlements"]["keychain-access-groups"] = ["OTHERTEAM.*"]
        self.assertNotIn("keychain-access-groups", signing.profile_entitlements(self.profile, "dev.bartosz.Rise", self.sha, self.now))

    def testRejectsOtherAppsExpiredProfilesOtherCertificatesAndOtherPlatforms(self):
        changes = [
            ("Entitlements", {**self.profile["Entitlements"], "com.apple.application-identifier": "TESTTEAM.other.app"}),
            ("Entitlements", {**self.profile["Entitlements"], "com.apple.application-identifier": "TESTTEAM.*"}),
            ("ExpirationDate", datetime.datetime(2020, 1, 1)),
            ("DeveloperCertificates", [b"another certificate"]),
            ("Platform", ["iOS"]),
        ]
        for key, value in changes:
            with self.subTest(key=key, value=value):
                profile = copy.deepcopy(self.profile); profile[key] = value
                with self.assertRaises(ValueError):
                    signing.profile_entitlements(profile, "dev.bartosz.Rise", self.sha, self.now)


class LocalIdentityTests(unittest.TestCase):
    def testPrefersADevelopmentIdentityAndFallsBackToAdHoc(self):
        listing = (
            '  1) 2B1DE14C84151F148B532FB126FA3F69231D544A "Apple Development: Test (TEAM)"\n'
            '  2) 353C762A57F47FAF8D1B8DC04484F99B3FDBF2DF "Developer ID Application: Test (TEAM)"\n'
            '  3) 0378CD50D675A3ECCD5C39A78159E47E2D01981B "Apple Development: Test (TEAM)"\n'
            '     3 valid identities found\n')
        self.assertEqual(signing.local_identity(listing), "0378CD50D675A3ECCD5C39A78159E47E2D01981B")
        self.assertEqual(signing.local_identity("     0 valid identities found\n"), "-")
        # A Mac without a development certificate still signs every build the same way.
        self.assertEqual(signing.local_identity(listing.replace("Apple Development", "Apple Distribution")),
                         "353C762A57F47FAF8D1B8DC04484F99B3FDBF2DF")


class CloudKitSigningTests(PasskeySigningTests):
    def setUp(self):
        super().setUp()
        self.profile["Entitlements"].update({
            "com.apple.developer.icloud-services": "*",
            "com.apple.developer.icloud-container-identifiers": [signing.CLOUD_CONTAINER],
            "com.apple.developer.icloud-container-environment": ["Development", "Production"],
            "com.apple.developer.aps-environment": "development",
        })

    def testCloudKitRequiresExplicitContainerAndKeepsOnlyApprovedCapabilities(self):
        result = signing.cloudkit_entitlements(self.profile, "dev.bartosz.Rise", self.sha, self.now)
        self.assertNotIn(signing.PASSKEY, result)
        self.assertNotIn("com.apple.security.get-task-allow", result)
        self.assertEqual(result["com.apple.developer.icloud-services"], ["CloudKit"])
        self.assertEqual(result["com.apple.developer.icloud-container-environment"], "Development")
        for key, value in [
            ("com.apple.developer.icloud-container-identifiers", ["iCloud.other"]),
            ("com.apple.developer.icloud-services", ["CloudDocuments"]),
            ("com.apple.developer.icloud-container-environment", ["Production"]),
            ("com.apple.application-identifier", "TESTTEAM.*"),
        ]:
            with self.subTest(key=key):
                profile = copy.deepcopy(self.profile); profile["Entitlements"][key] = value
                with self.assertRaises(ValueError):
                    signing.cloudkit_entitlements(profile, "dev.bartosz.Rise", self.sha, self.now)


if __name__ == "__main__":
    unittest.main()
