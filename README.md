# PC Gaming Golden Era Analytics

**Author:** AuggieMontePic
**Tools:** BigQuery SQL | Looker Studio | Google Cloud
**Datasets:** [Steam Games Dataset](https://www.kaggle.com/datasets/fronkongames/steam-games-dataset) | [Metacritic PC Scores](https://www.kaggle.com/datasets/henrylin03/metacritic-games-user-reviews-and-metascores)

---

## About This Project

This project answers a question every PC gamer has debated: **when was the true golden era of PC gaming?**

Using 30 years of critic scores, user ratings, ownership data, and genre metadata — spanning 1993 to 2024 — a composite Golden Era Index was built from the ground up in BigQuery SQL and visualised across a 5-page Looker Studio dashboard. The result is a data-driven argument, not an opinion.

This is a technical showcase project demonstrating end-to-end analytics capabilities: raw data ingestion, multi-source ETL pipeline, seed enrichment, composite index design, and dashboard storytelling. There are no business recommendations here — only findings, methodology, and the story the data chose to tell.

---

## Pipeline & Data Model

- [`data_model.md`](./data_model.md) — Schema diagram, table descriptions, grain definitions, transformation decisions, and known data characteristics
- [`pipeline_overview.md`](./pipeline_overview.md) — Full ETL architecture: Extract → Transform → Load → Visualise

---

## Dashboard

**5-page Looker Studio report — PC Gaming Golden Era Analytics**

| Page | Title | Source Table | Central Question |
|------|-------|-------------|-----------------|
| 1 | The Golden Era Index | `rpt_golden_era_index` | When was the best year in PC gaming history? |
| 2 | Hall of Kings | `rpt_hall_of_kings` | Who are the greatest PC games of each era? |
| 3 | Genre Golden Eras | `rpt_genre_golden_eras` | When did each genre peak? |
| 4 | Timeless or Trendy? | `rpt_game_analysis` | Do older games score higher? Do critics and players agree? |
| 5 | The Legends | `rpt_game_analysis` | Every great game (80+), remembered |

Link to live dashboard: https://datastudio.google.com/reporting/56a1a81a-205b-4dc2-a0ed-5b645098a958

---

## SQL Queries

| # | Query | Description |
|---|-------|-------------|
| 1 | [`rpt_golden_era_index.sql`](./queries/rpt_golden_era_index.sql) | Composite annual index — 5 weighted pillars, normalised 0–100 |
| 2 | [`rpt_hall_of_kings.sql`](./queries/rpt_hall_of_kings.sql) | Era champions, genre champions, VR and Stealth spotlights |
| 3 | [`rpt_genre_golden_eras.sql`](./queries/rpt_genre_golden_eras.sql) | Genre-level quality timelines with peak year identification |
| 4 | [`rpt_game_analysis.sql`](./queries/rpt_game_analysis.sql) | Game-level longevity, nostalgia delta, age bucket analysis |

---

## Key Findings

**The data crowned the year 2000 as the greatest year in PC gaming history.**

The Pre-Steam Peak era (2000–2002) ranked first in the composite Golden Era Index, driven by exceptional quality depth — Baldur's Gate II, Deus Ex, Diablo II, The Sims, and Planescape: Torment all releasing within the same window. A year so dense with landmark titles it has never been equalled.

**Other significant findings:**

- **Survivor bias is real and measurable.** Golden Age games (1996–1999) achieve the highest average critic scores AND the largest ownership numbers of any era — but only the games worth remembering survived into the dataset. The bad ones were forgotten. The good ones became legends.

- **Critics consistently rate games higher than players across every era.** Not one era produced a positive average nostalgia delta — users rate below critics in all nine eras. Post-Boom Correction (2022–2024) shows the most extreme gap, suggesting growing player frustration with modern release quality and monetisation practices.

- **Birth of 3D is the only era where players rated higher than critics.** The 1993–1995 window — Doom, Quake, Command & Conquer — was underestimated by critics at the time and retrospectively beloved by players. The gap is small but directionally unique in the dataset.

- **Out of the Park Baseball 2007 is the greatest outlier in the dataset.** Critic score: 96. User score: 26. A niche sports simulation universally praised by professional reviewers and almost universally rejected by the general player base. A single row that validates the entire Critics vs Players analytical framework.

- **Action is the only genre present in every era.** Across 30 years and 9 eras, Action maintained enough qualifying games to register in every single period. No other genre achieved this consistency.

- **Stealth never became a genre — it became a mechanic.** Only 22 qualifying Stealth games across 30 years. Too thin to sustain a genre timeline but rich enough to crown Thief: The Dark Project as its all-time champion.

- **Half-Life: Alyx is the unchallenged VR champion.** The only VR title that crosses the era champion threshold on both critic score and cultural significance.

- **The Golden Era Index declines sharply after 2022.** The Post-Boom Correction era registers the lowest composite index score of any era with sufficient data — driven by falling quality rates, widening critic-player gaps, and declining genre diversity in high-scoring titles.

---

## SQL Techniques Demonstrated

| Technique | Queries |
|-----------|---------|
| CTEs (Common Table Expressions) | All queries |
| Window functions — `DENSE_RANK`, `ROW_NUMBER`, `LAG`, `FIRST_VALUE` | All queries |
| Min-max normalisation across window | `rpt_golden_era_index` |
| Composite index design (5 weighted pillars) | `rpt_golden_era_index` |
| Log scaling (`LN`) to prevent volume domination | `rpt_golden_era_index` |
| Multi-source deduplication with priority ranking | All queries |
| Seed enrichment joins (name + year tolerance matching) | All queries |
| `COALESCE` waterfall for null handling | All queries |
| `REGEXP_REPLACE` for fuzzy name normalisation | All queries |
| `SAFE_DIVIDE` for null-safe division | `rpt_golden_era_index` |
| `STRING_AGG` for aggregated display strings | `rpt_genre_golden_eras` |
| Genre normalisation via in-query `CASE` consolidation | All queries |
| Composite champion tier classification | `rpt_hall_of_kings` |
| Rolling 3-year average (`ROWS BETWEEN`) | `rpt_golden_era_index` |
| Age bucket and nostalgia delta calculations | `rpt_game_analysis` |

---

## Dataset

| Dataset | Source | Coverage |
|---------|--------|----------|
| Steam Games | [Kaggle — fronkongames](https://www.kaggle.com/datasets/fronkongames/steam-games-dataset) | ~85,000 Steam titles with ownership, playtime, review data |
| Metacritic PC | [Kaggle — henrylin03](https://www.kaggle.com/datasets/henrylin03/metacritic-games-user-reviews-and-metascores) | Pre-Steam era (1993–2002) critic and user scores |
| seed_enrichment | Manual curation | 337-row genre overrides, developer corrections, VR flags |
| seed_vr_games | Steam-derived | VR title identification for optional VR filtering |

**Study period:** 1993–2024
**Qualifying games (critic_score ≥ 75):** ~3,100
**Legends (critic_score ≥ 80):** 1,793

---

## Tools & Technologies

- **Google BigQuery** — Data warehouse, SQL transformation, table materialisation
- **Looker Studio** — 5-page interactive dashboard
- **Google Cloud Platform** — Cloud infrastructure

---

## Known Data Characteristics

- `avg_playtime_hrs` is null across all games due to column misalignment in the raw Steam CSV ingest. Longevity analysis was adapted accordingly — see [`data_model.md`](./data_model.md) for full details.
- Pre-Steam era (1993–2002) covered by Metacritic only. No ownership, playtime, or CCU data for this period.
- 43% null genre rate in `rpt_game_analysis` — expected behaviour from excluded Steam genre tags (Casual, Survival, etc.) mapping to NULL via the normalisation CTE.
- Genre champion threshold requires ≥ 3 qualifying games per genre per era. Sparse eras and genres do not appear in genre champion views — this is correct behaviour, not a data gap.

---

*Datasets: [Steam Games on Kaggle](https://www.kaggle.com/datasets/fronkongames/steam-games-dataset) | [Metacritic on Kaggle](https://www.kaggle.com/datasets/henrylin03/metacritic-games-user-reviews-and-metascores)*
*Tools: Google BigQuery · Looker Studio · Google Cloud Platform*
