# Source review and engineering findings

Checked 2026-09-14. These observations document the inspected responses, not a claim of a supported API contract or a legal opinion.

## Berkeley data source

The public [menus page](https://dining.berkeley.edu/menus/) embeds recipe IDs and base64-encoded XML paths. Its [cal-dining JavaScript](https://dining.berkeley.edu/wp-content/plugins/cal-dining/assets/custom.js) uses WordPress actions `get_recipe_details` and `cald_filter_xml`. The corresponding XML files are directly public, so the adapter fetches those structured exports rather than posting once per recipe.

Verified URLs:

- https://dining.berkeley.edu/wp-content/uploads/menus-exportimport/Crossroads_20260914.xml
- https://dining.berkeley.edu/wp-content/uploads/menus-exportimport/Cafe_3_20260914.xml
- https://dining.berkeley.edu/wp-content/uploads/menus-exportimport/Foothill_20260914.xml
- https://dining.berkeley.edu/wp-content/uploads/menus-exportimport/Clark_Kerr_Campus_20260914.xml

The EatecExchange document identifies hall, service date, source meal name and recipe IDs. A pipe-separated nutrient header maps to each recipe's corresponding values. The importer maps by header name rather than hard-coded column positions. The four feeds contained 540 recipe appearances; identical repeated IDs within a meal collapse to 536 items. Conflicting repeated records fail that hall's import. All four feeds had breakfast, lunch and dinner and omitted late-night/brunch on the observed day.

Serving units in the observed files are `oz`. The API preserves this source string and converts it as mass ounces at 28.349523125 grams/ounce. This is a source-unit interpretation, not an independent weighing. Fluid-volume/count units remain unknown mass. Confirm source-unit semantics with Berkeley before using weight values to calibrate a measurement model. No reference food-photo field was found; icons on the menu represent dietary/allergen information and are not used as food embeddings.

## Robots and linked terms

The direct HTTPS response from [robots.txt](https://dining.berkeley.edu/robots.txt) was HTTP 200 with an empty body on the inspection date. That contains no disallow rule, but is not a license. Every importer run re-checks robots.txt. Denial, 401/403, transient failures after retries, malformed HTML, and redirects fail closed; 404/410 mean no robots file. The adapter does not bypass authentication or access controls.

Reviewed the menu footer's [privacy statement](https://security.berkeley.edu/privacy-statement-uc-berkeley-websites) and the site's [meal-plan terms](https://dining.berkeley.edu/meal-plans/2026-2027/living-off-campus/terms-and-conditions-living-off-campus/). These address privacy and dining-plan use; no explicit public feed redistribution license or supported developer API terms were found in those pages. The footer reserves UC Regents copyright. Production redistribution rights remain unverified; obtain a supported-feed/data-use arrangement before commercial launch. This did not prevent limited public-source development and verification. No one was contacted on your behalf.

## Adjustments to the larger specification

1. Published recipe macros reduce food-identity uncertainty but do not eliminate all nutrition error: preparation and substitutions still matter. API/UI should call them published reference values, not exact measurements of the photographed food.
2. Menus can contain dozens of selectable items, including bars and condiments. The source inspected here exceeds the assumed 5–15 choices. Later classification should use station/context and user preselection to narrow candidates.
3. Missing meal periods are not confirmed closures. The API explicitly represents `not_published`; it does not fabricate a late-night menu.
4. Camera count alone does not establish stereo-depth feasibility. Apple's [AVCaptureMultiCamSession](https://developer.apple.com/documentation/avfoundation/avcapturemulticamsession) provides a runtime support check and requires supported device formats. It does not, by itself, establish calibrated metric stereo from arbitrary rear-camera pairs. Phase C needs a real-device feasibility gate covering synchronized capture, intrinsics/extrinsics, overlap, minimum focus distance and absolute-depth validation. Prefer verified system depth where available; if reliable metric depth cannot be established, narrow the supported-device list rather than promise all dual-camera devices. No per-device baseline table or stereo claim is implemented here.
5. The classical depth/geometry and macro-summing steps are not necessarily ML models. They do not require CoreML conversion merely to conform to a four-stage pipeline. Actual model sourcing/conversion and Nutrition5k suitability must be investigated in their phases, and no on-device validation is claimed from this Windows backend environment.
