title: How nutrition numbers are published (sample)
source_url: sample://nutrition-data
sample: true
---
> SAMPLE TEXT written for the CalSwipes Agent demo. It is NOT official Berkeley Dining text. Replace it by running `python -m pipeline.fetch_docs`.

## Approved nutrition only

Berkeley Dining marks each recipe as having approved nutrition or not. CalSwipes only shows calories, protein, carbohydrates, and fat when nutrition is approved and all four values are present. Otherwise the item is shown as nutrition unavailable, and its numbers are never estimated.

## Serving sizes

Serving sizes come from the feed, usually in ounces. CalSwipes converts ounces to grams using 28.35 grams per ounce. Macros are per one listed serving, so two servings means double the numbers.

## Accuracy

Nutrition values are calculated from standard recipes. What lands on your plate can differ because portion sizes vary when food is served by hand.
