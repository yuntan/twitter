class Stream < Diva::Model
  attr_reader :title
  attr_reader :datasource_slug
  alias uri datasource_slug

  def initialize(title, datasource_slug)
    super({})
    @title = title
    @datasource_slug = datasource_slug
  end

  class << self
    def all
      new(Plugin[:twitter]._('受信したすべてのツイート(Twitter)'),
          :twitter_appear_tweets)
    end

    def friends(idname)
      new(Plugin[:twitter]._('Twitter/%{id}/ホームタイムライン') % { id: idname },
          :"twitter-#{idname}-friends")
    end

    def list(idname, list_id)
      new(Plugin[:twitter]._('Twitter/%{id}/リスト/%{list_id}') % { id: idname, list_id: list_id, },
          :"#twitter-#{idname}-list-#{list_id}")
    end
  end
end
