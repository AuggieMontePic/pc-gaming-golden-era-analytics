-- =============================================================================
-- rpt_hall_of_kings.sql  (v2 — with seed enrichment)
-- PC Gaming Golden Era Analytics — Reporting Layer
--
-- Answers: "Who are the greatest PC games of each era and genre?"
--
-- Changes from v1:
--   - Joins seed_enrichment to recover developer and genre for
--     Metacritic-sourced games (which have no native developer/genre fields)
--   - Joins seed_vr_games to flag VR titles from Steam dataset
--   - Genre champion threshold raised from 75 to 80 for cleaner story
--   - Era champion threshold remains 75+
--
-- Champion selection: highest critic score per era / genre+era combo.
-- Tiebreaker: user_score DESC, reviews_total DESC.
-- Cross-era comparison intentionally avoided — each era crowns its own king.
--
-- Source tables:
--   pc-gaming-golden-era.pc_gaming.stg_pc_games     (base game data)
--   pc-gaming-golden-era.pc_gaming.seed_enrichment  (developer + genre fixes)
--   pc-gaming-golden-era.pc_gaming.seed_vr_games    (VR flag from Steam)
-- Output grain: one row per qualifying PC game (critic_score >= 75)
-- =============================================================================


WITH

-- =============================================================================
-- CTE 1 — Enriched game base
-- Joins seed tables to recover missing developer/genre/VR data.
-- COALESCE priority: seed enrichment → raw staging data → fallback value
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
    g.review_ratio_pct,
    g.peak_ccu,
    g.score_match_tier,
    g.has_playtime_data,

    -- Developer: seed enrichment first, fall back to raw staging
    COALESCE(
      NULLIF(TRIM(e.developer_clean), ''),
      NULLIF(TRIM(g.developer), ''),
      'Unknown'
    )                                                                  AS developer,

    -- Publisher: raw staging only (seed enrichment doesn't track publisher)
    COALESCE(NULLIF(TRIM(g.publisher), ''), 'Unknown')                 AS publisher,

    -- Genre: seed enrichment first (fixes Metacritic Unknown genres),
    -- fall back to primary_genre from staging, then genres_raw first token
    COALESCE(
      NULLIF(TRIM(e.genre_clean), ''),
      NULLIF(TRIM(g.primary_genre), ''),
      NULLIF(TRIM(SPLIT(COALESCE(g.genres_raw, ''), ',')[SAFE_OFFSET(0)]), ''),
      'Unknown'
    )                                                                  AS genre,

    -- Full genre string for dashboard multi-genre filtering
    COALESCE(g.genres_raw, e.genre_clean, 'Unknown')                  AS genres_raw,

    -- VR flag: seed_vr_games (Steam-derived) OR seed_enrichment manual flag
    CASE
      WHEN vr.app_id IS NOT NULL THEN TRUE
      WHEN e.is_vr = TRUE THEN TRUE
      ELSE FALSE
    END                                                                AS is_vr,

    -- Nostalgia delta: user score minus critic score
    ROUND(COALESCE(g.user_score, 0) - g.critic_score, 2)              AS nostalgia_delta,

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
    END                                                                AS era_label,

    -- Era sort order for correct dashboard display sequence
    CASE
      WHEN g.release_year BETWEEN 1993 AND 1995 THEN 1
      WHEN g.release_year BETWEEN 1996 AND 1999 THEN 2
      WHEN g.release_year BETWEEN 2000 AND 2002 THEN 3
      WHEN g.release_year BETWEEN 2003 AND 2006 THEN 4
      WHEN g.release_year BETWEEN 2007 AND 2011 THEN 5
      WHEN g.release_year BETWEEN 2012 AND 2014 THEN 6
      WHEN g.release_year BETWEEN 2015 AND 2018 THEN 7
      WHEN g.release_year BETWEEN 2019 AND 2021 THEN 8
      WHEN g.release_year BETWEEN 2022 AND 2024 THEN 9
      ELSE 10
    END                                                                AS era_sort_order

  FROM `pc-gaming-golden-era.pc_gaming.stg_pc_games` g

  -- Seed enrichment: join on name + release year (±1 year tolerance)
  LEFT JOIN `pc-gaming-golden-era.pc_gaming.seed_enrichment` e
    ON LOWER(TRIM(g.name_raw)) = LOWER(TRIM(e.game_name))
   AND ABS(g.release_year - e.release_year) <= 1

  -- VR flag: join on app_id (Steam games only)
  LEFT JOIN `pc-gaming-golden-era.pc_gaming.seed_vr_games` vr
    ON CAST(g.game_key AS STRING) = CAST(vr.app_id AS STRING)

  WHERE
    g.critic_score >= 75
    AND g.release_year BETWEEN 1993 AND 2024
    AND g.critic_score IS NOT NULL
),


-- =============================================================================
-- CTE 2 — Deduplicate on game_name + release_year
-- Removes duplicate rows caused by multiple Metacritic platform entries
-- or Steam + Metacritic overlap for the same game.
-- Priority: Steam source > Metacritic source (Steam has richer data)
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
-- CTE 2b — Genre normalization
-- Applies consolidation rules to the resolved genre field.
-- Runs AFTER deduplication so normalization doesn't affect dedup logic.
--
-- Rules applied:
--   Massively Multiplayer → MMO           (Steam tag rename)
--   Action RPG            → RPG           (maps to nearest 14-genre equivalent)
--   First-Person Shooter  → Action        (FPS bucket — change to 'FPS' to split)
--   Casual / Sexual Content / Card Game
--   / Free To Play / Survival
--   / Visual Novel        → NULL          (excluded from genre analysis)
--   Unknown               → NULL          (no reliable genre data)
--
-- Downstream CTEs filter WHERE genre IS NOT NULL naturally.
-- =============================================================================
genre_normalized_games AS (
  SELECT
    * EXCEPT (genre),
    CASE
      WHEN genre = 'Massively Multiplayer'          THEN 'MMO'
      WHEN genre = 'Action RPG'                     THEN 'RPG'
      -- FPS toggle: change 'Action' → 'FPS' here to enable 15th genre
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
-- CTE 3 — Era statistics
-- Context metrics per era for dashboard champion cards.
-- =============================================================================
era_stats AS (
  SELECT
    era_label,
    era_sort_order,
    COUNT(*)                                                           AS era_qualified_games,
    ROUND(AVG(critic_score), 1)                                        AS era_avg_score,
    MAX(critic_score)                                                  AS era_peak_score,
    COUNT(DISTINCT genre)                                              AS era_distinct_genres,
    MIN(release_year)                                                  AS era_start_year,
    MAX(release_year)                                                  AS era_end_year,
    SUM(CASE WHEN is_vr THEN 1 ELSE 0 END)                            AS era_vr_games
  FROM genre_normalized_games
  WHERE genre IS NOT NULL
  GROUP BY era_label, era_sort_order
),


-- =============================================================================
-- CTE 4 — Era champion ranking
-- Top game per era (critic_score >= 75 gate applied in CTE 1).
-- =============================================================================
era_ranked AS (
  SELECT
    game_key,
    DENSE_RANK() OVER (
      PARTITION BY era_label
      ORDER BY
        critic_score DESC,
        COALESCE(user_score, 0) DESC,
        COALESCE(reviews_total, 0) DESC
    )                                                                  AS era_rank
  FROM genre_normalized_games
),


-- =============================================================================
-- CTE 5 — Genre champion ranking per era
-- Top game per genre per era (critic_score >= 80 gate for genre champions).
-- Only genres with 3+ qualifying games in an era are eligible.
-- VR treated as an independent genre category regardless of primary genre.
-- =============================================================================
genre_era_counts AS (
  SELECT
    era_label,
    genre,
    COUNT(*)                                                           AS genre_era_count
  FROM genre_normalized_games
  WHERE critic_score >= 80
  GROUP BY era_label, genre
),

vr_era_counts AS (
  SELECT
    era_label,
    'VR' AS genre,
    COUNT(*)                                                           AS genre_era_count
  FROM genre_normalized_games
  WHERE is_vr = TRUE
    AND critic_score >= 80
  GROUP BY era_label
),

genre_ranked AS (
  SELECT
    g.game_key,
    g.genre                                                            AS ranked_genre,
    gc.genre_era_count,
    DENSE_RANK() OVER (
      PARTITION BY g.era_label, g.genre
      ORDER BY
        g.critic_score DESC,
        COALESCE(g.user_score, 0) DESC,
        COALESCE(g.reviews_total, 0) DESC
    )                                                                  AS genre_era_rank
  FROM genre_normalized_games g
  INNER JOIN genre_era_counts gc
    ON g.era_label = gc.era_label
   AND g.genre = gc.genre
  WHERE g.critic_score >= 80
    AND gc.genre_era_count >= 3
),

-- VR champion ranking: independent of primary genre
vr_ranked AS (
  SELECT
    g.game_key,
    'VR'                                                               AS vr_category,
    DENSE_RANK() OVER (
      PARTITION BY g.era_label
      ORDER BY
        g.critic_score DESC,
        COALESCE(g.user_score, 0) DESC
    )                                                                  AS vr_era_rank
  FROM genre_normalized_games g
  INNER JOIN vr_era_counts vc
    ON g.era_label = vc.era_label
  WHERE g.is_vr = TRUE
    AND g.critic_score >= 80
)


-- =============================================================================
-- FINAL OUTPUT
-- All qualifying games with full ranking context.
-- Dashboard filter options:
--   is_era_champion = TRUE        → Hall of Kings main view (9 champions)
--   is_genre_era_champion = TRUE  → Genre champion view
--   is_vr_champion = TRUE         → VR category champions
--   era_rank <= 5                 → Era top 5 drilldown panel
--   genre = 'RPG'                 → Single genre deep dive
--   is_vr = TRUE                  → All VR titles
-- =============================================================================
SELECT
  -- Identity
  d.game_key,
  d.source,
  d.game_name,
  d.release_year,
  d.era_label,
  d.era_sort_order,
  d.genre,
  d.genres_raw,
  d.developer,
  d.publisher,
  d.is_vr,

  -- Scores
  d.critic_score,
  d.user_score,
  d.nostalgia_delta,

  -- Era ranking
  er.era_rank,
  CASE WHEN er.era_rank = 1 THEN TRUE ELSE FALSE END                   AS is_era_champion,

  -- Genre ranking (NULL if genre had < 3 qualifying games in era)
  gr.genre_era_rank,
  gr.genre_era_count,
  CASE WHEN gr.genre_era_rank = 1 THEN TRUE ELSE FALSE END             AS is_genre_era_champion,

  -- VR category ranking
  vr.vr_era_rank,
  CASE WHEN vr.vr_era_rank = 1 THEN TRUE ELSE FALSE END                AS is_vr_era_champion,

  -- Era context for champion cards
  es.era_qualified_games,
  es.era_avg_score,
  es.era_peak_score,
  es.era_distinct_genres,
  es.era_start_year,
  es.era_end_year,
  es.era_vr_games,

  -- Engagement signals
  d.avg_playtime_hrs,
  d.owners_midpoint,
  d.reviews_total,
  d.review_ratio_pct,
  d.peak_ccu,
  d.has_playtime_data,
  d.score_match_tier

FROM genre_normalized_games d
LEFT JOIN era_ranked er     ON d.game_key = er.game_key
LEFT JOIN genre_ranked gr   ON d.game_key = gr.game_key
LEFT JOIN vr_ranked vr      ON d.game_key = vr.game_key
LEFT JOIN era_stats es      ON d.era_label = es.era_label

ORDER BY
  d.era_sort_order ASC,
  d.critic_score DESC,
  COALESCE(d.user_score, 0) DESC;
