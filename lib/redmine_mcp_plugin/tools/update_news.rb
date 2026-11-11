# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class UpdateNews < Tool
      include NewsItems

      tool 'update_news',
           title: 'Update news',
           description: 'Edit a news item\'s title, summary or description. Editing sends no email. ' \
                        'End with the url.',
           permission: :manage_news,
           rendered: %w[description],
           plain: %w[title summary],
           write: true,
           destructive: true,
           schema: {
             'type' => 'object',
             'properties' => {
               'news' => { 'type' => 'integer', 'description' => 'News id.' },
               'title' => { 'type' => 'string', 'description' => 'Up to 60 characters.' },
               'summary' => { 'type' => 'string', 'description' => 'Up to 255 characters.' },
               'description' => { 'type' => 'string', 'description' => 'Body.' }
             },
             'required' => %w[news],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        news = fetch_news(arguments['news'])
        authorize!(:manage_news, news.project)

        attributes = news_attributes(arguments)
        raise ToolError, 'Pass at least one field to change' if attributes.empty?

        refuse_unsettable!(news, attributes)
        news.safe_attributes = attributes
        raise ToolError, "Could not update news: #{news.errors.full_messages.join('; ')}" unless news.save

        news_state(news)
      end
    end
  end
end
