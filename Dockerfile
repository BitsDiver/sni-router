FROM haproxy:3.3-alpine

# Ensure the config directory exists and is writable by the haproxy user
RUN mkdir -p /usr/local/etc/haproxy \
    && chown haproxy:haproxy /usr/local/etc/haproxy

# Copy entrypoint script with execute permission (BuildKit --chmod)
COPY --chmod=755 entrypoint.sh /entrypoint.sh

# Default listen port — override via SNI_LISTEN_PORT env var
EXPOSE 443

# Our entrypoint generates haproxy.cfg from env vars, validates it, then starts haproxy
ENTRYPOINT ["/entrypoint.sh"]
CMD ["haproxy", "-W", "-db", "-f", "/usr/local/etc/haproxy/haproxy.cfg"]
