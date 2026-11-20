# Christmas Shopping

A shared Christmas shopping list. Anyone with the link can add, edit and delete items.

- Static app in `public/` (HTML, CSS, vanilla JS). No build step.
- `netlify/functions/items.mjs` stores each item as one Netlify Blob (`shopping-items` store).
- Works offline: the service worker caches the app; `localStorage` holds the list and a queue of unsent changes, which upload when the device is back online.
- Conflicts: the change with the newest `updatedAt` wins, per item.

## Develop

```bash
npm install
npx netlify dev
```
