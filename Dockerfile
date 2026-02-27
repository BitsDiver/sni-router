FROM haproxy:3.3-alpine

# The base image sets USER haproxy — switch to root for filesystem setup
USER root

# Ensure the config directory exists and is writable by the haproxy user,
# and set entrypoint permissions — all as root before switching back
RUN mkdir -p /usr/local/etc/haproxy \
    && chown haproxy:haproxy /usr/local/etc/haproxy

# Copy entrypoint script and make it executable
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

# Switch back to the unprivileged haproxy user
USER haproxy

# Default listen port — override via SNI_LISTEN_PORT env var
EXPOSE 443

# Our entrypoint generates haproxy.cfg from env vars, validates it, then starts haproxy
ENTRYPOINT ["/entrypoint.sh"]
CMD ["haproxy", "-W", "-db", "-f", "/usr/local/etc/haproxy/haproxy.cfg"]
