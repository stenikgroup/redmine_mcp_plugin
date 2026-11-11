# frozen_string_literal: true

module RedmineMcpPlugin
  # This Redmine's public address, from Administration > Settings > General,
  # the way core builds the links of its notification emails.
  #
  # Not from the request: request.base_url is the Host header, which the caller
  # writes. An Origin compared against it always matches under DNS rebinding,
  # and a discovery document built from it names whatever host was sent, which
  # a cache in front of /.well-known would then serve to real clients.
  #
  # The request is the fallback for an install that left the setting empty.
  module PublicUrl
    module_function

    # scheme://host[:port] with no path, the form of an Origin header.
    def origin(request)
      host = configured_host
      return request.base_url if host.blank?

      "#{Setting.protocol}://#{host.split('/').first}"
    end

    # The address Redmine is served at, sub-path included, no trailing slash.
    def root(request)
      host = configured_host
      return request.base_url + (Redmine::Utils.relative_url_root.presence || '') if host.blank?

      "#{Setting.protocol}://#{host}"
    end

    # "Host name and path" may carry the sub-path Redmine is mounted on.
    def configured_host
      Setting.host_name.to_s.strip.chomp('/')
    end
  end
end
