FROM wordpress:7.1.1-php8.3-fpm@sha256:f62a39d3e301cc081fd13a470fc8614c0a11e67722a54f1151f7fa075b6b6263
USER root
RUN set -eux; \
    savedAptMark="$(apt-mark showmanual)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends $PHPIZE_DEPS libfcgi-bin; \
    pecl install redis-6.3.0; \
    docker-php-ext-enable redis; \
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual $savedAptMark libfcgi-bin; \
    # The official Debian PHP base marks PHPIZE_DEPS manual; explicitly remove those too.
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false $PHPIZE_DEPS; \
    rm -rf /var/lib/apt/lists/* /tmp/pear; \
    php --ri redis; \
    ! command -v gcc
USER www-data
