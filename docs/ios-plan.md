# Mill House: iOS app plan

Status: decided 2026-11-23, not started. Development happens on the Mac mini (dwkns-mini, `~/Developer/mill-house`), which has Xcode.

Naming: the project is **Mill House** (repo, Xcode project, bundle id, code). The public name stays
**Christmas Shopping** for now (Home Screen name "Xmas List"); it will change later.

## Decisions

| Topic | Decision |
|---|---|
| Platform | Native iOS app (SwiftUI). Everyone uses an iPhone; no Android. |
| Backend | Keep Netlify. The iOS app uses the same API as the web app, so both share one list. |
| Web app | Stays live while people move to the iOS app. Long term the project is iOS only. The Netlify URL stays `christmas-shopping-uovm.netlify.app` (renaming it would break installed web apps). |
| Distribution | Ad hoc + over-the-air updates, the same way as `dwkns/lifts` (no TestFlight). |
| Version 1 scope | Feature parity with the web app, plus "live notifications when items are due" (see Open questions). |

## Follow the Lifts conventions

Copy the setup from `dwkns/lifts` (on the mini: `~/Developer/lifts`) rather than inventing a new one:

- `ios/project.yml` for XcodeGen. Team `LD2427W529`, `bundleIdPrefix: com.dwkns`, iOS 17, `CODE_SIGN_STYLE: Automatic`.
  Project and target name: `MillHouse`. Bundle id: `com.dwkns.millhouse`. Display name (public, for now): `Xmas List`.
- One version number (`MARKETING_VERSION` = `CURRENT_PROJECT_VERSION`), bumped by the release script.
- Scripts adapted from Lifts: `scripts/secrets.sh` (App Store Connect API key from 1Password, "Lift - Apple"),
  `scripts/add-device.sh` (register a phone UDID), `scripts/ship-ios.sh` (build and install on a paired phone),
  `scripts/release-ios.sh` (build an IPA and publish it for over-the-air install).
- Over-the-air install needs an HTTPS `manifest.plist` and the IPA. Host both on Netlify: store the IPA in a Netlify
  Blobs store and serve it, the manifest and a small install page from a function (for example `/updates/*`).
- A `Makefile` with the same target names (`ship`, `release`, `test-ios`, `lint`).
- Optional: register the mini as a self-hosted GitHub Actions runner for this repo, like Lifts' `ios.yml`.

## Backend contract (already live)

Base URL: `https://christmas-shopping-uovm.netlify.app`

### `GET /api/items`

Returns `{ "items": [Item], "now": <ms> }`. Includes tombstones (`{ id, deleted: true, updatedAt }`).

### `POST /api/items`

Body `{ "changes": [Item], "actor": "<my name>" }`. For each item the newest `updatedAt` wins; the response returns
what the server kept, `{ "items": [Item] }`. Send deletions as `{ id, deleted: true, updatedAt }`.

Item fields (all strings unless noted):

| Field | Shopping | To-do | Notes |
|---|---|---|---|
| `id` | ✓ | ✓ | 6–64 chars, `[A-Za-z0-9_-]` |
| `type` | `""` | `"todo"` | |
| `name` | ✓ | ✓ | item or task text |
| `qty` | ✓ | | optional |
| `day` | ✓ | | `Fri`, `Sat`, `Sun`, `All` (old items may have `Thu`, `Multiple` = All) |
| `meal` | ✓ | | `Breakfast`, `Lunch`, `Dinner`, `Snacks` or `""` |
| `done` | ✓ | ✓ | boolean (bought / done) |
| `by`, `color` | ✓ | ✓ | who added it; colour `#RRGGBB` |
| `assignee`, `assigneeColor` | | ✓ | `""` means Anyone |
| `due` | | ✓ | `YYYY-MM-DD` or `""` |
| `createdAt`, `updatedAt` | ✓ | ✓ | numbers, ms since epoch |

Sync rules used by the web app (keep the same): local store is the offline source of truth; queue changes in an
outbox; POST the outbox, then GET everything and merge by `updatedAt`; poll every ~8 s while open.

### `POST /api/aisles`

Body `{ "names": ["turkey", ...] }` (lower-cased, trimmed). Returns `{ "aisles": { "turkey": "Meat & Poultry" } }`.
Claude sorts unknown names; answers are cached per name. Aisle order is the `AISLES` list in `public/app.js`.

### Notifications today (web push)

`netlify/functions/push.mjs`, `netlify/lib/push.mjs`, and the daily `netlify/functions/reminders.mjs` (08:00 UTC).
Events: someone else adds shopping; a to-do is assigned to you; to-dos due today or overdue.

## Work to do

1. **Backend: APNs.** Add a device-token endpoint (for example `POST /api/apns` with `{ token, name }`, stored in a
   blob store) and send the same three events through APNs as well as web push. Needs an APNs auth key (.p8) from the
   developer account; store key id, team id and key in Netlify environment variables (keep under the ~4 KB total).
2. **iOS app, version 1:** Shopping (All / Day / Meal / Aisle), To-do (Everyone / Mine; Overdue, Today, Tomorrow,
   Later, No Date, Done), Settings (name, colour, notifications, clear bought / done). Offline store, outbox sync,
   pull to refresh, swipe to delete, coloured person dots, version number shown in the app.
3. **Due notifications** (see Open questions).
4. **Distribution:** adapt the Lifts scripts; host the IPA and manifest on Netlify; register the family's phones.

## Open questions for the user

- "Live notifications when items are due": local notifications scheduled on the phone at the due time, a Live
  Activity / lock-screen countdown, or both? A due *time* (not only a date) would be needed for anything beyond a
  morning reminder.
- App icon: reuse the web icon (`public/icons/icon.svg`) or a new design?
