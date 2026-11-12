# Tray scanner evals

There is **no labeled photo set in this repo yet**, and no fake or generated photos are being passed off as real. The offline tests use `StubVision`, which never looks at the image. They check the plumbing (candidate loading, schema, server-side validation, errors, cost logging), not recognition accuracy.

This folder describes how to build a real set from CalSwipes users' own confirmations, and `score_scan.py` scores the scanner on it once it exists.

## Building the labeled set from user confirmations

1. **Ask for consent in the app.** Add an opt-in toggle ("Help improve tray scanning by saving my scan photos"). Default off. Only photos from users who opted in are kept. Say how long photos are stored and how to delete them, and update the privacy policy on the CalSwipes website before shipping.
2. **Collect the label at the moment it's free.** After `POST /v1/scan` returns matches, the user already confirms, removes or adds items before logging the meal. That final list is the label. Store one record per confirmed scan:
   ```json
   {"photo": "gs://<bucket>/scans/2026-11-20/ab12.jpg", "hall": "crossroads", "meal": "lunch",
    "date": "2026-11-20", "predicted": ["556", "981"], "confirmed": ["556", "1204"], "app_version": "1.4.0"}
   ```
   The existing backend endpoint `/v1/log-correction` already logs per-item corrections. Extend it, or add a new endpoint that takes the whole confirmed list.
3. **Store photos privately.** Use a GCS bucket with no public access and a lifecycle rule (for example, delete after 180 days). Strip EXIF/location data before upload. Never put photos in git.
4. **Review a sample by hand.** Users skip corrections when they're in a hurry, so confirmed lists are noisy. Before using a record for evals, check it against the photo. Start with 100-200 reviewed scans spread across halls and meals.
5. **Freeze a test split.** Put reviewed records in `labels.jsonl` (kept out of git if it points at private photos). Don't tune prompts on the test split.

## Scoring

```bash
cd agent
python -m evals.scan.score_scan --labels path/to/labels.jsonl              # re-runs the scanner on each photo
python -m evals.scan.score_scan --labels path/to/labels.jsonl --use-logged # scores the stored predictions
```

It reports micro precision/recall/F1 over menu item ids, exact-match rate (the whole tray right), off-menu drops, and p50/p95 latency, and writes `scan-report.md`. Photos are read from local paths. Download `gs://` photos first with `gcloud storage cp`.
