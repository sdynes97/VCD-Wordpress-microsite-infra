<?php
/**
 * Loaded from wp-config.php via WORDPRESS_CONFIG_EXTRA.
 *
 * The only path into these containers is the Cloudflare Tunnel, so the
 * forwarded headers below can be trusted.
 */

if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    $_SERVER['HTTPS'] = 'on';
}

if (!empty($_SERVER['HTTP_CF_CONNECTING_IP'])) {
    $_SERVER['REMOTE_ADDR'] = $_SERVER['HTTP_CF_CONNECTING_IP'];
}

define('FORCE_SSL_ADMIN', true);
define('DISALLOW_FILE_EDIT', true);
define('WP_AUTO_UPDATE_CORE', 'minor');

// WP-Cron is triggered by host cron (see /etc/cron.d/wordpress) instead of
// loopback HTTP requests, which would otherwise go out through Cloudflare.
define('DISABLE_WP_CRON', true);
