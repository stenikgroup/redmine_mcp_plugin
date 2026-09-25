# frozen_string_literal: true

module RedmineMcpPlugin
  # Redmine's layouts reference controllers relatively (`controller: 'my'`), and Rails resolves
  # those against the controller recalled from the current request, doorkeeper/authorizations
  # inside Doorkeeper. That yields doorkeeper/my, UrlGenerationError, and a 500 on the consent screen.
  module DoorkeeperUrlOptions
    # Prepended, so it composes with an older install that still patches the same method in core.
    def self.apply
      [Doorkeeper::ApplicationsController,
       Doorkeeper::AuthorizationsController,
       Doorkeeper::AuthorizedApplicationsController].each { |controller| controller.prepend(self) }
    end

    def url_options
      options = super
      recall  = options[:_recall]
      return options unless recall

      options.merge(_recall: recall.merge(controller: recall[:controller].to_s.sub(%r{\Adoorkeeper/}, '')))
    end
  end
end
