# frozen_string_literal: true

module RedmineMcpPlugin
  module Tools
    class DeleteNews < Tool
      tool 'delete_news',
           title: 'Delete news',
           description: 'Delete a news item for good, with its comments. Get explicit confirmation before calling.',
           permission: :manage_news,
           write: true,
           destructive: true,
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
        # manage_news alone, as core; nothing of the item is read back.
        news = News.find_by(id: arguments['news'].to_i)
        raise ToolError, "No visible news with id #{arguments['news'].inspect}" if news.nil? || !news.project.visible?(user)

        require_module!(news.project, :news)
        authorize_open!(:manage_news, news.project)
        news.destroy
        { deleted: true, id: news.id, project_identifier: news.project.identifier }
      end
    end
  end
end
