FROM wordpress:7.1.5-php8.3-fpm@sha256:68422e7571344a1ce0e4625d91e825d0accecdff83f0593db36ccf2bbce06744
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
