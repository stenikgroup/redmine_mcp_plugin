# frozen_string_literal: true

module RedmineMcpPlugin
  # Protocol-version negotiation across three MCP revisions.
  #
  # 2026-07-28 made MCP stateless: no initialize handshake, no Mcp-Session-Id.
  # Servers MUST implement server/discover.
  #
  # 2025-06-18 and 2025-11-25 negotiate once via initialize and then send the
  # agreed version in the MCP-Protocol-Version header. Shipped clients still do
  # this, so both paths are served.
  module Protocol
    META_SERVER_INFO_KEY = 'io.modelcontextprotocol/serverInfo'
    ICON_PATH = File.expand_path('../../assets/icon.png', __dir__)

    # Embedded, because the firewall admits the client only on /mcp, /.well-known and /oauth,
    # so a URL to the icon would never load. Cosmetic: any failure means no icons, never no boot.
    ICONS = begin
      png = File.binread(ICON_PATH) if File.file?(ICON_PATH)
      if png
        raise ArgumentError, 'not a PNG' unless png.start_with?("\x89PNG\r\n\x1a\n".b)

        width, height = png[16, 8].unpack('N2')
        [{ src: "data:image/png;base64,#{[png].pack('m0')}", mimeType: 'image/png', sizes: ["#{width}x#{height}"] }].freeze
      end
    rescue StandardError => e
      Rails.logger.warn("[redmine_mcp_plugin] icon not advertised: #{ICON_PATH}: #{e.class}: #{e.message}")
      nil
    end

    module_function

    def server_info
      { name: 'redmine-mcp-plugin', title: 'Redmine', version: RedmineMcpPlugin::VERSION }
    end

    # serverInfo for initialize and server/discover. _meta keeps the short form:
    # the icon is kilobytes and would otherwise ride on every result.
    def implementation
      ICONS ? server_info.merge(icons: ICONS) : server_info
    end

    def capabilities
      # No listChanged: this server never pushes notifications, so advertising
      # it would promise a subscriptions/listen stream we do not serve.
      # No prompts/resources: not implemented in this version, and declaring a
      # capability we cannot answer makes conformant clients call into a hole.
      { tools: {} }
    end

    def supported?(version)
      RedmineMcpPlugin::SUPPORTED_PROTOCOL_VERSIONS.include?(version.to_s)
    end

    # Chooses the revision to answer an `initialize` with. The spec says: if the
    # client's requested version is supported, echo it back; otherwise reply
    # with one we do support and let the client decide whether to continue.
    def negotiate_initialize(requested)
      supported?(requested) ? requested.to_s : RedmineMcpPlugin::PREFERRED_PROTOCOL_VERSION
    end

    # Results from 2026-07-28 onwards carry resultType and identify the server
    # in _meta. Older clients ignore both, and the spec instructs them to treat
    # a missing resultType as "complete", so this is safe to send always.
    def decorate(payload)
      payload.merge(
        resultType: 'complete',
        _meta: { META_SERVER_INFO_KEY => server_info }
      )
    end
  end
end
