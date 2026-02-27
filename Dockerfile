FROM haproxy:3.3-alpine

# Create config directory (already exists in official image, but explicit)
RUN mkdir -p /usr/local/etc/haproxy

# Copy and set permissions on the entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Default listen port — override via SNI_LISTEN_PORT env var
EXPOSE 443

# Our entrypoint generates haproxy.cfg from env vars, validates it, then starts haproxy
ENTRYPOINT ["/entrypoint.sh"]
CMD ["haproxy", "-W", "-db", "-f", "/usr/local/etc/haproxy/haproxy.cfg"]
