# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class GetNews < Tool
      include NewsItems

      tool 'get_news',
           title: 'Get news',
           description: 'Fetch one news item with its description and comments.',
           permission: :view_news,
           schema: {
             'type' => 'object',
             'properties' => {
               'news' => { 'type' => 'integer', 'description' => 'News id.' }
             },
             'required' => %w[news],
             'additionalProperties' => false
           }

      private

      def perform(arguments)
        news = fetch_news(arguments['news'])
        authorize!(:view_news, news.project)

        news_state(news).merge(
          description: news.description,
          # Core shows every comment to whoever may see the news.
          comments: news.comments.preload(:author).map do |comment|
            { id: comment.id, author: comment.author&.name, content: comment.content,
              created_on: iso(comment.created_on) }
          end
        )
      end
    end
  end
end
