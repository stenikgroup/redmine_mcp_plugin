# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class CreateNews < Tool
      include NewsItems

      tool 'create_news',
           title: 'Create news',
           description: 'Publish a news item in a project. It is visible at once and may be emailed to ' \
                        'every project member, clients included: show the user the full title, summary ' \
                        'and description and get explicit confirmation before calling. End with the url.',
           permission: :manage_news,
           rendered: %w[description],
           plain: %w[title summary],
           write: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'project' => { 'type' => %w[string integer],
                              'description' => 'Project identifier or numeric id.' },
               'title' => { 'type' => 'string', 'description' => 'Up to 60 characters.' },
               'summary' => { 'type' => 'string', 'description' => 'Up to 255 characters, optional.' },
               'description' => { 'type' => 'string', 'description' => 'Body.' }
             },
             'required' => %w[project title description],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        project = fetch_project(arguments['project'])
        require_module!(project, :news)
        authorize!(:manage_news, project)

        news       = News.new(project: project, author: user)
        attributes = news_attributes(arguments)
        refuse_unsettable!(news, attributes)
        news.safe_attributes = attributes
        raise ToolError, "Could not create news: #{news.errors.full_messages.join('; ')}" unless news.save

        news_state(news)
      end
    end
  end
end
