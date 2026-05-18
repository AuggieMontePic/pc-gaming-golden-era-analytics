-- =============================================================================
-- rpt_genre_golden_eras.sql
-- PC Gaming Golden Era Analytics — Reporting Layer
--
-- Answers: "When did each genre peak? What were its greatest years?"
--
-- Methodology: per-genre annual quality index showing peaks, declines,
-- and renaissances over the 30-year study window.
--
-- Genre source priority:
--   1. seed_enrichment.genre_clean (manually curated, most accurate)
--   2. stg_pc_games.primary_genre  (Steam Tags first token)
--   3. Fallback: 'Unknown' (excluded from genre analysis)
--
-- Quality gate: critic_score >= 75 for inclusion in genre metrics.
-- Minimum 3 scored games per genre per year for reliable statistics.
--
-- Source tables:
--   pc-gaming-golden-era.pc_gaming.stg_pc_games
--   pc-gaming-golden-era.pc_gaming.seed_enrichment
--   pc-gaming-golden-era.pc_gaming.seed_vr_games
-- Output grain: one row per genre per year
-- =============================================================================


WITH

-- =============================================================================
-- CTE 1 — Enriched game base (same enrichment logic as rpt_hall_of_kings)
-- =============================================================================
enriched_games AS (
  SELECT
    g.game_key,
    g.source,
    g.name_raw                                                         AS game_name,
    g.release_year,
    g.critic_score,
    g.user_score,
    g.avg_playtime_hrs,
    g.owners_midpoint,
    g.reviews_total,

    -- Developer enrichment
    COALESCE(
      NULLIF(TRIM(e.developer_clean), ''),
      NULLIF(TRIM(g.developer), ''),
      'Unknown'
    )                                                                  AS developer,

    -- Genre enrichment
    COALESCE(
      NULLIF(TRIM(e.genre_clean), ''),
      NULLIF(TRIM(g.primary_genre), ''),
      NULLIF(TRIM(SPLIT(COALESCE(g.genres_raw, ''), ',')[SAFE_OFFSET(0)]), ''),
      'Unknown'
    )                                                                  AS genre,

    -- VR flag
    CASE
      WHEN vr.app_id IS NOT NULL THEN TRUE
      WHEN e.is_vr = TRUE THEN TRUE
      ELSE FALSE
    END                                                                AS is_vr,

    -- Era label for cross-reference
    CASE
      WHEN g.release_year BETWEEN 1993 AND 1995 THEN 'Birth of 3D'
      WHEN g.release_year BETWEEN 1996 AND 1999 THEN 'Golden Age'
      WHEN g.release_year BETWEEN 2000 AND 2002 THEN 'Pre-Steam Peak'
      WHEN g.release_year BETWEEN 2003 AND 2006 THEN 'Steam Launch Era'
      WHEN g.release_year BETWEEN 2007 AND 2011 THEN 'Console Dominance Era'
      WHEN g.release_year BETWEEN 2012 AND 2014 THEN 'Indie Explosion'
      WHEN g.release_year BETWEEN 2015 AND 2018 THEN 'AAA Renaissance'
      WHEN g.release_year BETWEEN 2019 AND 2021 THEN 'Pandemic Boom'
      WHEN g.release_year BETWEEN 2022 AND 2024 THEN 'Post-Boom Correction'
      ELSE 'Unknown'
    END                                                                AS era_label

  FROM `pc-gaming-golden-era.pc_gaming.stg_pc_games` g

  LEFT JOIN `pc-gaming-golden-era.pc_gaming.seed_enrichment` e
    ON LOWER(TRIM(g.name_raw)) = LOWER(TRIM(e.game_name))
   AND ABS(g.release_year - e.release_year) <= 1

  LEFT JOIN `pc-gaming-golden-era.pc_gaming.seed_vr_games` vr
    ON CAST(g.game_key AS STRING) = CAST(vr.app_id AS STRING)

  WHERE
    g.critic_score >= 75
    AND g.release_year BETWEEN 1993 AND 2024
    AND g.critic_score IS NOT NULL
),


-- =============================================================================
-- CTE 2 — Deduplicate (same logic as rpt_hall_of_kings)
-- =============================================================================
deduped_games AS (
  SELECT *
  FROM (
    SELECT
      *,
      ROW_NUMBER() OVER (
        PARTITION BY
          REGEXP_REPLACE(LOWER(TRIM(game_name)), r'[^a-z0-9 ]', ''),
          release_year
        ORDER BY
          CASE WHEN source = 'steam' THEN 1 ELSE 2 END ASC,
          critic_score DESC
      )                                                                AS dedup_rank
    FROM enriched_games
  )
  WHERE dedup_rank = 1
    AND genre != 'Unknown'
),

-- =============================================================================
-- CTE 2b — Genre normalization (consistent with rpt_hall_of_kings)
-- =============================================================================
genre_normalized_games AS (
  SELECT
    * EXCEPT (genre),
    CASE
      WHEN genre = 'Massively Multiplayer'          THEN 'MMO'
      WHEN genre = 'Action RPG'                     THEN 'RPG'
      WHEN genre IN ('First-Person Shooter', 'FPS') THEN 'Action'
      WHEN genre IN (
        'Casual',
        'Sexual Content',
        'Card Game',
        'Free To Play',
        'Survival',
        'Visual Novel',
        'Unknown'
      )                                             THEN NULL
      ELSE genre
    END                                             AS genre
  FROM deduped_games
),

-- =============================================================================
-- CTE 3 — Genre-year base metrics
-- Aggregates quality metrics per genre per year.
-- Minimum 3 games gate applied here.
-- =============================================================================
genre_year_base AS (
  SELECT
    genre,
    release_year,
    era_label,
    COUNT(*)                                                           AS game_count,
    ROUND(AVG(critic_score), 2)                                        AS avg_critic_score,
    ROUND(AVG(user_score), 2)                                          AS avg_user_score,
    MAX(critic_score)                                                  AS peak_score,
    ROUND(AVG(CASE WHEN critic_score >= 90 THEN 1.0 ELSE 0.0 END) * 100, 1)
                                                                       AS pct_above_90,
    ROUND(AVG(CASE WHEN critic_score >= 80 THEN 1.0 ELSE 0.0 END) * 100, 1)
                                                                       AS pct_above_80,
    -- Longevity signal (Steam era only)
    ROUND(AVG(avg_playtime_hrs), 2)                                    AS avg_playtime_hrs,
    -- Ownership signal
    ROUND(AVG(owners_midpoint), 0)                                     AS avg_owners_midpoint,
    -- Nostalgia delta
    ROUND(AVG(COALESCE(user_score, 0) - critic_score), 2)              AS avg_nostalgia_delta

  FROM genre_normalized_games
  WHERE genre IS NOT NULL
  GROUP BY genre, release_year, era_label
  HAVING COUNT(*) >= 3
),


-- =============================================================================
-- CTE 4 — Genre quality index per year
-- Composite score for each genre-year combination.
-- Simpler than the Golden Era Index — just quality + volume.
-- =============================================================================
genre_year_indexed AS (
  SELECT
    *,

    -- Genre quality index: weighted quality + breadth signal
    ROUND(
      (pct_above_80 * 0.60) +
      (LEAST(game_count, 20) / 20.0 * 100 * 0.40),
    2)                                                                 AS genre_quality_index,

    -- Year over year change in avg critic score
    ROUND(
      avg_critic_score - LAG(avg_critic_score) OVER (
        PARTITION BY genre
        ORDER BY release_year
      ),
    2)                                                                 AS yoy_score_delta,

    -- Year over year change in game count
    game_count - LAG(game_count) OVER (
      PARTITION BY genre
      ORDER BY release_year
    )                                                                  AS yoy_volume_delta

  FROM genre_year_base
),


-- =============================================================================
-- CTE 5 — Peak year identification per genre
-- The year with highest genre_quality_index = peak year.
-- =============================================================================
genre_peaks AS (
  SELECT
    genre,
    FIRST_VALUE(release_year) OVER (
      PARTITION BY genre
      ORDER BY genre_quality_index DESC
    )                                                                  AS peak_year,
    FIRST_VALUE(genre_quality_index) OVER (
      PARTITION BY genre
      ORDER BY genre_quality_index DESC
    )                                                                  AS peak_index,
    FIRST_VALUE(avg_critic_score) OVER (
      PARTITION BY genre
      ORDER BY genre_quality_index DESC
    )                                                                  AS peak_avg_score,
    release_year
  FROM genre_year_indexed
),


-- =============================================================================
-- CTE 6 — Top 3 games per genre per year
-- For dashboard drilldown: click a genre peak and see the top 3 games
-- =============================================================================
genre_year_top3 AS (
  SELECT
    genre,
    release_year,
    game_name,
    developer,
    critic_score,
    user_score,
    is_vr,
    ROW_NUMBER() OVER (
      PARTITION BY genre, release_year
      ORDER BY critic_score DESC, COALESCE(user_score, 0) DESC
    )                                                                  AS year_rank_in_genre

  FROM genre_normalized_games
),

-- Aggregate top 3 into a single string per genre-year for dashboard display
top3_aggregated AS (
  SELECT
    genre,
    release_year,
    STRING_AGG(
      CONCAT(game_name, ' (', CAST(critic_score AS STRING), ')'),
      ' · '
      ORDER BY year_rank_in_genre
    )                                                                  AS top3_games

  FROM genre_year_top3
  WHERE year_rank_in_genre <= 3
  GROUP BY genre, release_year
)


-- =============================================================================
-- FINAL OUTPUT
-- One row per genre per year — Looker Studio line chart ready.
-- Primary use: genre timeline chart with peak annotation.
-- Secondary use: genre drilldown table with top 3 games.
-- =============================================================================
SELECT
  g.genre,
  g.release_year,
  g.era_label,

  -- Volume and quality metrics
  g.game_count,
  g.avg_critic_score,
  g.avg_user_score,
  g.peak_score,
  g.pct_above_90,
  g.pct_above_80,
  g.avg_playtime_hrs,
  g.avg_owners_midpoint,
  g.avg_nostalgia_delta,

  -- Genre quality index and trends
  g.genre_quality_index,
  g.yoy_score_delta,
  g.yoy_volume_delta,

  -- Peak year flags (for annotation in dashboard)
  p.peak_year,
  p.peak_index,
  p.peak_avg_score,
  CASE
    WHEN g.release_year = p.peak_year THEN TRUE
    ELSE FALSE
  END                                                                  AS is_peak_year,

  -- Top 3 games string for drilldown tooltip
  t.top3_games

FROM genre_year_indexed g

LEFT JOIN (
  SELECT DISTINCT genre, peak_year, peak_index, peak_avg_score
  FROM genre_peaks
)                                                                      p
  ON g.genre = p.genre

LEFT JOIN top3_aggregated t
  ON g.genre = t.genre
 AND g.release_year = t.release_year

ORDER BY
  g.genre ASC,
  g.release_year ASC;
