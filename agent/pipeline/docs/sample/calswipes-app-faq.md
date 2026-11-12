title: CalSwipes app FAQ (sample)
source_url: sample://calswipes-app-faq
sample: true
---
> SAMPLE TEXT written for the CalSwipes Agent demo. It is NOT official Berkeley Dining text. Replace it by running `python -m pipeline.fetch_docs`.

## When menus update

The CalSwipes backend imports the next day's menus every night at 10:00 PM Pacific time, so tomorrow's menu is ready when the app rolls over. A freshness monitor checks every 15 minutes.

## Stale menus

If a menu has not been refreshed within 36 hours, the API refuses to serve it and returns a menu_stale error instead of showing old data.

## Where the data comes from

All menu, nutrition, allergen, and dietary data comes from the public Berkeley Dining menu feed.
