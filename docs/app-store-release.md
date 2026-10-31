# Time Breaker Mac App Store Release Guide

Date: 2026-10-31

Status: the project is prepared for Mac App Store submission, but nothing has been signed for distribution, registered with Apple, or uploaded. Those steps need a paid Apple Developer Program membership. A free Personal Team can build, run, and test the app, including tips through the local StoreKit configuration, but it can't create App Store Connect records, sell in-app purchases, or distribute.

This guide lists what the project already provides, what can be done before enrolling, and the steps to take after enrolling, in order.

## 1. What the project provides

| Requirement | Where |
| --- | --- |
| App Sandbox with minimal entitlements: user-selected files, read-only; no network | `TimeBreaker/TimeBreaker.entitlements` |
| Privacy manifest: no tracking, no collected data, `UserDefaults` accessed for reason `CA92.1` | `TimeBreaker/Resources/PrivacyInfo.xcprivacy` |
| Export compliance: `ITSAppUsesNonExemptEncryption = NO`, so uploads skip the encryption question | Target build settings |
| Category `public.app-category.healthcare-fitness` | Target build settings |
| Version 1.0, build 1 | `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` |
| Copyright “Copyright © 2026 ipfans. All rights reserved.” Change it if the seller name differs. | `INFOPLIST_KEY_NSHumanReadableCopyright` |
| App icon, including the 1024-pixel size | `TimeBreaker/Resources/Assets.xcassets/AppIcon.appiconset` |
| Optional tips: three consumable in-app purchases that unlock nothing | `TimeBreaker/Store/TipJar.swift`; Settings → Support |
| Local StoreKit configuration for the Run action and the tests | `TimeBreaker/TimeBreaker.storekit` (not copied into the app) |
| Automatic signing. Without a team, builds sign to run locally. | Project build settings |
| Archive, export, and upload script | `scripts/archive-app-store.sh` |
| Privacy policy draft | [privacy-policy.md](privacy-policy.md) |

The build is `arm64` only, as decided in the [implementation plan](implementation-plan.md). Intel Macs that run macOS 26 can't install it. After the first upload, confirm that the App Store listing shows the Apple silicon requirement.

### How tips work

The Support tab loads the three products only when it is shown. Tip names follow the app's language setting and come from the app's string catalog; prices always come from the App Store. The purchase sheet attaches to the Settings window. On macOS, `Product.purchase()` without a window fails with `invalidPresentationContext`.

Each transaction is finished as soon as it arrives. A listener started at launch finishes transactions that complete outside a purchase in progress, such as approved Ask to Buy requests or purchases interrupted by quitting. Consumable tips don't need a Restore Purchases button.

| Product ID | Type | Local test price |
| --- | --- | --- |
| `com.acgso.timebreaker.tip.small` | Consumable | $0.99 |
| `com.acgso.timebreaker.tip.medium` | Consumable | $2.99 |
| `com.acgso.timebreaker.tip.large` | Consumable | $4.99 |

The product IDs must match in three places: App Store Connect, `TipJar.Tier`, and `TimeBreaker.storekit`. The local prices only affect testing. Real prices are set in App Store Connect.

## 2. Before enrolling

These steps work with a free account.

- **Test tips locally.** Run the app from Xcode. The shared scheme's Run action uses `TimeBreaker.storekit`. Open Settings → Support and buy each tip. Use **Debug → StoreKit → Manage Transactions** to inspect, approve, or delete transactions. To test Ask to Buy or StoreKit errors, open `TimeBreaker.storekit` and turn them on from Xcode's Editor menu.
- **Run the automated tests.** The Tip jar suite loads products from the same configuration through `SKTestSession` and needs no account (see the README). It doesn't make purchases, so test purchases from Xcode as above.
- **Host the privacy policy.** Fill in the contact line in [privacy-policy.md](privacy-policy.md) and publish it at a stable URL, for example with GitHub Pages. App Store Connect requires a privacy policy URL and a support URL for every app.
- **Prepare the listing.** Write the description, keywords, promotional text, and support URL. Take at least one Mac screenshot at a 16:10 size: 1280 × 800, 1440 × 900, 2560 × 1600, or 2880 × 1800. Screenshots of a break overlay and of Settings show the app's main features.
- **Choose tip prices.**
- **Finish release qualification.** Do the manual checks listed in the [validation report](validation-report.md), including testing on macOS 26.

## 3. After enrolling

1. **Find the paid team.** In Xcode → Settings → Accounts, the paid team appears separately from “(Personal Team)” and has its own team ID. Use the paid team. Personal Team IDs can't distribute.
2. **Choose signing.** Either pass the team to the script (step 9), or set it once in Xcode. To set it in Xcode, select the TimeBreaker target → Signing & Capabilities, set **Team** to the paid team, and set **Signing Certificate** to **Development**, not Sign to Run Locally. Xcode writes `DEVELOPMENT_TEAM` into `project.pbxproj`. A team ID isn't secret, so it can be committed.
3. **Register the bundle ID** `com.acgso.timebreaker`. Automatic signing registers it on the first archive, or you can register it in Certificates, Identifiers & Profiles. Bundle IDs are unique across all developers. If this one is taken, change `PRODUCT_BUNDLE_IDENTIFIER`, the IDs in `TipJar.Tier`, and `TimeBreaker.storekit` together. The README's container path and log subsystem also use the bundle ID.
4. **Sign the Paid Applications Agreement.** Do this in App Store Connect → Business, then complete tax and banking. In-app purchases need it even though the app is free.
5. **Create the app record.** Go to My Apps → + → New App. Choose platform macOS, a name (“Time Breaker” may be taken), primary language English (U.S.), the bundle ID, and an SKU such as `timebreaker-mac`.
6. **Create the three in-app purchases.** Go to Monetization → In-App Purchases. Create each one as **Consumable**, using the product IDs in section 1. Add a reference name, a price, and a display name and description for at least English. The app's other seven languages can be added too. Keep the display names consistent with the app: Small Tip, Medium Tip, Large Tip. Each needs a review screenshot of Settings → Support.
7. **Fill in the app information.**
   - Primary category: Health & Fitness, which matches `LSApplicationCategoryType`.
   - Age rating questionnaire, privacy policy URL, and support URL.
   - App Privacy: **Data Not Collected**. The app collects nothing, and Apple processes purchases.
8. **Set pricing and availability.** Choose Free and the territories.
9. **Archive and upload.** Every upload needs a build number higher than the last one.

   ```sh
   TEAM_ID=<paid team ID> BUILD_NUMBER=1 scripts/archive-app-store.sh          # signed .pkg in build/AppStore/Export
   TEAM_ID=<paid team ID> BUILD_NUMBER=1 scripts/archive-app-store.sh upload   # upload to App Store Connect
   ```

   Alternatively, in Xcode choose Product → Archive, then Distribute App → App Store Connect.
10. **Test with TestFlight.** Install the build through TestFlight for Mac, where purchases are free. Check that:
    - all three tips load with prices;
    - the purchase sheet appears over Settings;
    - the thank-you message appears after a purchase.

    This is also the first test of StoreKit against the real App Store from inside the sandbox. The app has no network entitlement, which is expected to work because StoreKit runs outside the app's process. If tips fail to load here, the next thing to check is `com.apple.security.network.client`.
11. **Submit.** On the version page:
    - select the build;
    - add the three in-app purchases under **In-App Purchases and Subscriptions**, since the first in-app purchases must be submitted with an app version;
    - paste the review notes below;
    - submit for review.

## 4. App Review notes

```text
Time Breaker is a menu bar app and has no Dock icon. Click the cup icon in the menu bar to open its menu.

To see a break right away, choose "Take Short Break Now" from the menu. The break covers every display. "Pause" and "Quit" are always available on the break screen, and "Skip" is available unless it is turned off in Settings.

Optional tips are in Settings… → Support. The three tips are consumable in-app purchases that don't unlock any features.

"Open at login" is off by default and can only be turned on in Settings → General. The app needs no account, network access, or special permissions.
```

## 5. Review guidelines considered

| Guideline | How the app meets it |
| --- | --- |
| 2.4.5(i): Mac apps must be sandboxed | App Sandbox is on, with only user-selected read-only file access. |
| 2.4.5(iii): no automatic launch without consent | Launch at login is off until the user turns it on, through `SMAppService`. |
| 3.1.1: digital purchases use in-app purchase | Tips use StoreKit. They are labeled as optional and unlock nothing. |
| 5.1.1: privacy policy | The policy draft is ready to host; the privacy manifest declares no collection. |
| 2.3: accurate metadata | Screenshots and the description must show the shipping app. |

## 6. Not yet verified

- Distribution signing, export, and upload. They need the paid team. The script passes `shellcheck` and its export options are valid, but only the archive step was run, signed to run locally.
- Purchases against the real App Store, including from inside the sandbox without a network entitlement.
- Purchases under the bundle ID `com.acgso.timebreaker`. The automated tests don't make purchases. Purchases made against an offscreen window passed under the previous bundle ID, and the purchase sheet in the running app has never been exercised.
- The App Store listing's Apple silicon requirement.
