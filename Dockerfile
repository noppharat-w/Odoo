FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        fontconfig \
        fonts-dejavu-core \
        gettext-base \
        git \
        libevent-dev \
        libffi-dev \
        libfreetype6-dev \
        libfribidi-dev \
        libharfbuzz-dev \
        libjpeg62-turbo-dev \
        libldap2-dev \
        libmagic1 \
        libopenjp2-7-dev \
        libpq-dev \
        libsasl2-dev \
        libssl-dev \
        libtiff-dev \
        libwebp-dev \
        libxcb1-dev \
        libxml2-dev \
        libxslt1-dev \
        nodejs \
        npm \
        wkhtmltopdf \
        zlib1g-dev \
    && npm install -g rtlcss less less-plugin-clean-css \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --system --home /opt/odoo --shell /bin/bash odoo \
    && mkdir -p /opt/odoo /etc/odoo /var/lib/odoo /var/log/odoo \
    && chown -R odoo:odoo /opt/odoo /etc/odoo /var/lib/odoo /var/log/odoo

WORKDIR /opt/odoo

COPY --chown=odoo:odoo requirements.txt /opt/odoo/requirements.txt
RUN python -m pip install --upgrade pip setuptools wheel \
    && pip install -r /opt/odoo/requirements.txt

COPY --chown=odoo:odoo docker/entrypoint.sh /usr/local/bin/odoo-docker-entrypoint
COPY --chown=odoo:odoo docker/odoo.conf.template /etc/odoo/odoo.conf.template
RUN chmod +x /usr/local/bin/odoo-docker-entrypoint

USER odoo

EXPOSE 8069 8072

ENTRYPOINT ["odoo-docker-entrypoint"]
