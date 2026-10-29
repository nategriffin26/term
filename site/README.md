# site

Term's public support site: static HTML and one stylesheet, no build step. Preview by opening `index.html`, or run `python3 -m http.server` in this folder and visit `http://localhost:8000`.

Before publishing, replace every placeholder below and resolve every `<!-- CONFIRM: ... -->` comment (`grep -rn CONFIRM site`).

| Placeholder | Where | What |
| --- | --- | --- |
| `APP_STORE_URL` | index | App Store link |
| `REPO_URL` | all pages | GitHub repository URL (also builds `/issues` and `/blob/main/LICENSE`) |
| `SUPPORT_EMAIL` | privacy, support | support address (also in `mailto:` links) |
| `EFFECTIVE_DATE` | privacy | policy's effective date |
| `COUNTER_SWITCH` | privacy | where the daily count's off switch sits in Settings |
| `PRO_FEATURES` | faq | what Pro adds; the paywall is not decided |
| `PRICE_MONTHLY`, `PRICE_YEARLY`, `PRICE_LIFETIME` | faq | prices |
| `RESTORE_PURCHASES_STEPS` | support | where Restore Purchases is in the app |
| `HOST_KIT_INSTALL_COMMAND` | setup | the `term-host` install one-liner |
| `SCREEN_HOST_DOWNLOAD_URL` | setup | the notarized Term Screen Host download |

The privacy policy's push and daily-count sections follow the push-relay branch (`relay/src/contract.ts`, `relay/src/index.ts`, `integrations/notify`) as of commit 36b4f48. Nothing there has shipped, and the app side of both (asking before the first count, the off switch) is not built; the `CONFIRM` comments name what to recheck.
