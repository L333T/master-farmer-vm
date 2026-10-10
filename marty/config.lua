-- ============================================================================
-- Marty Nav - config.lua
-- One shared table of tunables. client:update_config({ key = value }) changes
-- any key here (same Lua type only), as with AmeisenNav's anav/config.lua -
-- products that tune AmeisenNav keep working; keys that mean nothing here
-- (driver, avoid_*, use_look_at ...) are accepted and kept.
-- ============================================================================

return {
    -- server
    url                 = "https://nav.deathwing.fyi/nav/testpath",
    base_url            = "https://nav.deathwing.fyi",   -- AmeisenNav name; informational
    token               = "",
    request_timeout     = 8.0,      -- a remote server: longer than AmeisenNav's 3 s
    max_inflight        = 4,
    max_queued          = 32,
    health_interval     = 30,
    health_retry        = 5,
    down_after_failures = 3,

    -- paths
    path_flags          = 0,        -- accepted, unused: the test server fixes smoothing
    path_cache_ttl      = 10,
    path_cache_grid     = 4,
    path_cache_size     = 64,
    partial_accept      = 5.0,      -- a partial path ending this close counts as complete

    -- walking
    waypoint_threshold  = 2.5,
    final_threshold     = 1.5,
    pause_while_casting = true,
    use_look_at         = "auto",   -- auto | look_at | turns  (auto: turns on WoW Forever)
    driver              = "auto",   -- accepted for AmeisenNav compatibility (always simple_movement)
    deviation_limit     = 8.0,      -- yards off the path before a repath
    max_repaths         = 10,

    -- stuck
    stuck_sample        = 0.5,
    stuck_window        = 1.5,
    stuck_min_move      = 0.8,
    stuck_clear_move    = 3.0,
    max_stuck           = 5,
    backoff_time        = 0.6,

    -- kite / flee
    escape_distance     = 12.0,

    -- accepted for AmeisenNav compatibility, unused here
    avoid               = true,
    avoid_units         = true,
    avoid_ask_every     = 0.2,
    follow_near         = 3.0,
    faction             = "auto",
    draw_path           = true,
    debug_log           = false,
    banner              = true,
}
