# Pipeline Overview
## PC Gaming Golden Era Analytics — End-to-End Analytics Pipeline

A production-style data pipeline built on two Kaggle datasets, demonstrating the full journey from raw relational data to a 5-page business intelligence dashboard answering one central question: **when was the true golden era of PC gaming?**

---

## Pipeline Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        EXTRACT                              │
│                                                             │
│   Kaggle CSV Export (Steam + Metacritic — 2 datasets)       │
│              │                                              │
│              ▼                                              │
│   Google BigQuery (raw ingestion layer)                     │
└─────────────────────────────┬───────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    SEED ENRICHMENT                          │
│                                                             │
│   seed_enrichment   — 337-row manual genre + developer fix  │
│   seed_vr_games     — VR title flags (Steam-derived)        │
└─────────────────────────────┬───────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                       TRANSFORM                             │
│                                                             │
│   BigQuery SQL — 4 reporting queries                        │
│                                                             │
│   Multi-source merge         Deduplication                  │
│   Seed enrichment joins      Genre normalisation            │
│   COALESCE null handling     Min-max normalisation          │
│   Composite index design     Champion ranking logic         │
└─────────────────────────────┬───────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                         LOAD                                │
│                                                             │
│   4 clean reporting tables materialised in BigQuery         │
│   Consistent CTE structure across all queries               │
│   Dashboard-ready analytical output                         │
└─────────────────────────────┬───────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                       VISUALISE                             │
│                                                             │
│   Looker Studio — 5-page PC Gaming Golden Era dashboard     │
└─────────────────────────────────────────────────────────────┘
```

---

## Extract

**Sources:** Two Kaggle datasets ingested as raw BigQuery tables.

| Table | Source | Description |
|-------|--------|-------------|
| `raw_steam_games` | [Steam Games Dataset](https://www.kaggle.com/datasets/fronkongames/steam-games-dataset) | ~85,000 Steam titles — ownership, reviews, genre tags, price |
| `raw_metacritic` | [Metacritic PC Scores](https://www.kaggle.com/datasets/henrylin03/metacritic-games-user-reviews-and-metascores) | Pre-Steam era critic and user scores (1993–2002) |

**Period covered:** 1993–2024
**Format:** CSV → BigQuery raw tables

**Coverage by source:**

| Era | Primary Source |
|-----|---------------|
| 1993–2002 | Metacritic only |
| 2003–2024 | Steam + Metacritic (deduplicated, Steam prioritised) |

---

## Seed Enrichment

A dedicated enrichment layer sits between raw ingestion and transformation. This layer was built to address systematic data quality gaps that could not be resolved through SQL logic alone.

### seed_enrichment
337 manually curated rows covering:
- **Genre overrides** — Metacritic-sourced games carry no native genre field. Seed enrichment assigns genres to the most significant pre-Steam titles, enabling them to appear in genre analysis on Pages 2 and 3.
- **Developer corrections** — Raw developer names contain inconsistencies, abbreviations, and publisher/developer conflation. Corrected names surface cleanly in Page 5 (The Legends table).
- **Stealth reclassifications** — Titles with Action or Adventure tags that are primarily stealth experiences are manually reclassified.
- **Horror additions** — Horror titles that Steam tags under broader categories are manually flagged.
- **VR flags** — A small number of VR titles not captured by `seed_vr_games` are manually flagged via `is_vr = TRUE`.

Joined on game name + release year with a ±1 year tolerance to handle minor dating discrepancies between datasets:
```sql
LEFT JOIN `pc-gaming-golden-era.pc_gaming.seed_enrichment` e
  ON LOWER(TRIM(g.name_raw)) = LOWER(TRIM(e.game_name))
 AND ABS(g.release_year - e.release_year) <= 1
```

### seed_vr_games
Steam-derived VR title identification. Joined on `app_id` to flag VR games independently of their primary genre classification. Powers the VR Champion spotlight on Page 2 and the `is_vr` filter available across all reporting tables.

---

## Transform

All transformation logic lives in BigQuery SQL across 4 reporting queries. Each query follows a consistent CTE architecture ensuring identical enrichment, deduplication, and genre normalisation logic across the entire reporting layer.

### Consistent CTE Architecture

Every reporting query follows this structure:

```
CTE 1 — enriched_games
  Joins seed_enrichment and seed_vr_games to raw staging data.
  Resolves developer, genre, VR flag, and era label.
  Applies critic_score >= 75 gate and 1993–2024 year filter.

CTE 2 — deduped_games
  Deduplicates on normalised game name + release year.
  Steam source prioritised over Metacritic.
  REGEXP_REPLACE strips punctuation before partition to catch near-identical titles.

CTE 2b — genre_normalized_games
  Applies genre consolidation rules after deduplication.
  Massively Multiplayer → MMO
  Action RPG → RPG
  First-Person Shooter → Action
  Excluded tags → NULL

CTE 3+ — [downstream analytical logic per query]
  Query-specific calculations, rankings, and aggregations.
```

### Key Transformation Decisions

**Critic score gates**
Base filter `critic_score >= 75` applied in `enriched_games` across all queries. Genre champion eligibility requires `critic_score >= 80` with a minimum of 3 qualifying games per genre per era — preventing thin-data eras from producing unreliable champions.

**Min-max normalisation (Golden Era Index)**
Each of the 5 index pillars is normalised to 0–100 before weighting:
```sql
SAFE_DIVIDE(
  value - MIN(value) OVER(),
  NULLIF(MAX(value) OVER() - MIN(value) OVER(), 0)
) * 100
```
This ensures no single metric dominates due to scale differences. Volume is additionally log-scaled to prevent Steam-era game counts from overwhelming pre-Steam era quality scores.

**COALESCE waterfall for genre resolution**
Three-level priority cascade resolving genre from seed enrichment → Steam primary tag → first raw genre token → NULL. This minimises ungrouped games while preserving accuracy — seed enrichment overrides always take precedence.

**Deduplication with source priority**
`ROW_NUMBER()` partitioned on normalised game name + release year, ordered Steam first. Ensures each game appears exactly once, with the richer Steam data record retained where both sources exist.

**Champion ranking**
`DENSE_RANK()` used rather than `ROW_NUMBER()` for champion selection — allowing genuine ties to share a rank rather than arbitrarily splitting tied games. Tiebreaker order: `critic_score DESC`, `user_score DESC`, `reviews_total DESC`.

**Nostalgia delta**
Calculated as `user_score - critic_score` at game level in `rpt_game_analysis`. Positive = players rate higher than critics. Negative = critics rate higher than players. Aggregated by era in the dashboard to surface temporal patterns in critic/player divergence.

### SQL Techniques by Query

| Query | Key Techniques |
|-------|---------------|
| `rpt_golden_era_index` | Min-max normalisation, log scaling, composite weighted index, `LAG`, rolling 3-year average (`ROWS BETWEEN`), `DENSE_RANK`, `SAFE_DIVIDE` |
| `rpt_hall_of_kings` | Multi-seed enrichment joins, `DENSE_RANK` champion ranking, `COALESCE` waterfall, VR and genre champion sub-CTEs, era sort order |
| `rpt_genre_golden_eras` | Genre quality index, `LAG` for YoY deltas, `FIRST_VALUE` peak year identification, `STRING_AGG` top-3 game strings, minimum game count gate |
| `rpt_game_analysis` | Age bucket classification, nostalgia delta calculation, longevity tier, ownership tier, `CASE` multi-label assignment |

---

## Load

Transformed query outputs are materialised as clean analytical tables in BigQuery using **Create or Replace Table** — overwriting on each run to ensure the dashboard always reflects the latest transformation logic.

| Table | Grain | Rows (approx) | Powers |
|-------|-------|---------------|--------|
| `rpt_golden_era_index` | One row per year | 32 | Page 1 |
| `rpt_hall_of_kings` | One row per qualifying game | ~3,100 | Page 2 |
| `rpt_genre_golden_eras` | One row per genre per year | ~250 | Page 3 |
| `rpt_game_analysis` | One row per qualifying game | ~3,100 | Pages 4 & 5 |

All tables apply the `critic_score >= 75` base filter. `rpt_hall_of_kings` and `rpt_game_analysis` share the same game-level grain and base population — they diverge in the downstream columns they calculate and expose.

---

## Visualise

A single Looker Studio report consumes all four reporting tables via live BigQuery connector.

| Page | Title | Source Table | Central Question |
|------|-------|-------------|-----------------|
| 1 | The Golden Era Index | `rpt_golden_era_index` | When was the best year in PC gaming history? |
| 2 | Hall of Kings | `rpt_hall_of_kings` | Who are the greatest PC games of each era? |
| 3 | Genre Golden Eras | `rpt_genre_golden_eras` | When did each genre peak? |
| 4 | Timeless or Trendy? | `rpt_game_analysis` | Do older games score higher? Do critics and players agree? |
| 5 | The Legends | `rpt_game_analysis` | Every great game (80+), remembered |

**Design decisions:**
- Dark charcoal canvas (`#1C1C1E`) with orange accent palette (`#FF6B2B`)
- Spacious single-page layouts — one or two hero visuals per page, no clutter
- Chart types chosen for narrative fit: treemap for era champions, heatmap for genre quality, bubble chart for survivorship analysis, horizontal bar for divergence
- Stealth and VR surfaced as spotlight scorecards on Page 2 rather than independent pages — volume too sparse for standalone treatment

---

## Repository Structure

```
/
├── README.md                        ← Project overview and key findings
├── data_model.md                    ← Schema, table descriptions, transformation decisions
├── pipeline_overview.md             ← ETL architecture (this document)
├── conclusions.md                   ← Analytical findings and data story
├── dashboard/
│   └── pc_gaming_golden_era.pdf     ← Dashboard export (static preview)
└── queries/
    ├── rpt_golden_era_index.sql
    ├── rpt_hall_of_kings.sql
    ├── rpt_genre_golden_eras.sql
    └── rpt_game_analysis.sql
```

---

*Dataset sources:*
*Steam: [Kaggle — fronkongames](https://www.kaggle.com/datasets/fronkongames/steam-games-dataset)*
*Metacritic: [Kaggle — henrylin03](https://www.kaggle.com/datasets/henrylin03/metacritic-games-user-reviews-and-metascores)*
*Tools: Google BigQuery · Looker Studio · Google Cloud Platform*
