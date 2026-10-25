FROM wordpress:7.1.3-php8.3-fpm@sha256:788d6b34cb89997483ff2a08e2e04d1df28ce284ca046cd7990b0be10828c5b9
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
