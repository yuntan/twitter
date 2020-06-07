# frozen_string_literal: true

require_relative 'quote'
require_relative 'reply'
require_relative 'favorite'
require_relative 'retweet'

Plugin.create :twitter do
  psp = Plugin::SubpartsPhoto
  pt = Plugin::Twitter

  filter_subparts_widgets do |message, yielder|
    message.class == Plugin::Twitter::Message or next [message, yielder]
    [pt::Quote, psp::Photo, pt::Reply, pt::Favorite, pt::Retweet].each do |klass|
      yielder << klass.new(message)
    end
    [message, yielder]
  end

  update_favorite = proc do |_, _, message|
    pt::Favorite.instances[message.uri]&.changed
  end

  on_favorite(&update_favorite)
  on_before_favorite(&update_favorite)
  on_fail_favorite(&update_favorite)
  on_unfavorite(&update_favorite)

  on_update do |_, retweets|
    retweets.each do |message|
      pt::Retweet.instances[message.uri]&.changed
    end
  end

  on_destroyed do |messages|
    messages.each do |message|
      pt::Retweet.instances[message.uri]&.changed
    end
  end
end
