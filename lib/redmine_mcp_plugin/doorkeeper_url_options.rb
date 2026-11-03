# frozen_string_literal: true

module RedmineMcpPlugin
  # Redmine's layouts, and the plugins that extend them, reference controllers relatively
  # (`controller: 'my'`, `controller: 'people'` in redmine_people's avatar helper), and Rails resolves
  # those against the current request's controller, doorkeeper/authorizations inside Doorkeeper. That
  # yields doorkeeper/my, UrlGenerationError, and a 500 on the consent screen. Core's menus avoid it
  # with use_absolute_controller; this does the same for every URL built in the Doorkeeper controllers
  # and their views.
  #
  # An earlier fix stripped doorkeeper/ from the recalled controller instead, which also broke every
  # URL built from the recall alone: sudo mode's `form_tag({})` became authorizations#create, so
  # clicking Authorize with sudo mode on returned a 500.
  module DoorkeeperUrlOptions
    # Prepended, and given to the views as a helper, so it composes with an older install that still
    # patches url_options in core.
    def self.apply
      [Doorkeeper::ApplicationsController,
       Doorkeeper::AuthorizationsController,
       Doorkeeper::AuthorizedApplicationsController].each do |controller|
        controller.prepend(self)
        controller.helper(self)
      end
    end

    def self.absolute_controller(options)
      return options unless options.is_a?(Hash) && options[:controller].present?
      return options if options[:controller].to_s.start_with?('/')

      options.merge(controller: "/#{options[:controller]}")
    end

    def url_for(options = nil)
      super(DoorkeeperUrlOptions.absolute_controller(options))
    end

    # Puts back the recalled controller that the earlier fix, hand-applied to core's
    # 30-redmine.rb on some installs, strips. A no-op everywhere else.
    def url_options
      options = super
      recall  = options[:_recall]
      return options unless recall.is_a?(Hash) && respond_to?(:request, true) && request

      controller = request.path_parameters[:controller]
      return options if controller.nil? || recall[:controller] == controller

      options.merge(_recall: recall.merge(controller: controller))
    end
  end
end
