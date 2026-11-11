# frozen_string_literal: true

module RedmineMcpPlugin
  class Tool
    # News items: the visibility rule, the attributes a write takes and the
    # state it replies with.
    module NewsItems
      private

      # Same reason. Stricter than core, which updates a news item under
      # manage_news alone, but the reply returns fields only view_news may read.
      def fetch_news(id)
        news = News.visible(user).find_by(id: id.to_i)
        raise ToolError, "No visible news with id #{id.inspect}" if news.nil? || !news.visible?(user)

        news
      end

      def news_attributes(arguments)
        %w[title summary description].each_with_object({}) do |field, attributes|
          attributes[field] = arguments[field].to_s unless arguments[field].nil?
        end
      end

      def news_state(news)
        {
          id: news.id,
          title: news.title,
          summary: news.summary,
          author: news.author&.name,
          created_on: iso(news.created_on),
          project_identifier: news.project&.identifier,
          comments_count: news.comments_count,
          url: absolute_url(:news_url, news)
        }
      end
    end
  end
end
