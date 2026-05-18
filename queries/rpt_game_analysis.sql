-- =============================================================================
-- rpt_game_analysis.sql
-- PC Gaming Golden Era Analytics — Reporting Layer
--
-- Powers two dashboard pages:
--
-- PAGE 4A — The Test of Time
--   "Which games were great at launch and are still being played today?"
--   Scatter plot: game age (X) × avg playtime (Y) × owners (bubble size)
--   Top-right quadrant = true legends: old AND still played
--
-- PAGE 4B — Critics vs Players
--   "Where do critics and players disagree most?"
--   Nostalgia delta analysis: user_score - critic_score per game
--   Positive delta = users rate higher (nostalgia premium or cult classic)
--   Negative delta = critics rate higher (paper classic or review inflation)
--   Grouped by game age bucket to surface temporal patterns
--
-- Data notes:
--   - Longevity metrics (playtime, peak_ccu) only available for Steam games
--   - Pre-Steam games have NULL playtime — shown separately as "Legacy" tier
--   - Both pages share the same underlying game-level dataset
--   - VR titles flagged for optional VR-specific filtering
--
-- Source tables:
--   pc-gaming-golden-era.pc_gaming.stg_pc_games
--   pc-gaming-golden-era.pc_gaming.seed_enrichment
--   pc-gaming-golden-era.pc_gaming.seed_vr_games
-- Output grain: one row per qualifying PC game (critic_score >= 75)
-- =============================================================================


WITH

-- =============================================================================
-- CTE 1 — Enriched game base (consistent with other reporting tables)
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
    g.median_playtime_mins,
    g.peak_ccu,
    g.owners_midpoint,
    g.owners_range_low,
    g.owners_range_high,
    g.reviews_positive,
    g.reviews_negative,
    g.reviews_total,
    g.review_ratio_pct,
    g.recommendations,
    g.price_usd,
    g.has_playtime_data,
    g.score_match_tier,

    -- Developer enrichment
    COALESCE(
      NULLIF(TRIM(e.developer_clean), ''),
      NULLIF(TRIM(g.developer), ''),
      'Unknown'
    )                                                                  AS developer,

    -- Publisher
    COALESCE(NULLIF(TRIM(g.publisher), ''), 'Unknown')                 AS publisher,

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

    -- Era label
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
-- CTE 2 — Deduplicate
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
-- CTE 3 — Longevity and nostalgia metrics
-- Core calculations for both dashboard pages
-- =============================================================================
game_metrics AS (
  SELECT
    *,

    -- Game age in years (from 2024)
    2024 - release_year                                                AS game_age_years,

    -- Age bucket for grouping
    CASE
      WHEN 2024 - release_year >= 20 THEN '20+ years (Legend tier)'
      WHEN 2024 - release_year >= 15 THEN '15-19 years (Classic tier)'
      WHEN 2024 - release_year >= 10 THEN '10-14 years (Established)'
      WHEN 2024 - release_year >= 5  THEN '5-9 years (Recent)'
      ELSE 'Under 5 years (New)'
    END                                                                AS age_bucket,

    -- Age bucket sort order
    CASE
      WHEN 2024 - release_year >= 20 THEN 1
      WHEN 2024 - release_year >= 15 THEN 2
      WHEN 2024 - release_year >= 10 THEN 3
      WHEN 2024 - release_year >= 5  THEN 4
      ELSE 5
    END                                                                AS age_bucket_sort,

    -- Nostalgia delta: user score minus critic score
    -- NULL user_score games get NULL delta (not forced to 0)
    CASE
      WHEN user_score IS NOT NULL
      THEN ROUND(user_score - critic_score, 2)
      ELSE NULL
    END                                                                AS nostalgia_delta,

    -- Nostalgia classification
    CASE
      WHEN user_score IS NULL                        THEN 'No user score'
      WHEN user_score - critic_score >= 10           THEN 'Cult Classic (users love it)'
      WHEN user_score - critic_score >= 3            THEN 'Slight user preference'
      WHEN user_score - critic_score >= -3           THEN 'Critics and users agree'
      WHEN user_score - critic_score >= -10          THEN 'Slight critic preference'
      ELSE                                                'Critics loved it more'
    END                                                                AS nostalgia_label,

    -- Longevity tier (Page 4A: Test of Time)
    -- Based on avg playtime relative to game's age
    CASE
      WHEN avg_playtime_hrs IS NULL                  THEN 'Legacy (pre-Steam, no data)'
      WHEN avg_playtime_hrs >= 100                   THEN 'Timeless (100h+ avg)'
      WHEN avg_playtime_hrs >= 50                    THEN 'Long-lasting (50-100h)'
      WHEN avg_playtime_hrs >= 20                    THEN 'Well-played (20-50h)'
      WHEN avg_playtime_hrs >= 5                     THEN 'Moderate play (5-20h)'
      ELSE                                                'Low engagement (<5h)'
    END                                                                AS longevity_tier,

    -- Longevity tier sort order (for dashboard legend ordering)
    CASE
      WHEN avg_playtime_hrs IS NULL                  THEN 0
      WHEN avg_playtime_hrs >= 100                   THEN 5
      WHEN avg_playtime_hrs >= 50                    THEN 4
      WHEN avg_playtime_hrs >= 20                    THEN 3
      WHEN avg_playtime_hrs >= 5                     THEN 2
      ELSE                                                1
    END                                                                AS longevity_tier_sort,

    -- Ownership tier for bubble sizing in scatter plot
    CASE
      WHEN owners_midpoint >= 10000000  THEN 'Mega (10M+ owners)'
      WHEN owners_midpoint >= 1000000   THEN 'Major (1-10M owners)'
      WHEN owners_midpoint >= 100000    THEN 'Significant (100K-1M)'
      WHEN owners_midpoint >= 10000     THEN 'Niche (10K-100K)'
      WHEN owners_midpoint IS NULL      THEN 'Unknown'
      ELSE                                   'Micro (<10K)'
    END                                                                AS ownership_tier

  FROM genre_normalized_games
)


-- =============================================================================
-- FINAL OUTPUT
-- One row per game — powers both Page 4A and Page 4B.
--
-- Page 4A (Test of Time) key fields:
--   game_age_years, avg_playtime_hrs, owners_midpoint,
--   longevity_tier, critic_score, developer, era_label
--
-- Page 4B (Critics vs Players) key fields:
--   nostalgia_delta, nostalgia_label, age_bucket,
--   critic_score, user_score, game_name, release_year
-- =============================================================================
SELECT
  -- Identity
  game_key,
  source,
  game_name,
  release_year,
  era_label,
  genre,
  developer,
  publisher,
  is_vr,

  -- Scores
  critic_score,
  user_score,

  -- Nostalgia analysis (Page 4B)
  nostalgia_delta,
  nostalgia_label,

  -- Age signals
  game_age_years,
  age_bucket,
  age_bucket_sort,

  -- Longevity signals (Page 4A)
  avg_playtime_hrs,
  median_playtime_mins,
  peak_ccu,
  longevity_tier,
  longevity_tier_sort,
  has_playtime_data,

  -- Ownership signals (bubble sizing)
  owners_midpoint,
  owners_range_low,
  owners_range_high,
  ownership_tier,

  -- Review signals
  reviews_positive,
  reviews_negative,
  reviews_total,
  review_ratio_pct,
  recommendations,

  -- Price
  price_usd,

  -- Pipeline metadata
  score_match_tier

FROM game_metrics
ORDER BY
  critic_score DESC,
  COALESCE(user_score, 0) DESC;
