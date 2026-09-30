FROM wordpress:7.1.2-php8.3-fpm@sha256:6f7b6caf88576b527fec7897b929a67f8a4ca2e4b6e76a920181613630ba1bcb
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
