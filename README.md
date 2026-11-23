# Christmas Shopping

A shared Christmas shopping list. Anyone with the link can add, edit and delete items.

- Static app in `public/` (HTML, CSS, vanilla JS). No build step.
- `netlify/functions/items.mjs` stores each item as one Netlify Blob (`shopping-items` store).
- Works offline: the service worker caches the app; `localStorage` holds the list and a queue of unsent changes, which upload when the device is back online.
- Conflicts: the change with the newest `updatedAt` wins, per item.

## To-dos and notifications

- To-dos are items with `type: "todo"`, plus `assignee` and an optional `due` date.
- `netlify/functions/push.mjs` stores Web Push subscriptions (blob store `push-subs`).
- `netlify/functions/items.mjs` notifies other people when shopping is added or a to-do is assigned.
- `netlify/functions/reminders.mjs` runs daily at 08:00 UTC and reminds people about to-dos due today or overdue.
- Needs the environment variables `VAPID_PUBLIC_KEY` and `VAPID_PRIVATE_KEY` (generate with `npx web-push generate-vapid-keys`).
- On iPhone, notifications work only in the Home Screen app (iOS 16.4 or later).

## Develop

```bash
npm install
npx netlify dev
```
