#!/usr/bin/env bash
# Sourced only for the isolated extraction tree, never the live document root.
# -------- 6. clean Apache-era junk --------
log "Step 6/12: Cleaning Apache/host-specific junk from extracted wp-content"

WPCONTENT_SRC="$EXTRACT_DIR/wp-content"
[[ -d "$WPCONTENT_SRC" ]] || die "Expected $WPCONTENT_SRC after extraction"

JUNK=(
  "$WPCONTENT_SRC/advanced-cache.php"
  "$WPCONTENT_SRC/object-cache.php"
  "$WPCONTENT_SRC/db.php"
  "$WPCONTENT_SRC/wp-cache-config.php"
  "$WPCONTENT_SRC/cache"
  "$WPCONTENT_SRC/wflogs"
  "$WPCONTENT_SRC/w3tc-config"
  "$WPCONTENT_SRC/uploads/cache"
  "$WPCONTENT_SRC/mu-plugins/endurance-page-cache.php"
  "$WPCONTENT_SRC/mu-plugins/wp-stack-cache.php"
  "$WPCONTENT_SRC/mu-plugins/kinsta-mu-plugins.php"
  "$WPCONTENT_SRC/mu-plugins/kinsta-mu-plugins"
  "$WPCONTENT_SRC/mu-plugins/sg-cachepress.php"
  "$WPCONTENT_SRC/mu-plugins/wpe-wp-sign-on-plugin.php"
  "$EXTRACT_DIR/.htaccess"
  "$EXTRACT_DIR/.user.ini"
  "$EXTRACT_DIR/wp-config.php"            # Source wp-config — never reuse
  "$EXTRACT_DIR/wp-config-sample.php"
)
for p in "${JUNK[@]}"; do
  if [[ -e "$p" ]]; then
    require_child "$EXTRACT_DIR" "$p"
    rm -rf -- "$p" && echo "  removed $p"
  fi
done
