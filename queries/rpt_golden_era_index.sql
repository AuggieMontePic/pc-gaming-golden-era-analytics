-- =============================================================================
-- rpt_golden_era_index.sql
-- PC Gaming Golden Era Analytics — Reporting Layer
--
-- Answers the central question of the project:
--   "What year or period constitutes the true golden era of PC gaming?"
--
-- Methodology: composite annual score built from 5 weighted pillars.
-- Each pillar is normalized to 0-100 before weighting so no single
-- metric dominates due to scale differences.
--
-- Pillar weights (documented rationale in data_model.md):
--   30% — Quality threshold rate  (% of games scoring 80+)
--   25% — Average critic score    (overall annual quality floor)
--   20% — Genre diversity         (breadth of creative output)
--   15% — Volume of scored games  (how much quality, not just peak quality)
--   10% — Longevity signal        (avg playtime as quality proxy, Steam era only)
--
-- Era labels mark known industry inflection points for dashboard annotation.
--
-- Source: pc-gaming-golden-era.pc_gaming.stg_pc_games
-- Output grain: one row per year (1993–2024)
-- =============================================================================


WITH

-- =============================================================================
-- CTE 1 — Base metrics per year
-- Only games with a critic score contribute to quality metrics.
-- Volume counts all games regardless of score coverage.
-- =============================================================================
yearly_base AS (
  SELECT
    release_year,

    -- Volume: all games released that year with any data
    COUNT(*)                                                           AS total_games,

    -- Scored games: subset with critic scores (quality analysis base)
    COUNT(critic_score)                                                AS scored_games,

    -- Quality metrics (critic-scored games only)
    ROUND(AVG(critic_score), 2)                                        AS avg_critic_score,
    ROUND(AVG(CASE WHEN critic_score >= 90 THEN 1.0 ELSE 0.0 END) * 100, 2)
                                                                       AS pct_above_90,
    ROUND(AVG(CASE WHEN critic_score >= 80 THEN 1.0 ELSE 0.0 END) * 100, 2)
                                                                       AS pct_above_80,
    ROUND(AVG(CASE WHEN critic_score >= 70 THEN 1.0 ELSE 0.0 END) * 100, 2)
                                                                       AS pct_above_70,
    MAX(critic_score)                                                  AS peak_score,

    -- Genre diversity: distinct primary genres as proxy for creative breadth
    -- Normalized later relative to max observed across all years
    COUNT(DISTINCT primary_genre)                                      AS distinct_genres,

    -- Longevity signal: avg playtime (Steam era only, NULLs excluded)
    ROUND(AVG(avg_playtime_hrs), 2)                                    AS avg_playtime_hrs,
    COUNT(avg_playtime_hrs)                                            AS games_with_playtime,

    -- User score coverage (for nostalgia delta calculation downstream)
    ROUND(AVG(user_score), 2)                                          AS avg_user_score,
    COUNT(user_score)                                                  AS games_with_user_score,

    -- Review sentiment (Steam era)
    ROUND(AVG(review_ratio_pct), 2)                                    AS avg_review_ratio,

    -- Ownership signal (Steam era)
    ROUND(AVG(owners_midpoint), 0)                                     AS avg_owners_midpoint

  FROM `pc-gaming-golden-era.pc_gaming.stg_pc_games`
  WHERE release_year BETWEEN 1993 AND 2024
  GROUP BY release_year
),


-- =============================================================================
-- CTE 2 — Normalize each pillar to 0-100 scale
-- Uses min-max normalization across all years so pillars are comparable.
-- A year scoring 100 on a pillar is the best-ever year for that metric.
-- A year scoring 0 is the worst-ever year for that metric.
-- =============================================================================
normalized AS (
  SELECT
    *,

    -- Pillar 1: Quality threshold rate (% games scoring 80+)
    ROUND(
      SAFE_DIVIDE(
        pct_above_80 - MIN(pct_above_80) OVER(),
        NULLIF(MAX(pct_above_80) OVER() - MIN(pct_above_80) OVER(), 0)
      ) * 100, 2
    )                                                                  AS p1_quality_rate,

    -- Pillar 2: Average critic score
    ROUND(
      SAFE_DIVIDE(
        avg_critic_score - MIN(avg_critic_score) OVER(),
        NULLIF(MAX(avg_critic_score) OVER() - MIN(avg_critic_score) OVER(), 0)
      ) * 100, 2
    )                                                                  AS p2_avg_score,

    -- Pillar 3: Genre diversity
    ROUND(
      SAFE_DIVIDE(
        distinct_genres - MIN(distinct_genres) OVER(),
        NULLIF(MAX(distinct_genres) OVER() - MIN(distinct_genres) OVER(), 0)
      ) * 100, 2
    )                                                                  AS p3_genre_diversity,

    -- Pillar 4: Volume of scored games
    -- Log-scaled to prevent massive Steam-era volumes from dominating
    ROUND(
      SAFE_DIVIDE(
        LN(scored_games + 1) - MIN(LN(scored_games + 1)) OVER(),
        NULLIF(
          MAX(LN(scored_games + 1)) OVER() - MIN(LN(scored_games + 1)) OVER(),
          0
        )
      ) * 100, 2
    )                                                                  AS p4_volume,

    -- Pillar 5: Longevity signal (avg playtime hrs, NULL-safe)
    -- Years with no playtime data (pre-Steam) score 0 on this pillar
    ROUND(
      SAFE_DIVIDE(
        COALESCE(avg_playtime_hrs, 0) - MIN(COALESCE(avg_playtime_hrs, 0)) OVER(),
        NULLIF(
          MAX(COALESCE(avg_playtime_hrs, 0)) OVER() -
          MIN(COALESCE(avg_playtime_hrs, 0)) OVER(),
          0
        )
      ) * 100, 2
    )                                                                  AS p5_longevity

  FROM yearly_base

  -- Minimum data quality gate: at least 5 scored games to be included
  -- Prevents single-game years from distorting the index
  WHERE scored_games >= 5
),


-- =============================================================================
-- CTE 3 — Composite Golden Era Index
-- Weighted sum of normalized pillars.
-- =============================================================================
composite AS (
  SELECT
    *,

    -- Golden Era Index: weighted composite (weights sum to 1.0)
    ROUND(
      (p1_quality_rate  * 0.30) +
      (p2_avg_score     * 0.25) +
      (p3_genre_diversity * 0.20) +
      (p4_volume        * 0.15) +
      (p5_longevity     * 0.10),
    2)                                                                 AS golden_era_index,

    -- Year-over-year change in average critic score
    ROUND(
      avg_critic_score - LAG(avg_critic_score) OVER (ORDER BY release_year),
    2)                                                                 AS yoy_score_delta,

    -- Year-over-year change in scored game volume
    scored_games - LAG(scored_games) OVER (ORDER BY release_year)     AS yoy_volume_delta,

    -- Nostalgia delta: user score vs critic score gap
    -- Positive = users rate higher than critics (nostalgia premium)
    -- Negative = critics rate higher than users (backlash)
    ROUND(avg_user_score - avg_critic_score, 2)                        AS nostalgia_delta

  FROM normalized
),


-- =============================================================================
-- CTE 4 — Era labels and index ranking
-- Annotates known industry inflection points for dashboard storytelling.
-- =============================================================================
final AS (
  SELECT
    *,

    -- Global rank: 1 = greatest year in PC gaming history by this index
    DENSE_RANK() OVER (ORDER BY golden_era_index DESC)                 AS era_index_rank,

    -- Rolling 3-year average to smooth noise for trend visualization
    ROUND(AVG(golden_era_index) OVER (
      ORDER BY release_year
      ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING
    ), 2)                                                              AS golden_era_index_3yr_avg,

    -- Era label for dashboard annotation
    CASE
      WHEN release_year BETWEEN 1993 AND 1995 THEN 'Birth of 3D (Doom Era)'
      WHEN release_year BETWEEN 1996 AND 1999 THEN 'Golden Age Candidates'
      WHEN release_year BETWEEN 2000 AND 2002 THEN 'Pre-Steam Peak'
      WHEN release_year BETWEEN 2003 AND 2006 THEN 'Steam Launch Era'
      WHEN release_year BETWEEN 2007 AND 2011 THEN 'Console Dominance Era'
      WHEN release_year BETWEEN 2012 AND 2014 THEN 'Indie Explosion'
      WHEN release_year BETWEEN 2015 AND 2018 THEN 'AAA Renaissance'
      WHEN release_year BETWEEN 2019 AND 2021 THEN 'Pandemic Boom'
      WHEN release_year BETWEEN 2022 AND 2024 THEN 'Post-Boom Correction'
      ELSE 'Unknown'
    END                                                                AS era_label,

    -- Coverage tier flag for dashboard transparency
    CASE
      WHEN release_year < 2003 THEN 'Metacritic-only (pre-Steam)'
      ELSE 'Steam + Metacritic'
    END                                                                AS coverage_tier

  FROM composite
)


-- =============================================================================
-- FINAL OUTPUT
-- One row per year — ready for Looker Studio connection
-- =============================================================================
SELECT
  release_year,
  era_label,
  coverage_tier,

  -- Raw metrics
  total_games,
  scored_games,
  avg_critic_score,
  avg_user_score,
  pct_above_90,
  pct_above_80,
  pct_above_70,
  peak_score,
  distinct_genres,
  avg_playtime_hrs,
  avg_owners_midpoint,
  avg_review_ratio,

  -- Normalized pillars (for dashboard pillar breakdown chart)
  p1_quality_rate,
  p2_avg_score,
  p3_genre_diversity,
  p4_volume,
  p5_longevity,

  -- The index
  golden_era_index,
  golden_era_index_3yr_avg,
  era_index_rank,

  -- Trend signals
  yoy_score_delta,
  yoy_volume_delta,
  nostalgia_delta

FROM final
ORDER BY release_year ASC;
