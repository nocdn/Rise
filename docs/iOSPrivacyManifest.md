# iOS required-reason API declarations

`Apps/iOS/Rise/PrivacyInfo.xcprivacy` is included in the app's resources by the
Xcode project's synchronized `Rise` group. It declares these required-reason APIs:

| Category | Reason | Use |
| --- | --- | --- |
| User defaults | `CA92.1` | Read/write Rise's own preferences for AI, protections, autoplay, and iCloud tab sync. |
| File timestamps | `C617.1` | Read file sizes for downloads and modification dates for summary-cache eviction, within the app's container. |
| System boot time | `35F9.1` | Measure elapsed download progress samples and local timer/animation intervals. |

Download throughput is derived from successive `systemUptime` samples. The raw
uptime samples remain on the device. File metadata is used for local UI and cache
management. These APIs are not used to fingerprint users or devices.

The Downloads widget's own source and its shared activity code do not directly use
any required-reason APIs. It therefore does not inherit the app's declarations.
Recheck its own bundle if that changes.

This manifest's required-reason declarations are separate from App Store Connect's
privacy labels, the published privacy policy, and consent for sending page content
to a selected AI provider; they do not assert that no data leaves the device.

Source: [Apple's required-reason API categories and approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
