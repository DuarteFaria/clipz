const std = @import("std");

pub const Config = struct {
    // Monitoring intervals (in milliseconds)
    min_poll_interval: u64 = 100, // Minimum polling interval
    max_poll_interval: u64 = 250, // Maximum polling interval when inactive
    inactive_threshold: i64 = 300, // Seconds before considering inactive

    // Persistence settings
    batch_save_interval: i64 = 5, // Seconds between saves
    force_save_cycles: u32 = 200, // Cycles before forcing a save check

    // Content limits
    max_content_size: usize = 100 * 1024, // 100KB per clipboard entry
    max_fetch_size: usize = 512 * 1024, // 512KB maximum fetch from system

    // History settings
    max_entries: usize = 10, // Maximum clipboard entries to keep

    pub fn default() Config {
        return Config{};
    }

    pub fn lowPower() Config {
        return Config{
            .min_poll_interval = 250, // Slower polling
            .max_poll_interval = 1000, // Much slower when inactive
            .inactive_threshold = 180, // Consider inactive sooner
            .batch_save_interval = 30, // Save less frequently
            .force_save_cycles = 100, // Check saves less often
        };
    }

    pub fn ultraLowPower() Config {
        return Config{
            .min_poll_interval = 500, // Very slow polling
            .max_poll_interval = 2000, // 2 second max delay
            .inactive_threshold = 120, // Consider inactive quickly (2 min)
            .batch_save_interval = 60, // Save only every minute
            .force_save_cycles = 50, // Check saves very rarely
            .max_entries = 5, // Keep fewer entries
        };
    }

    pub fn responsive() Config {
        return Config{
            .min_poll_interval = 50, // Faster polling
            .max_poll_interval = 150, // Stay relatively fast
            .inactive_threshold = 600, // Take longer to slow down
            .batch_save_interval = 2, // Save more frequently
            .force_save_cycles = 300, // Check saves more often
        };
    }
};
