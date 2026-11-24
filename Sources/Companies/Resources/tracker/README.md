# AdGuard companiesdb tracker list

This folder holds data from AdGuard companiesdb (https://github.com/AdguardTeam/companiesdb), which is based on the Whotracks.me database (https://whotracks.me, CC BY 4.0).

Licence: this folder, and only this folder, is under the Creative Commons Attribution-ShareAlike 4.0 International licence (text in `LICENSE`). The rest of Tattle is MIT.

`tracker.tsv` is built by `scripts/build-tracker-list.sh` from a pinned copy. Changes made: only the fields domain, company name and category are kept; company names are trimmed; a tracker with no company whose name is only a domain gets an empty company. The pinned commit and checksums are in `../manifest.json`.

Do not edit `tracker.tsv` by hand.

Before shipping this data in an iOS App Store app, check the licence's rule against adding technical restrictions (DRM).
