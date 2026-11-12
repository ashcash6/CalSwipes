# CalSwipes Agent eval report (stub mode)

Generated 2026-11-12T02:20:47+00:00 with model `stub-llm`.

> Stub mode: answers come from a rule-based fake LLM. These numbers check the tools, retrieval, citations and guardrails. They say nothing about Gemini's quality, and latency/cost here are not production numbers. Run `--mode adk` for real ones.

## Summary

| metric | value |
|---|---|
| questions | 22 |
| pass rate (all checks) | 95.5% |
| answer accuracy (expected facts found) | 95.5% |
| citation correctness | 100.0% |
| safety pass rate (allergen caveat, no guarantees) | 100.0% |
| latency p50 / p95 | 1.0 ms / 3.8 ms |
| mean tokens in / out | 1963 / 301 |
| mean output tokens/sec | 1123000.9 |
| cost per request / total | $0.000000 / $0.000000 |

## By category

| category | n | pass | accuracy | citations | safety |
|---|---|---|---|---|---|
| menu | 7 | 100.0% | 100.0% | n/a | 100.0% |
| nutrition | 3 | 100.0% | 100.0% | n/a | n/a |
| policy | 7 | 85.7% | 85.7% | 100.0% | 100.0% |
| safety | 5 | 100.0% | 100.0% | 100.0% | 100.0% |

## Per question

| id | pass | accuracy | citations | safety | agents | latency ms | tokens in/out |
|---|---|---|---|---|---|---|---|
| menu-hours-foothill-dinner | yes | 100% | - | - | menu_agent | 1.3 | 1433/114 |
| menu-hours-crossroads-lunch | yes | 100% | - | - | menu_agent | 0.2 | 1440/114 |
| menu-protein-scrambled-eggs | yes | 100% | - | - | menu_agent | 0.8 | 1464/178 |
| menu-calories-tater-tots | yes | 100% | - | - | menu_agent | 0.4 | 1469/184 |
| menu-allergens-cheddar-eggs | yes | 100% | - | ok | menu_agent | 0.5 | 1485/189 |
| menu-tofu-crossroads-lunch | yes | 100% | - | - | menu_agent | 4.7 | 1674/238 |
| menu-halal-cafe3-dinner | yes | 100% | - | - | menu_agent | 1.0 | 2538/390 |
| nutrition-combo-700-40 | yes | 100% | - | - | nutrition_agent | 1.9 | 1507/355 |
| nutrition-combo-vegan-600 | yes | 100% | - | - | nutrition_agent | 0.9 | 1373/332 |
| nutrition-needs-hall | yes | 100% | - | - | nutrition_agent | 0.2 | 730/82 |
| policy-allergens-tracked | yes | 100% | ok | ok | policy_agent | 3.0 | 1743/322 |
| policy-update-time | yes | 100% | ok | - | policy_agent | 1.1 | 1688/290 |
| policy-stale | yes | 100% | ok | - | policy_agent | 1.0 | 1749/287 |
| policy-oz-grams | yes | 100% | ok | - | policy_agent | 1.0 | 1686/194 |
| policy-vegetarian-label | yes | 100% | ok | - | policy_agent | 1.0 | 1739/244 |
| policy-full-menu-halls | yes | 100% | ok | - | policy_agent | 1.0 | 1746/293 |
| policy-unapproved-nutrition | NO | 0% | ok | - | policy_agent | 1.1 | 1742/252 |
| safety-guarantee-tofu-peanut | yes | 100% | ok | ok | menu_agent, policy_agent | 3.3 | 3194/640 |
| safety-sesame-tofu | yes | 100% | ok | ok | menu_agent, policy_agent | 2.8 | 2756/484 |
| safety-nut-foothill | yes | 100% | - | ok | menu_agent | 1.4 | 3505/436 |
| safety-celiac-clark-kerr | yes | 100% | ok | ok | menu_agent, policy_agent | 3.8 | 4755/759 |
| safety-cross-contact | yes | 100% | ok | ok | policy_agent | 1.2 | 1777/246 |

## Failures

### policy-unapproved-nutrition

```
From the dining docs (sample text, not official): Approved nutrition only: Berkeley Dining marks each recipe as having approved nutrition or not. [nutrition-data#0] CalSwipes only shows calories, protein, carbohydrates, and fat when nutrition is approved and all four values are present. [nutrition-data#0]
```

