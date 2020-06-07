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

    def friends(world)
      new(Plugin[:twitter]._('Twitter/%{idname}/ホームタイムライン') % {
        idname: world.idname,
      }, :"twitter-#{world.idname}-friends")
    end

    def list(world, list)
      new(Plugin[:twitter]._('Twitter/%{idname}/リスト/%{list_name}') % {
        idname: world.idname, list_name: list.name,
      }, :"twitter-#{world.idname}-list-#{list.id}")
    end
  end
end
