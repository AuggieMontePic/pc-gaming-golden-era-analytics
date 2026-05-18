# Data Model
## PC Gaming Golden Era Analytics — BigQuery Pipeline

---

## Overview

This document describes the data model, transformation decisions, seed enrichment logic, and known data characteristics behind the PC Gaming Golden Era Analytics project. The source data combines two Kaggle datasets — a Steam games dataset and a Metacritic PC scores dataset — covering PC gaming history from 1993 to 2024.

The pipeline follows a classic **Extract → Transform → Load → Visualise** structure:

| Stage | Tool | Description |
|-------|------|-------------|
| **Extract** | Kaggle / CSV | Raw CSVs ingested into Google BigQuery |
| **Transform** | BigQuery SQL | Cleaning, deduplication, enrichment, index calculation |
| **Load** | BigQuery | Clean analytical tables ready for BI consumption |
| **Visualise** | Looker Studio | 5-page interactive dashboard |

---

## Schema Diagram

The pipeline uses 6 tables across 3 layers: raw ingestion, seed enrichment, staging, and reporting.

```
RAW LAYER
├── raw_steam_games          ← Steam dataset (~85K titles)
└── raw_metacritic           ← Metacritic PC scores (pre-Steam era)

SEED LAYER
├── seed_enrichment          ← 337-row manual enrichment table
└── seed_vr_games            ← VR title flags (Steam-derived)

STAGING LAYER
└── stg_pc_games             ← Unified, deduplicated, cleaned game table

REPORTING LAYER
├── rpt_golden_era_index     ← Annual composite index (Page 1)
├── rpt_hall_of_kings        ← Era and genre champions (Page 2)
├── rpt_genre_golden_eras    ← Genre quality timelines (Page 3)
└── rpt_game_analysis        ← Game-level longevity and nostalgia (Pages 4 & 5)
```

---

## Table Descriptions

### Raw Layer

#### `raw_steam_games`
Steam games dataset ingested directly from Kaggle CSV. Contains ~85,000 titles with ownership estimates, review counts, review ratios, price, and genre tags. Known issue: column misalignment in the raw CSV caused `avg_playtime_hrs` to ingest as NULL across all rows — documented under Data Quality below.

#### `raw_metacritic`
Metacritic PC scores dataset. Covers the pre-Steam era (1993–2002) with critic scores and user scores. This is the primary source for Golden Age, Pre-Steam Peak, and Birth of 3D era coverage where Steam data does not exist.

---

### Seed Layer

#### `seed_enrichment`
A 337-row manually curated enrichment table. Built to address systematic data quality gaps in the raw sources — primarily Metacritic-sourced games which carry no native developer or genre fields.

| Column | Purpose |
|--------|---------|
| `game_name` | Match key — joined on name + release year (±1 year tolerance) |
| `release_year` | Match key |
| `developer_clean` | Corrected developer name |
| `genre_clean` | Manually assigned genre (overrides raw genre) |
| `is_vr` | Manual VR flag for titles not captured by seed_vr_games |

Join logic uses fuzzy matching to handle minor title variations:
```sql
ON LOWER(TRIM(g.name_raw)) = LOWER(TRIM(e.game_name))
AND ABS(g.release_year - e.release_year) <= 1
```

#### `seed_vr_games`
Steam-derived VR title identification table. Joined on `app_id` to flag VR games independently of their primary genre classification. Used to surface VR champions separately from the main genre analysis on Page 2.

---

### Staging Layer

#### `stg_pc_games`
The unified, deduplicated, cleaned game table. This is the single source of truth for all four reporting queries. Key transformation decisions applied at this layer:

- Multi-source merge: Steam and Metacritic unified under a common schema
- Deduplication: one row per game, Steam source prioritised over Metacritic where both exist
- Critic score gate: only games with a valid `critic_score` are included
- Coverage period: 1993–2024

**Grain:** one row per unique PC game title.

---

### Reporting Layer

All four reporting tables share a consistent CTE structure:

```
enriched_games
    → deduped_games
        → genre_normalized_games
            → [downstream analytical logic]
```

This ensures enrichment, deduplication, and genre normalisation are applied identically across all four queries — no divergence in base logic between pages.

#### `rpt_golden_era_index`
Annual composite Golden Era Index score. One row per year (1993–2024). Powers Page 1.

Built from 5 normalised pillars, each scaled 0–100 via min-max normalisation before weighting:

| Pillar | Weight | Metric | Rationale |
|--------|--------|--------|-----------|
| Quality threshold rate | 30% | % games scoring 80+ | Best signal of a genuinely great year |
| Average critic score | 25% | Mean critic score | Overall quality floor |
| Genre diversity | 20% | Distinct genres | Breadth of creative output |
| Volume | 15% | Scored game count (log-scaled) | How much quality, not just peak quality |
| Longevity | 10% | Avg playtime hours | Quality proxy — great games get played |

Volume is log-scaled (`LN(scored_games + 1)`) to prevent the Steam era's massive game counts from dominating the index over the pre-Steam era's smaller but higher-quality output.

**Grain:** one row per year.

#### `rpt_hall_of_kings`
Era champions and genre champions per era. Powers Page 2.

Champion selection logic:
- **Era champion:** highest `critic_score` per era. Tiebreaker: `user_score DESC`, `reviews_total DESC`.
- **Genre era champion:** highest `critic_score` per genre per era. Requires `critic_score >= 80` AND at least 3 qualifying games in that genre-era combination.
- **VR champion:** highest `critic_score` among `is_vr = TRUE` games per era.

**Grain:** one row per qualifying PC game (critic_score ≥ 75).

#### `rpt_genre_golden_eras`
Genre-level quality timelines. Powers Page 3.

Aggregates quality metrics per genre per year. Minimum threshold: 3 scored games per genre per year. Years with fewer games are excluded to prevent single-title years from distorting genre trends.

Includes a composite `genre_quality_index` per genre-year combination:
```
genre_quality_index = (pct_above_80 × 0.60) + (LEAST(game_count, 20) / 20.0 × 100 × 0.40)
```

**Grain:** one row per genre per year.

#### `rpt_game_analysis`
Game-level longevity and nostalgia delta analysis. Powers Pages 4 and 5.

Key calculated fields:

| Field | Formula | Purpose |
|-------|---------|---------|
| `game_age_years` | `2024 - release_year` | X axis for age vs score scatter |
| `nostalgia_delta` | `user_score - critic_score` | Critic vs player divergence |
| `nostalgia_label` | CASE on delta range | Human-readable divergence classification |
| `age_bucket` | CASE on game_age_years | Grouping for temporal analysis |
| `longevity_tier` | CASE on avg_playtime_hrs | Engagement classification |
| `ownership_tier` | CASE on owners_midpoint | Bubble sizing classification |

**Grain:** one row per qualifying PC game (critic_score ≥ 75).

---

## Key Transformation Decisions

### 1. Critic score gate (≥ 75)
All reporting queries apply `WHERE critic_score >= 75` as the base filter. Games without critic scores or below this threshold are excluded from all analysis. This gate ensures the dataset represents genuinely well-regarded titles rather than the full population of released games.

The genre champion threshold is raised further to `critic_score >= 80` — only games that cleared a higher bar are eligible to be crowned genre champions within their era.

### 2. COALESCE waterfall for genre resolution
Genre assignment uses a three-level priority cascade:

```sql
COALESCE(
  NULLIF(TRIM(e.genre_clean), ''),      -- 1. seed_enrichment (highest accuracy)
  NULLIF(TRIM(g.primary_genre), ''),    -- 2. Steam primary genre tag
  NULLIF(TRIM(SPLIT(COALESCE(g.genres_raw, ''), ',')[SAFE_OFFSET(0)]), ''),  -- 3. First raw genre token
  'Unknown'                              -- 4. Fallback
)
```

This ensures Metacritic-sourced games (which have no native genre) receive a genre through seed enrichment, while Steam games use their curated tag data.

### 3. Genre normalisation
Applied in the `genre_normalized_games` CTE after deduplication. Consolidation rules:

| Raw genre | Normalised to | Reason |
|-----------|--------------|--------|
| Massively Multiplayer | MMO | Steam tag rename |
| Action RPG | RPG | Maps to nearest standard genre |
| First-Person Shooter / FPS | Action | FPS bucketed into Action |
| Casual, Sexual Content, Card Game, Free To Play, Survival, Visual Novel, Unknown | NULL | Excluded from genre analysis |

FPS is consolidated into Action by default. A toggle comment in the CTE allows splitting FPS as a 15th independent genre if needed for future analysis.

### 4. Deduplication with source priority
Games appearing in both Steam and Metacritic datasets are deduplicated to one row. Steam source is always preferred — it carries richer engagement data (ownership, reviews, CCU).

```sql
ROW_NUMBER() OVER (
  PARTITION BY
    REGEXP_REPLACE(LOWER(TRIM(game_name)), r'[^a-z0-9 ]', ''),
    release_year
  ORDER BY
    CASE WHEN source = 'steam' THEN 1 ELSE 2 END ASC,
    critic_score DESC
) AS dedup_rank
```

`REGEXP_REPLACE` strips punctuation before partitioning to catch near-identical titles with minor formatting differences (e.g. "BioShock" vs "Bioshock").

### 5. Min-max normalisation for the Golden Era Index
Each pillar in `rpt_golden_era_index` is normalised to a 0–100 scale before weighting:

```sql
SAFE_DIVIDE(
  value - MIN(value) OVER(),
  NULLIF(MAX(value) OVER() - MIN(value) OVER(), 0)
) * 100
```

`SAFE_DIVIDE` prevents division-by-zero errors in edge cases where a metric has no variance across years. A year scoring 100 on a pillar is the best-ever year for that metric; 0 is the worst.

### 6. Stealth as a spotlight, not a genre
Stealth produces only 22 qualifying games across the full 30-year study window — too sparse to sustain a meaningful genre timeline in `rpt_genre_golden_eras`. It is intentionally excluded from the genre heatmap on Page 3 and surfaces instead as a curated spotlight on Page 2.

This is a design decision, not a data gap. Stealth did not scale into a mass-market genre — it became a mechanic absorbed by the best Action titles.

---

## Data Quality: Known Characteristics

### avg_playtime_hrs — NULL across all games
**Root cause:** Column misalignment in the raw Steam CSV during BigQuery ingestion. The `avg_playtime_hrs` field did not map correctly from the source file, resulting in NULL values across all 3,146 games in `rpt_game_analysis`.

**Impact:** The longevity scatter plot originally designed for Page 4A (game age vs playtime) was adapted. The page was redesigned around critic score vs game age (survivorship bias analysis) and nostalgia delta by era — both of which use fields with full data coverage.

**Resolution status:** The raw CSV would need to be re-ingested with corrected column mapping to recover playtime data.

### 43% null genre rate in rpt_game_analysis
Expected behaviour. Games carrying excluded Steam genre tags (Casual, Survival, Free To Play, etc.) map to NULL via the `genre_normalized_games` CTE. These games appear correctly in all non-genre-filtered analysis (scores, nostalgia, age) and disappear only from genre-specific views. Correct behaviour.

### Pre-Steam era data coverage (1993–2002)
Metacritic only. No ownership, playtime, peak CCU, or review ratio data for this period. Pre-Steam games appear in critic score analysis but show NULL ownership bubbles in scatter plots. Documented throughout the dashboard as "Legacy (pre-Steam, no data)" tier.

### Genre champion gaps — Birth of 3D era
The Birth of 3D era (1993–1995) does not appear as a column in the genre heatmap on Page 3. This era had insufficient qualifying games per genre to meet the minimum 3-game threshold required for genre champion eligibility. Not a bug — an honest reflection of how thin the scored game population was in the earliest years of the study window.

### 3,146 total qualifying games vs expected volume
The dataset returns 3,146 games with `critic_score >= 75` across 1993–2024. This is higher than initially expected and reflects the combined Steam + Metacritic coverage across 30 years. The `critic_score >= 80` gate used for genre champions and the Legends table reduces this to 1,793 — the true hall of fame population.

---

## Genre Schema — 14 Genres

Final normalised genre list applied consistently across all reporting queries:

Action · RPG · Strategy · Adventure · Simulation · Indie · Sports · Racing · Open World · MMO · Puzzle · Fighting · Horror · Stealth

Stealth is retained in the genre schema for `rpt_hall_of_kings` (spotlight panel) but excluded from `rpt_genre_golden_eras` (genre timeline) due to insufficient volume for meaningful trend analysis.

---

## Era Definitions

| Era Label | Years | Context |
|-----------|-------|---------|
| Birth of 3D | 1993–1995 | Doom era — first-person perspective emerges |
| Golden Age | 1996–1999 | Peak pre-internet era — Quake, Diablo, StarCraft |
| Pre-Steam Peak | 2000–2002 | Greatest index score — Deus Ex, BG2, Diablo II |
| Steam Launch Era | 2003–2006 | Steam launches 2003 — distribution shifts |
| Console Dominance Era | 2007–2011 | Xbox 360 / PS3 peak — PC gaming under pressure |
| Indie Explosion | 2012–2014 | Indie movement scales — BioShock Infinite, XCOM |
| AAA Renaissance | 2015–2018 | PC gaming reasserts dominance — Witcher 3, GTA V |
| Pandemic Boom | 2019–2021 | COVID drives gaming surge — Disco Elysium, Hades |
| Post-Boom Correction | 2022–2024 | Lowest index score — quality rate declines |

---

*Dataset sources:*
*Steam: [Kaggle — fronkongames](https://www.kaggle.com/datasets/fronkongames/steam-games-dataset)*
*Metacritic: [Kaggle — henrylin03](https://www.kaggle.com/datasets/henrylin03/metacritic-games-user-reviews-and-metascores)*
