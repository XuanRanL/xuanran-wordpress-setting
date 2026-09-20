#!/usr/bin/env bash
# Sourced by restore-from-duplicator.sh; required WordPress operations fail closed.
# -------- 10. WP finalisation --------
log "Step 10/12: WordPress finalisation (update-db, deactivate conflicting plugins, flush)"

wpcli bash -lc "
  set -e

  # 10a. Run pending DB migrations (WooCommerce / others) -- avoids 503 maintenance loop
  wp core update-db --network 2>/dev/null || wp core update-db

  # 10b. Deactivate plugins that misbehave in nginx + Cloudflare environment OR
  # carry host-bound state from the source server. wp-rocket is included here
  # because its advanced-cache.php drop-in points to the source host's paths;
  # we reactivate it cleanly in step 10d below so it regenerates fresh state.
  for plug in wp-rocket w3-total-cache wp-super-cache wp-fastest-cache litespeed-cache \
              wordfence wordfence-login-security simple-cloudflare-turnstile cloudflare \
              breeze hummingbird-performance autoptimize wp-optimize sg-cachepress \
              wp-stateless duplicator duplicator-pro social-auto-poster; do
    if wp plugin is-installed \$plug --skip-plugins --skip-themes 2>/dev/null; then
      wp plugin deactivate \$plug --skip-plugins --skip-themes
    fi
  done

  # 10c. UPGRADE A: auto-install + activate Redis Object Cache + drop-in
  # WordPress without an object-cache.php drop-in only uses Redis if a plugin
  # provides one; we wipe it in step 6 (because old drop-ins point to host paths)
  # and re-install the canonical one here. Idempotent.
  if ! wp plugin is-installed redis-cache --skip-plugins --skip-themes 2>/dev/null; then
    wp plugin install redis-cache --activate --skip-plugins --skip-themes
  else
    wp plugin activate redis-cache --skip-plugins --skip-themes
  fi
  wp redis enable   # registered by redis-cache plugin, can't --skip-plugins

  # 10d. UPGRADE B: re-activate WP Rocket cleanly if source had it. WP Rocket
  # 3.19+ supports nginx natively. Activating now creates a fresh
  # advanced-cache.php drop-in pointing to OUR cache dir (not the source host's).
  if wp plugin is-installed wp-rocket --skip-plugins --skip-themes 2>/dev/null; then
    wp plugin activate wp-rocket --skip-plugins --skip-themes
  fi

  wp cache flush --skip-plugins --skip-themes
  wp rewrite flush --hard --skip-plugins --skip-themes
"
