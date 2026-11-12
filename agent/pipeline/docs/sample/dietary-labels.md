title: Dietary labels on menu items (sample)
source_url: sample://dietary-labels
sample: true
---
> SAMPLE TEXT written for the CalSwipes Agent demo. It is NOT official Berkeley Dining text. Replace it by running `python -m pipeline.fetch_docs`.

## The four dietary labels

The menu feed can tag an item with four dietary labels: Vegan Option, Vegetarian Option, Halal, and Kosher. A label is either present or absent for each item.

## What the labels do not tell you

A Vegetarian Option label means the recipe is vegetarian. It does not mean the item was cooked on separate equipment. Labels are sometimes missing from items that clearly qualify, such as plain tofu dishes, so an absent label does not prove an item is not vegan.

## How CalSwipes uses them

CalSwipes treats a dietary label as a hard filter when you set a dietary preference, and it can also infer obvious plant-based items by name. The nutrition agent only recommends items that pass your allergen and dietary filters.
